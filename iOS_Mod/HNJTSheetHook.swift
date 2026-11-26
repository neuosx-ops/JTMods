//
//  HNJTSheetHook.swift
//  Runner - JTSheetController Injection & Action Handling
//

import UIKit

private enum HNZaloQRRetryCache {
    private static let defaultsKey = "HNZaloQRRetryCache"

    struct Entry {
        let image: UIImage
        let amount: Int
    }

    static func save(image: UIImage, phone: String, waybillNo: String, amount: Int) {
        let cleanWaybill = waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPhone = normalizedPhone(phone)
        guard !cleanWaybill.isEmpty, !cleanPhone.isEmpty else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            HNLog.write("Zalo QR retry: không lưu được ảnh hoặc mã vận đơn rỗng")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            guard let imageData = image.pngData() else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                HNLog.write("Zalo QR retry: không mã hóa được PNG")
                return
            }
            UserDefaults.standard.set([
                "phone": cleanPhone,
                "waybillNo": cleanWaybill,
                "amount": amount,
                "image": imageData
            ], forKey: defaultsKey)
        }
    }

    static func entry(forWaybill waybillNo: String, phone: String) -> Entry? {
        let cleanWaybill = waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWaybill.isEmpty,
              let saved = UserDefaults.standard.dictionary(forKey: defaultsKey),
              saved["waybillNo"] as? String == cleanWaybill,
              saved["phone"] as? String == normalizedPhone(phone),
              let amount = saved["amount"] as? Int,
              let imageData = saved["image"] as? Data,
              let image = UIImage(data: imageData) else {
            return nil
        }
        return Entry(image: image, amount: amount)
    }

    private static func normalizedPhone(_ phone: String) -> String {
        var digits = phone.filter(\.isNumber)
        if digits.hasPrefix("84") { digits = "0" + String(digits.dropFirst(2)) }
        return digits
    }
}

private enum HNJTSheetAssociations {
    static var stkButtonTargetKey: UInt8 = 0
    static var flashTargetKey: UInt8 = 1
    static var cellFlashTargetKey: UInt8 = 2
    static var cellFlashButtonKey: UInt8 = 3
    static var cellTTFastTargetKey: UInt8 = 4
    static var cellTTFastButtonKey: UInt8 = 5
    static var ttFastTargetKey: UInt8 = 6
    static var zaloTargetKey: UInt8 = 7
    static var zaloBadgeKey: UInt8 = 8
    static var zaloBadgeSignatureKey: UInt8 = 9
    static var copyPhoneTargetKey: UInt8 = 10
    static var downScreenTargetKey: UInt8 = 11
    static var updatePhoneTargetKey: UInt8 = 13
}

private final class HNJTSheetTTFastTarget: NSObject {
    weak var cell: UITableViewCell?
    weak var sheet: UIViewController?

    init(cell: UITableViewCell) {
        self.cell = cell
        super.init()
    }

    init(sheet: UIViewController) {
        self.sheet = sheet
        super.init()
    }

    override init() {
        super.init()
    }

    @objc func runTTFastFlow() {
        let workflow = HNCompactWorkflow.shared
        guard let presenter = sheet?.presentingViewController ?? UIApplication.shared.topViewController() ?? sheet else { return }

        guard let targetView: UIView = cell ?? (sheet.flatMap { HNJTSheetHook.findTargetCellOrCardView(for: $0, in: presenter) }) ?? presenter.view else { return }

        let (cellName, cellMaskedPhone, cellAmount, cellWaybill) = HNJTSheetHook.extractCellOrderDetails(from: targetView)

        let textInCell = HNJTSheetHook.extractAllVisibleTexts(in: targetView)
        let cachedOrders = workflow.findAllCachedOrders(maskedPhone: cellMaskedPhone, name: cellName, textInViews: textInCell)
            .filter { !$0.isSigned }

        var ordersToPay: [(waybillNo: String, amountText: String)] = []

        if !cachedOrders.isEmpty {
            for order in cachedOrders {
                if !order.waybillId.isEmpty {
                    ordersToPay.append((
                        waybillNo: order.waybillId,
                        amountText: order.codAmount
                    ))
                }
            }
        }

        if ordersToPay.isEmpty {
            let waybill = cellWaybill.isEmpty ? workflow.currentWaybillNo : cellWaybill
            let amount = (cellAmount == "0" || cellAmount.isEmpty) ? workflow.currentCodAmount : cellAmount
            if !waybill.isEmpty {
                if workflow.cachedSignedStatus(forWaybill: waybill) == true {
                    HNLog.write("TTFast Error: waybill \(waybill) is already signed!")
                    let errAlert = UIAlertController(title: "Đơn đã ký nhận", message: "Đơn hàng (\(waybill)) đã được ký nhận thành công. Không cần tạo mã QR thanh toán.", preferredStyle: .alert)
                    errAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    presenter.present(errAlert, animated: true)
                    return
                }
                ordersToPay.append((
                    waybillNo: waybill,
                    amountText: amount
                ))
            }
        }

        HNLog.write("TTFast Click: cell=\(cell != nil), sheet=\(sheet != nil), cellWaybill=\(cellWaybill), cellAmount=\(cellAmount), cellName=\(cellName), cellPhone=\(cellMaskedPhone)")
        HNLog.write("TTFast Found orders count: \(ordersToPay.count) -> \(ordersToPay)")

        if ordersToPay.isEmpty {
            HNLog.write("TTFast Error: waybillNo is empty! Cannot create payment QR.")
            let errAlert = UIAlertController(title: "TTFast Lỗi", message: "Không tìm thấy mã vận đơn trên đơn hàng này. Vui lòng mở chi tiết đơn hoặc thử lại.", preferredStyle: .alert)
            errAlert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(errAlert, animated: true)
            return
        }

        let topVC = presenter

        // 1. Check POD photo ("ảnh ký nhận") before creating payment QR code
        let primaryWaybill = ordersToPay.first?.waybillNo ?? ""
        let hasPhoto = HNJTSheetHook.hasPODPhoto(for: primaryWaybill)

        if !hasPhoto {
            // Show toast message matching J&T's prompt
            HNJTSheetHook.showToast(message: "Sau khi khách hàng thanh toán thành công, hệ thống sẽ tự động ký nhận. Vui lòng tải lên ảnh ký nhận trước.", in: topVC.view)

            let launchPhotoFlow = { [weak self] in
                NotificationCenter.default.removeObserver(self as Any, name: NSNotification.Name("HNOCRSavedSuccessNotification"), object: nil)
                NotificationCenter.default.addObserver(
                    self as Any,
                    selector: #selector(self?.handlePhotoSavedAndResumeTTFast(_:)),
                    name: NSNotification.Name("HNOCRSavedSuccessNotification"),
                    object: nil
                )

                workflow.triggerOCRPhotoFlow(from: topVC)
            }

            if let sheet = sheet, sheet.presentingViewController != nil {
                sheet.dismiss(animated: true, completion: launchPhotoFlow)
            } else {
                launchPhotoFlow()
            }
            return
        }

        // 2. POD Photo exists -> proceed directly to create TTFast Payment QR
        let waybillDisplayStr = ordersToPay.map(\.waybillNo).joined(separator: ", ")

        let executeApi = {
            let countStr = ordersToPay.count > 1 ? " (\(ordersToPay.count) đơn gộp)" : ""
            let loadingAlert = UIAlertController(title: "TTFast ⚡", message: "Đang tạo mã QR thanh toán\(countStr)...", preferredStyle: .alert)
            topVC.present(loadingAlert, animated: true)

            var isCompleted = false

            // Timeout protection after 12 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
                if !isCompleted {
                    isCompleted = true
                    loadingAlert.dismiss(animated: true) {
                        let errAlert = UIAlertController(title: "Timeout", message: "Kết nối tới server quá hạn. Vui lòng thử lại.", preferredStyle: .alert)
                        errAlert.addAction(UIAlertAction(title: "OK", style: .default))
                        topVC.present(errAlert, animated: true)
                    }
                }
            }

            workflow.createBatchCustomerPay(orders: ordersToPay) { result in
                DispatchQueue.main.async {
                    guard !isCompleted else { return }
                    isCompleted = true
                    loadingAlert.dismiss(animated: true) {
                        switch result {
                        case .success(let payData):
                            let qrVC = HNFastQRPaymentViewController()
                            qrVC.payData = payData
                            qrVC.waybillNo = waybillDisplayStr
                            qrVC.amountText = "\(payData.totalMoney)"
                            qrVC.receiverName = cellName.isEmpty ? workflow.currentReceiverName : cellName
                            qrVC.modalPresentationStyle = .fullScreen
                            topVC.present(qrVC, animated: true)

                        case .failure(let error):
                            let errAlert = UIAlertController(title: "Tạo QR Thất Bại", message: error.localizedDescription, preferredStyle: .alert)
                            errAlert.addAction(UIAlertAction(title: "OK", style: .default))
                            topVC.present(errAlert, animated: true)
                        }
                    }
                }
            }
        }

        if let sheet = sheet, sheet.presentingViewController != nil {
            sheet.dismiss(animated: true, completion: executeApi)
        } else {
            executeApi()
        }
    }

    @objc private func handlePhotoSavedAndResumeTTFast(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("HNOCRSavedSuccessNotification"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.runTTFastFlow()
        }
    }
}

private final class HNJTSheetCopyPhoneTarget: NSObject {
    weak var sheet: UIViewController?

    init(sheet: UIViewController) {
        self.sheet = sheet
        super.init()
    }

    /// Lấy SĐT đầy đủ của đơn đang bấm "Gọi" (giải mã qua API, không mở chi tiết đơn) rồi copy vào clipboard.
    @objc func copyPhone() {
        guard let sheet = sheet else { return }
        let workflow = HNCompactWorkflow.shared
        let presenter = sheet.presentingViewController ?? UIApplication.shared.topViewController() ?? sheet

        // Đọc thông tin đơn TRƯỚC khi đóng sheet (sheet còn thì mới tìm được đúng thẻ đã bấm)
        let targetView: UIView? = HNJTSheetHook.findTargetCellOrCardView(for: sheet, in: presenter) ?? presenter.view
        var waybillNo = ""
        var encPhone = ""
        if let targetView = targetView {
            let (cellName, cellMaskedPhone, _, cellWaybill) = HNJTSheetHook.extractCellOrderDetails(from: targetView)
            waybillNo = cellWaybill
            let texts = HNJTSheetHook.extractAllVisibleTexts(in: targetView)
            if let cached = workflow.findCachedOrder(maskedPhone: cellMaskedPhone, name: cellName, textInViews: texts) {
                if waybillNo.isEmpty { waybillNo = cached.waybillId }
                if cached.waybillId == waybillNo { encPhone = cached.encPhone }
            }
        }

        let finish: (String?) -> Void = { phone in
            DispatchQueue.main.async {
                let toastHost: UIView? = UIApplication.shared.topViewController()?.view ?? presenter.view
                guard let toastHost = toastHost else { return }
                guard let phone = phone, !phone.isEmpty, !phone.contains("*") else {
                    HNJTSheetHook.showToast(message: "Không lấy được SĐT đầy đủ của đơn này.", in: toastHost)
                    return
                }
                let clean = HNZaloConfig.shared.effectivePhone(phone)
                let isBackup = clean != HNZaloConfig.normalize(phone)
                UIPasteboard.general.string = clean
                HNJTSheetHook.showToast(message: "Đã copy SĐT\(isBackup ? " backup" : ""): \(clean)", in: toastHost)
            }
        }

        let run = {
            guard !waybillNo.isEmpty || !encPhone.isEmpty else {
                finish(nil)
                return
            }
            workflow.resolveFullReceiverPhone(waybillNo: waybillNo, encPhone: encPhone) { fullPhone in
                if let fullPhone = fullPhone, !fullPhone.isEmpty, !fullPhone.contains("*") {
                    finish(fullPhone)
                } else {
                    finish(workflow.decryptedPhone(forWaybill: waybillNo))
                }
            }
        }

        if sheet.presentingViewController != nil {
            sheet.dismiss(animated: true, completion: run)
        } else {
            run()
        }
    }
}

private final class HNJTSheetDownScreenTarget: NSObject {
    weak var sheet: UIViewController?

    init(sheet: UIViewController) {
        self.sheet = sheet
        super.init()
    }

    /// Lấy SĐT đầy đủ của đơn đang bấm "Down Screen" rồi tự động tải/lưu ảnh Call Log Screen vào Bộ sưu tập.
    @objc func runDownScreenFlow() {
        guard let sheet = sheet else { return }
        let workflow = HNCompactWorkflow.shared
        let presenter = sheet.presentingViewController ?? UIApplication.shared.topViewController() ?? sheet

        // Đọc thông tin đơn TRƯỚC khi đóng sheet
        let targetView: UIView? = HNJTSheetHook.findTargetCellOrCardView(for: sheet, in: presenter) ?? presenter.view
        var waybillNo = ""
        var encPhone = ""
        var cellMaskedPhone = ""
        var cellName = ""

        if let targetView = targetView {
            let details = HNJTSheetHook.extractCellOrderDetails(from: targetView)
            cellName = details.0
            cellMaskedPhone = details.1
            waybillNo = details.3

            let texts = HNJTSheetHook.extractAllVisibleTexts(in: targetView)
            if let cached = workflow.findCachedOrder(maskedPhone: cellMaskedPhone, name: cellName, textInViews: texts) {
                if waybillNo.isEmpty { waybillNo = cached.waybillId }
                if cached.waybillId == waybillNo { encPhone = cached.encPhone }
            }
        }

        let performDownload: () -> Void = {
            let toastHost: UIView? = UIApplication.shared.topViewController()?.view ?? presenter.view

            let saveImageForPhone: (String) -> Void = { phoneStr in
                let cleanPhone = (phoneStr.isEmpty || phoneStr.contains("*")) ? "0359145852" : phoneStr
                workflow.uploadFakeCallRecord(phoneNumber: cleanPhone, waybillNo: waybillNo, receiverName: cellName)
                HNFakeCallHistoryViewController.downloadAndSaveCallHistoryImage(phoneNumber: cleanPhone) { _ in
                    DispatchQueue.main.async {
                        if let host = toastHost {
                            HNJTSheetHook.showToast(message: "Đã fake cuộc gọi & tải ảnh Call Log Screen! 📲📸", in: host)
                        }
                    }
                }
            }

            guard !waybillNo.isEmpty || !encPhone.isEmpty else {
                let current = workflow.currentPhoneNumber
                let phoneToUse = (!current.isEmpty && !current.contains("*")) ? current : cellMaskedPhone
                saveImageForPhone(phoneToUse)
                return
            }

            workflow.resolveFullReceiverPhone(waybillNo: waybillNo, encPhone: encPhone) { fullPhone in
                DispatchQueue.main.async {
                    let resolved = (fullPhone != nil && !fullPhone!.contains("*")) ? fullPhone! : workflow.currentPhoneNumber
                    let finalPhone = (!resolved.isEmpty && !resolved.contains("*")) ? resolved : cellMaskedPhone
                    saveImageForPhone(finalPhone)
                }
            }
        }

        if sheet.presentingViewController != nil {
            sheet.dismiss(animated: true, completion: performDownload)
        } else {
            performDownload()
        }
    }
}

private final class HNJTSheetUpdatePhoneTarget: NSObject {
    weak var sheet: UIViewController?

    init(sheet: UIViewController) {
        self.sheet = sheet
        super.init()
    }

    @objc func runUpdatePhoneFlow() {
        guard let sheet = sheet else { return }
        let workflow = HNCompactWorkflow.shared
        let presenter = sheet.presentingViewController ?? UIApplication.shared.topViewController() ?? sheet

        let targetView: UIView? = HNJTSheetHook.findTargetCellOrCardView(for: sheet, in: presenter) ?? presenter.view
        var waybillNo = ""
        var encPhone = ""
        var cellMaskedPhone = ""
        var cellName = ""

        if let targetView = targetView {
            let details = HNJTSheetHook.extractCellOrderDetails(from: targetView)
            cellName = details.0
            cellMaskedPhone = details.1
            waybillNo = details.3

            let texts = HNJTSheetHook.extractAllVisibleTexts(in: targetView)
            if let cached = workflow.findCachedOrder(maskedPhone: cellMaskedPhone, name: cellName, textInViews: texts) {
                if waybillNo.isEmpty { waybillNo = cached.waybillId }
                if cached.waybillId == waybillNo { encPhone = cached.encPhone }
            }
        }

        let showDialog: (String?) -> Void = { resolvedPhone in
            let hostVC = UIApplication.shared.topViewController() ?? presenter
            let originalPhone = (resolvedPhone != nil && !resolvedPhone!.contains("*")) ? resolvedPhone! : (workflow.currentPhoneNumber.isEmpty ? cellMaskedPhone : workflow.currentPhoneNumber)
            let currentBackup = HNZaloConfig.shared.getBackupPhone(originalPhone) ?? ""

            let alert = UIAlertController(
                title: "CẬP NHẬT SỐ ĐIỆN THOẠI BACKUP",
                message: "Nhập SĐT backup/Zalo cho khách (\(cellName.isEmpty ? originalPhone : cellName)):\nSĐT gốc: \(originalPhone)",
                preferredStyle: .alert
            )

            alert.addTextField { field in
                field.placeholder = "Nhập SĐT backup (VD: 0988888888)"
                field.text = currentBackup
                field.keyboardType = .phonePad
            }

            alert.addAction(UIAlertAction(title: "Lưu SĐT Backup", style: .default) { _ in
                let input = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                HNZaloConfig.shared.setBackupPhone(originalPhone, backupPhone: input, name: cellName)
                HNJTSheetHook.refreshZaloBadges()
                if input.isEmpty {
                    HNJTSheetHook.showToast(message: "Đã xóa SĐT backup cho \(originalPhone)", in: hostVC.view)
                } else {
                    HNJTSheetHook.showToast(message: "Đã lưu SĐT Backup Zalo: \(HNZaloConfig.normalize(input))", in: hostVC.view)
                }
            })

            alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            hostVC.present(alert, animated: true)
        }

        let dismissAndRun = {
            if !waybillNo.isEmpty || !encPhone.isEmpty {
                workflow.resolveFullReceiverPhone(waybillNo: waybillNo, encPhone: encPhone) { fullPhone in
                    DispatchQueue.main.async { showDialog(fullPhone) }
                }
            } else {
                showDialog(workflow.currentPhoneNumber)
            }
        }

        if sheet.presentingViewController != nil {
            sheet.dismiss(animated: true, completion: dismissAndRun)
        } else {
            dismissAndRun()
        }
    }
}

private final class HNJTSheetHNFlashTarget: NSObject {
    weak var sheet: UIViewController?
    // Dùng cho nút HN Flash gắn thẳng trên thẻ đơn (không có sheet "Gọi"): giữ 1 VC rỗng làm "sheet" ảo
    private var standaloneHolder: UIViewController?

    init(sheet: UIViewController) {
        self.sheet = sheet
    }

    override init() {
        let vc = UIViewController()
        standaloneHolder = vc
        sheet = vc
        super.init()
    }

    @objc func runHNFlashFlow() {
        guard let sheet = sheet else { return }
        let workflow = HNCompactWorkflow.shared

        // Lấy thông tin đơn & khởi chạy giải mã SĐT ngay lập tức (song song với hiệu ứng đóng sheet / mở chi tiết)
        let prewarmPresenter = sheet.presentingViewController ?? UIApplication.shared.topViewController() ?? sheet
        if let prewarmView = HNJTSheetHook.findTargetCellOrCardView(for: sheet, in: prewarmPresenter) {
            let (pName, pMasked, _, pWaybill) = HNJTSheetHook.extractCellOrderDetails(from: prewarmView)
            let pTexts = HNJTSheetHook.extractAllVisibleTexts(in: prewarmView)
            let pCached = workflow.findCachedOrder(maskedPhone: pMasked, name: pName, textInViews: pTexts)
            let pWb = (pCached?.waybillId.isEmpty == false) ? pCached!.waybillId : pWaybill
            let pEnc = pCached?.encPhone ?? ""
            if !pWb.isEmpty || !pEnc.isEmpty {
                workflow.resolveFullReceiverPhone(waybillNo: pWb, encPhone: pEnc) { _ in }
            }
        }

        let performFlash = {
            workflow.resetState()
            let presenter = sheet.presentingViewController ?? UIApplication.shared.topViewController() ?? sheet

            // 1. Identify specific cell view and extract details directly
            guard let targetView = HNJTSheetHook.findTargetCellOrCardView(for: sheet, in: presenter) ?? presenter.view else { return }
            let (cellName, cellMaskedPhone, cellAmount, cellWaybill) = HNJTSheetHook.extractCellOrderDetails(from: targetView)

            // Reset workflow state for clean execution
            workflow.currentPhoneNumber = ""
            workflow.currentCodAmount = "0"

            var waybillNo = cellWaybill
            var encPhone = ""
            var targetCodAmount = cellAmount

            let textInCell = HNJTSheetHook.extractAllVisibleTexts(in: targetView)
            if let cached = workflow.findCachedOrder(maskedPhone: cellMaskedPhone, name: cellName, textInViews: textInCell) {
                waybillNo = cached.waybillId
                encPhone = cached.encPhone
                if targetCodAmount == "0" || targetCodAmount.isEmpty {
                    targetCodAmount = cached.codAmount
                }
            } else {
                let extracted = HNJTSheetHook.extractWaybillNo(from: presenter)
                if !extracted.isEmpty { waybillNo = extracted }
            }

            if targetCodAmount != "0" && !targetCodAmount.isEmpty {
                workflow.currentCodAmount = targetCodAmount
            }

            if !waybillNo.isEmpty || !encPhone.isEmpty {
                workflow.resolveFullReceiverPhone(waybillNo: waybillNo, encPhone: encPhone) { _ in }
            }

            HNJTSheetHook.pinOrderInCell(targetView, waybillNo: waybillNo)

            // Các đơn chưa ký của cùng khách (để Zalo gộp 1 QR cho tất cả); lọc chính xác theo SĐT đầy đủ đã giải mã
            let fetchZaloOrdersForPhone: (String) -> [(waybillNo: String, amountText: String, goodsName: String)] = { targetPhone in
                var cached = workflow.findAllCachedOrders(maskedPhone: cellMaskedPhone, name: cellName, fullPhone: targetPhone, textInViews: textInCell)
                    .filter { !$0.waybillId.isEmpty && !$0.isSigned }
                if !waybillNo.isEmpty,
                   !cached.contains(where: { $0.waybillId == waybillNo }),
                   workflow.cachedSignedStatus(forWaybill: waybillNo) != true {
                    let cachedTarget = workflow.cachedOrderInfo(forWaybill: waybillNo)
                    cached.append(CachedOrderInfo(
                        waybillId: waybillNo,
                        receiverName: cellName,
                        maskedPhone: cellMaskedPhone,
                        encPhone: "",
                        codAmount: cachedTarget?.codAmount ?? workflow.currentCodAmount,
                        taxAfterFee: "0",
                        goodsName: cachedTarget?.goodsName ?? "",
                        isSigned: false
                    ))
                }
                return cached.map { (waybillNo: $0.waybillId, amountText: $0.codAmount, goodsName: $0.goodsName) }
            }

            // Step 3, 4, 5: Resolve Phone -> Open STK SMS -> Auto OCR -> Back to List (chạy sau khi đã vào chi tiết)
            let continueAfterNavigation: () -> Void = {
                HNJTSheetHook.dismissUnneededRelationPopupIfPresented {
                    let detailVC = UIApplication.shared.topViewController() ?? presenter

                    // Không tìm thấy đơn trong cache ở danh sách -> chưa có số vận đơn: đọc lại từ màn chi tiết vừa mở
                    if waybillNo.isEmpty {
                        let fromDetail = HNJTSheetHook.extractWaybillNo(from: detailVC)
                        if !fromDetail.isEmpty { waybillNo = fromDetail }
                    }
                    HNLog.write("HNFlash: waybill=\(waybillNo.isEmpty ? "EMPTY" : waybillNo) encPhone=\(encPhone.isEmpty ? "no" : "yes") masked=\(cellMaskedPhone) amount=\(workflow.currentCodAmount)")

                    workflow.resolveFullReceiverPhone(waybillNo: waybillNo, encPhone: encPhone) { fullPhone in
                        let runOnMain = {
                            HNLog.write("HNFlash: resolveFullReceiverPhone -> \(fullPhone == nil ? "nil" : "ok")")
                            let resolvedPhone = (fullPhone != nil && !fullPhone!.contains("*")) ? fullPhone! : workflow.currentPhoneNumber

                            if !resolvedPhone.isEmpty && !resolvedPhone.contains("*") {
                                workflow.currentPhoneNumber = resolvedPhone
                                HNJTSheetHook.dispatchZaloOrSMS(phone: resolvedPhone, waybillNo: waybillNo, orders: fetchZaloOrdersForPhone(resolvedPhone), name: cellName, from: detailVC)
                            } else {
                                workflow.prefillFromWaybillNo(waybillNo) { success in
                                    DispatchQueue.main.async {
                                        let phone = workflow.currentPhoneNumber
                                        HNLog.write("HNFlash: prefill success=\(success) phone=\(phone.isEmpty ? "EMPTY" : (phone.contains("*") ? "MASKED" : "ok"))")
                                        guard !phone.isEmpty, !phone.contains("*") else {
                                            let alert = UIAlertController(
                                                title: "Không lấy được số điện thoại",
                                                message: "Chưa lấy được SĐT đầy đủ của đơn này nên không gửi Zalo/SMS được. Xem View Log để biết chi tiết.",
                                                preferredStyle: .alert
                                            )
                                            alert.addAction(UIAlertAction(title: "OK", style: .default))
                                            detailVC.present(alert, animated: true)
                                            return
                                        }
                                        HNJTSheetHook.dispatchZaloOrSMS(phone: phone, waybillNo: waybillNo, orders: fetchZaloOrdersForPhone(phone), name: cellName, from: detailVC)
                                    }
                                }
                            }
                        }
                        if Thread.isMainThread {
                            runOnMain()
                        } else {
                            DispatchQueue.main.async(execute: runOnMain)
                        }
                    }
                }
            }

            // The row's sign action opens the order detail on this app.
            HNJTSheetHook.openOrderDetail(
                for: targetView,
                maskedPhone: cellMaskedPhone,
                name: cellName,
                waybillNo: waybillNo,
                in: presenter,
                completion: continueAfterNavigation
            )
        }

        if sheet.presentingViewController != nil {
            sheet.dismiss(animated: true, completion: performFlash)
        } else {
            performFlash()
        }
    }
}

@objc(HNJTSheetHook)
public class HNJTSheetHook: NSObject {

    public static weak var lastTappedView: UIView?

    @objc public static func installJTSheetHook() {
        _ = NSClassFromString("Runner.JTSheetController")
        UIApplication.swizzleSendEvent()
        UITableViewCell.swizzleLayoutForHNFlash()

        // Quay lại app (vd sửa HNZaloContacts.json) -> vẽ lại icon Zalo trên danh sách
        if !isZaloBadgeObserverInstalled {
            isZaloBadgeObserverInstalled = true
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                HNJTSheetHook.refreshZaloBadges()
            }
        }
    }

    private static var isZaloBadgeObserverInstalled = false

    @objc public static func injectSTKButton(into sheet: UIViewController) {
        guard objc_getAssociatedObject(sheet, &HNJTSheetAssociations.flashTargetKey) == nil else {
            return
        }

        guard let cls = NSClassFromString("Runner.JTSheetController"),
              let stackViewIvar = class_getInstanceVariable(cls, "stackView") else {
            return
        }

        sheet.loadViewIfNeeded()
        guard let stackView = object_getIvar(sheet, stackViewIvar) as? UIStackView else {
            return
        }

        let stackText = stackView.arrangedSubviews.flatMap { visibleText(in: $0) }
        let isCallSheet = stackText.contains { text in
            let normalized = text.lowercased()
            return normalized.contains("gọi") || normalized.contains("call") || text.contains("拨打")
        }
        guard isCallSheet else {
            return
        }

        var cancelIndex: Int? = nil
        var lastActionIndex: Int? = nil
        var actionReferenceView: UIView? = nil

        for (index, subview) in stackView.arrangedSubviews.enumerated() {
            let texts = visibleText(in: subview)
            let lowerTexts = texts.map { $0.lowercased() }

            if lowerTexts.contains(where: { $0.contains("huỷ") || $0.contains("cancel") || $0.contains("hủy") }) {
                if cancelIndex == nil { cancelIndex = index }
            }

            if lowerTexts.contains(where: { $0.contains("gọi") || $0.contains("nhắn tin") || $0.contains("call") || $0.contains("sms") }) {
                lastActionIndex = index
                if actionReferenceView == nil { actionReferenceView = subview }
            }
        }

        let insertIndex: Int
        if let cancelIdx = cancelIndex {
            insertIndex = cancelIdx
        } else if let actionIdx = lastActionIndex {
            insertIndex = actionIdx + 1
        } else {
            insertIndex = max(0, stackView.arrangedSubviews.count - 1)
        }

        func makeButton(_ title: String, id: String, color: UIColor) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = id
            button.contentHorizontalAlignment = .left
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitleColor(color, for: .normal)
            return button
        }

        let ttFastButton = makeButton("TTFast ⚡", id: "hnmod-ttfast", color: UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0))
        let zaloSmsButton = makeButton("Gửi Zalo/SMS 💬", id: "hnmod-send-zalo-sms", color: UIColor(red: 0.0, green: 0.5, blue: 0.8, alpha: 1.0))
        let copyPhoneButton = makeButton("Copy SĐT 📋", id: "hnmod-copy-phone", color: UIColor(red: 0.12, green: 0.6, blue: 0.32, alpha: 1.0))
        let downScreenButton = makeButton("Down Screen 📲", id: "hnmod-down-screen", color: UIColor(red: 0.85, green: 0.35, blue: 0.15, alpha: 1.0))
        let updatePhoneButton = makeButton("Update SĐT ✏️", id: "hnmod-update-phone", color: UIColor(red: 0.6, green: 0.2, blue: 0.8, alpha: 1.0))
        let newButtons = [ttFastButton, zaloSmsButton, copyPhoneButton, downScreenButton, updatePhoneButton]

        var buttonHeight: CGFloat = 50
        var buttonFont = UIFont.systemFont(ofSize: 17)
        var buttonBackground: UIColor = .clear
        if let refView = actionReferenceView ?? stackView.arrangedSubviews.first {
            buttonBackground = refView.backgroundColor ?? .clear
            if let refButton = refView as? UIButton {
                buttonFont = refButton.titleLabel?.font ?? buttonFont
                buttonBackground = refButton.backgroundColor ?? .clear
                if refButton.titleEdgeInsets.left > 0 {
                    newButtons.forEach { $0.titleEdgeInsets = refButton.titleEdgeInsets }
                }
            } else {
                var refFont: UIFont? = nil
                var refColor: UIColor? = nil
                findLabelProperties(in: refView, font: &refFont, color: &refColor)
                buttonFont = refFont ?? buttonFont
            }
            if refView.bounds.height > 0 { buttonHeight = refView.bounds.height }
        }
        newButtons.forEach { button in
            button.titleLabel?.font = buttonFont
            button.backgroundColor = buttonBackground
            button.heightAnchor.constraint(equalToConstant: buttonHeight).isActive = true
        }

        let ttFastTarget = HNJTSheetTTFastTarget(sheet: sheet)
        objc_setAssociatedObject(sheet, &HNJTSheetAssociations.ttFastTargetKey, ttFastTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        ttFastButton.addTarget(ttFastTarget, action: #selector(HNJTSheetTTFastTarget.runTTFastFlow), for: .touchUpInside)

        // Gửi Zalo/SMS = luồng HN Flash cũ (ghim -> chi tiết -> lấy SĐT) rồi chọn Zalo hoặc SMS theo HNZaloConfig
        let flashTarget = HNJTSheetHNFlashTarget(sheet: sheet)
        objc_setAssociatedObject(sheet, &HNJTSheetAssociations.flashTargetKey, flashTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        zaloSmsButton.addTarget(flashTarget, action: #selector(HNJTSheetHNFlashTarget.runHNFlashFlow), for: .touchUpInside)

        let copyPhoneTarget = HNJTSheetCopyPhoneTarget(sheet: sheet)
        objc_setAssociatedObject(sheet, &HNJTSheetAssociations.copyPhoneTargetKey, copyPhoneTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        copyPhoneButton.addTarget(copyPhoneTarget, action: #selector(HNJTSheetCopyPhoneTarget.copyPhone), for: .touchUpInside)

        let downScreenTarget = HNJTSheetDownScreenTarget(sheet: sheet)
        objc_setAssociatedObject(sheet, &HNJTSheetAssociations.downScreenTargetKey, downScreenTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        downScreenButton.addTarget(downScreenTarget, action: #selector(HNJTSheetDownScreenTarget.runDownScreenFlow), for: .touchUpInside)

        let updatePhoneTarget = HNJTSheetUpdatePhoneTarget(sheet: sheet)
        objc_setAssociatedObject(sheet, &HNJTSheetAssociations.updatePhoneTargetKey, updatePhoneTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        updatePhoneButton.addTarget(updatePhoneTarget, action: #selector(HNJTSheetUpdatePhoneTarget.runUpdatePhoneFlow), for: .touchUpInside)

        stackView.insertArrangedSubview(ttFastButton, at: insertIndex)
        stackView.insertArrangedSubview(zaloSmsButton, at: insertIndex + 1)
        stackView.insertArrangedSubview(copyPhoneButton, at: insertIndex + 2)
        stackView.insertArrangedSubview(downScreenButton, at: insertIndex + 3)
        stackView.insertArrangedSubview(updatePhoneButton, at: insertIndex + 4)

        stackView.setNeedsLayout()
        sheet.view.setNeedsLayout()
    }

    private struct PreparedZaloQRData {
        let totalAmount: Int
        let bankName: String
        let account: String
        let owner: String
        let content: String
        let emv: String
        let orderLines: [(waybill: String, goods: String)]
    }

    private static func prepareZaloQRData(for orders: [(waybillNo: String, amountText: String, goodsName: String)], bankConfig: (name: String, account: String, owner: String)) -> PreparedZaloQRData? {
        let workflow = HNCompactWorkflow.shared
        let validOrders = orders.filter { item in
            let wNo = item.waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wNo.isEmpty else { return false }
            return workflow.cachedSignedStatus(forWaybill: wNo) != true
        }

        let account = bankConfig.account.isEmpty ? "0962296321" : bankConfig.account
        let owner = bankConfig.owner.isEmpty ? "NGUYEN VAN HAU" : bankConfig.owner
        let bankName = bankConfig.name.isEmpty ? "BIDV" : bankConfig.name

        // Làm tròn nghìn: từ 400đ lên (14.400 -> 15.000, 14.399 -> 14.000)
        let total = HNVietQRBuilder.roundVND(validOrders.reduce(0) { $0 + HNVietQRBuilder.parseVND($1.amountText) })
        guard total > 0, let bin = HNVietQRBuilder.bin(forBankName: bankName), let first = validOrders.first else {
            HNLog.write("Zalo QR: skip (total=\(total) bin=\(HNVietQRBuilder.bin(forBankName: bankName) ?? "nil") bank=\(bankName))")
            return nil
        }

        let content = validOrders.count == 1 ? first.waybillNo : "\(first.waybillNo) \(validOrders.count) don"
        let emv = HNVietQRBuilder.payload(bin: bin, account: account, amount: total, content: content)
        HNLog.write("Zalo QR: amount=\(total) bin=\(bin) payload=\(emv)")

        let orderLines = validOrders.map { (waybill: $0.waybillNo, goods: $0.goodsName) }
        return PreparedZaloQRData(
            totalAmount: total,
            bankName: bankName,
            account: account,
            owner: owner,
            content: content,
            emv: emv,
            orderLines: orderLines
        )
    }

    private static func renderZaloQRBill(_ data: PreparedZaloQRData) -> UIImage? {
        guard let qr = HNVietQRBuilder.qrImage(from: data.emv) else { return nil }
        return HNVietQRBuilder.billImage(
            qr: qr,
            amount: data.totalAmount,
            bankName: data.bankName,
            account: data.account,
            owner: data.owner,
            content: data.content,
            orders: data.orderLines
        )
    }

    /// Ảnh QR (VietQR/napas247) của tài khoản trong cài đặt, tổng tiền = cộng chính xác các đơn.
    /// nil nếu không xác định được mã ngân hàng, QR hoặc tổng tiền (caller sẽ báo lỗi).
    public static func buildZaloQRImage(for orders: [(waybillNo: String, amountText: String, goodsName: String)], bankConfig: (name: String, account: String, owner: String)) -> UIImage? {
        guard let prepared = prepareZaloQRData(for: orders, bankConfig: bankConfig) else { return nil }
        return renderZaloQRBill(prepared)
    }

    public static func buildZaloMessage(for orders: [(waybillNo: String, amountText: String, goodsName: String)], bankConfig: (name: String, account: String, owner: String)) -> String {
        let workflow = HNCompactWorkflow.shared
        let validOrders = orders.filter { item in
            let wNo = item.waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wNo.isEmpty else { return false }
            return workflow.cachedSignedStatus(forWaybill: wNo) != true
        }

        var totalMoney: Int = 0
        var itemsText = ""
        for (index, order) in validOrders.enumerated() {
            let m = HNVietQRBuilder.parseVND(order.amountText)
            totalMoney += m
            let formattedM = NumberFormatter.localizedString(from: NSNumber(value: m), number: .decimal)
            let goodsStr = order.goodsName.isEmpty ? "" : " - \(order.goodsName)"
            itemsText += " \(index + 1) Đơn \(order.waybillNo) (\(formattedM) đ)\(goodsStr)\n"
        }

        totalMoney = HNVietQRBuilder.roundVND(totalMoney)
        let formattedTotal = NumberFormatter.localizedString(from: NSNumber(value: totalMoney), number: .decimal)

        let account = bankConfig.account.isEmpty ? "0962296321" : bankConfig.account
        let owner = bankConfig.owner.isEmpty ? "NGUYEN VAN HAU" : bankConfig.owner
        let bankName = bankConfig.name.isEmpty ? "BIDV" : bankConfig.name

        return """
        Tiền: \(formattedTotal) đ
        Số Tài Khoản: \(account) - \(owner)
        Tên Ngân Hàng: \(bankName)
        Tên Đơn Hàng:
        \(itemsText.trimmingCharacters(in: .whitespacesAndNewlines))
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func extractCellOrderDetails(from cellView: UIView) -> (name: String, maskedPhone: String, amount: String, waybillNo: String) {
        let texts = extractAllVisibleTexts(in: cellView)

        var name = ""
        var maskedPhone = ""
        var amount = "0"
        var waybillNo = ""

        for text in texts {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }

            if clean.contains("******") {
                let parts = clean.components(separatedBy: "|")
                for part in parts {
                    let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if p.contains("******") {
                        maskedPhone = p.filter { $0.isNumber || $0 == "*" }
                    } else if name.isEmpty && !p.contains("******") && p.count >= 2 {
                        name = p
                    }
                }
            }

            if name.isEmpty && !clean.contains("******") && !clean.contains("đ") && !clean.contains("đơn") {
                if clean.count >= 2 && clean.count <= 30 && !clean.contains("Tân Hội") && !clean.contains("Lâm Đồng") {
                    let digitsCount = clean.filter(\.isNumber).count
                    if digitsCount == 0 {
                        name = clean
                    }
                }
            }

            let digitsOnly = clean.filter(\.isNumber)
            if !digitsOnly.isEmpty {
                if clean.contains("đ") || clean.contains(",") || clean.contains(".") {
                    if let num = Int(digitsOnly), num > 100 {
                        amount = "\(num)"
                    }
                } else if digitsOnly.count >= 10 && digitsOnly.count <= 15 {
                    waybillNo = digitsOnly
                }
            }
        }

        return (name, maskedPhone, amount, waybillNo)
    }

    /// Màn chi tiết đang mở có đúng đơn cần mở không?
    /// true = khớp, false = chắc chắn là đơn khác, nil = chưa đọc được thông tin định danh (màn chưa tải xong).
    private static func detailMatches(vc: UIViewController?, maskedPhone: String, name: String, waybillNo: String) -> Bool? {
        guard let root = vc?.view else { return nil }
        let texts = extractAllVisibleTexts(in: root)
        let phoneKey = maskedPhone.filter { $0.isNumber }

        if !waybillNo.isEmpty && texts.contains(where: { $0.contains(waybillNo) }) { return true }

        var sawMaskedPhone = false
        for t in texts where t.contains("*") {
            let digits = t.filter { $0.isNumber }
            guard digits.count >= 3 else { continue }
            sawMaskedPhone = true
            if !phoneKey.isEmpty && digits.hasSuffix(phoneKey) { return true }
        }
        if sawMaskedPhone { return false }
        return nil
    }

    fileprivate static func dismissUnneededRelationPopupIfPresented(completion: @escaping () -> Void) {
        guard let top = UIApplication.shared.topViewController(),
              String(describing: type(of: top)).contains("DeliveryProxySignEditorViewController"),
              top.presentingViewController != nil else {
            completion()
            return
        }
        top.dismiss(animated: true, completion: completion)
    }

    /// Mở chi tiết đơn NGAY khi danh sách còn nguyên trạng (chưa ghim), nên thẻ vừa bấm "Gọi" chắc chắn đúng đơn.
    ///  - Ưu tiên nút "Ký nhận" của thẻ (log cho thấy didSelectRowAt không điều hướng), không được thì didSelect.
    ///  - Đọc màn chi tiết, so SĐT che / mã vận đơn với thẻ. Sai đơn -> lùi lại, thử cách còn lại (1 lần).
    ///    Vẫn sai -> dừng, KHÔNG chạy tiếp (tránh gửi STK nhầm khách).
    ///  - Khi đã vào đúng đơn: gọi onEntered (ghim đơn), rồi completion (SMS -> OCR).
    public static func openOrderDetail(for cell: UIView, maskedPhone: String, name: String, waybillNo: String, in presenter: UIViewController, completion: @escaping () -> Void) {
        let phoneKey = maskedPhone.filter { $0.isNumber }

        func cellStillMatches(_ v: UIView) -> Bool {
            guard v.window != nil else { return false }
            let texts = extractAllVisibleTexts(in: v)
            let joined = texts.joined(separator: " | ")
            var score = 0
            if !waybillNo.isEmpty && joined.contains(waybillNo) { score += 4 }
            if !phoneKey.isEmpty && texts.contains(where: { $0.contains("*") && $0.filter { $0.isNumber } == phoneKey }) { score += 3 }
            if !name.isEmpty && joined.contains(name) { score += 2 }
            return score >= 3
        }

        func matchingCell() -> UIView? {
            if cellStillMatches(cell) { return cell }
            for w in UIApplication.shared.windows {
                if let c = findCellMatching(maskedPhone: maskedPhone, name: name, waybillNo: waybillNo, in: w, quiet: true) {
                    return c
                }
            }
            return nil
        }

        func waitForDetailPush(before: UIViewController?, polls: Int, retriesRemaining: Int) {
            let after = UIApplication.shared.topViewController()
            if after !== before {
                verifyDetail(polls: 0, retriesRemaining: retriesRemaining)
                return
            }
            if polls < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    waitForDetailPush(before: before, polls: polls + 1, retriesRemaining: retriesRemaining)
                }
            } else if retriesRemaining > 0 {
                openAttempt(useSignButton: false, retriesRemaining: retriesRemaining - 1)
            }
        }

        func openAttempt(useSignButton: Bool, retriesRemaining: Int) {
            guard let target = matchingCell() else {
                guard retriesRemaining > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    openAttempt(useSignButton: useSignButton, retriesRemaining: retriesRemaining - 1)
                }
                return
            }
            let before = UIApplication.shared.topViewController()
            if useSignButton {
                guard tapSignButtonInCell(target) else {
                    openAttempt(useSignButton: false, retriesRemaining: retriesRemaining)
                    return
                }
            } else {
                navigateToOrderDetail(for: target, in: presenter)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                waitForDetailPush(before: before, polls: 0, retriesRemaining: retriesRemaining)
            }
        }

        func verifyDetail(polls: Int, retriesRemaining: Int) {
            let vc = UIApplication.shared.topViewController()
            if let vc, String(describing: type(of: vc)).contains("DeliveryProxySignEditorViewController") {
                dismissUnneededRelationPopupIfPresented {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        verifyDetail(polls: 0, retriesRemaining: retriesRemaining)
                    }
                }
                return
            }

            let verdict = detailMatches(vc: vc, maskedPhone: maskedPhone, name: name, waybillNo: waybillNo)

            if verdict == nil && polls < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    verifyDetail(polls: polls + 1, retriesRemaining: retriesRemaining)
                }
                return
            }

            if verdict == false {
                goBack(from: vc)
                guard retriesRemaining > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    openAttempt(useSignButton: true, retriesRemaining: retriesRemaining - 1)
                }
                return
            }

            completion()
        }

        func goBack(from vc: UIViewController?) {
            guard let vc = vc else { return }
            if let nav = vc.navigationController, nav.viewControllers.count > 1 {
                nav.popViewController(animated: true)
            } else if vc.presentingViewController != nil {
                vc.dismiss(animated: true, completion: nil)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { openAttempt(useSignButton: true, retriesRemaining: 1) }
    }

    /// Chỉ số hàng hiện tại của một thẻ trong UITableView / UICollectionView (nil nếu không xác định được).
    public static func rowIndex(ofCell view: UIView) -> Int? {
        guard let cell = findParentCell(view) else { return nil }
        if let c = cell as? UITableViewCell, let tv = findParentTableView(c), let ip = tv.indexPath(for: c) { return ip.row }
        if let c = cell as? UICollectionViewCell, let cv = findParentCollectionView(c), let ip = cv.indexPath(for: c) { return ip.item }
        return nil
    }

    @discardableResult
    private static func tapSignButtonInCell(_ cell: UIView) -> Bool {
        let target = normalizedVN("Ký nhận")
        for view in allSubviews(in: cell) {
            guard let button = view as? UIButton, button.window != nil, button.isEnabled else { continue }
            if normalizedVN(button.currentTitle) == target || normalizedVN(button.titleLabel?.text) == target {
                button.sendActions(for: .touchUpInside)
                return true
            }
        }
        return false
    }

    /// Tìm lại cell đơn hàng đang hiển thị theo dữ liệu (SĐT che / tên / mã vận đơn), không phụ thuộc vị trí hàng.
    public static func findCellMatching(maskedPhone: String, name: String, waybillNo: String, in root: UIView?, quiet _: Bool = false) -> UIView? {
        guard let root = root else { return nil }
        let phoneKey = maskedPhone.filter { $0.isNumber }

        var best: UIView? = nil
        var bestScore = 0
        for v in allSubviews(in: root) {
            guard (v is UITableViewCell || v is UICollectionViewCell), v.window != nil else { continue }
            let texts = extractAllVisibleTexts(in: v)
            let joined = texts.joined(separator: " | ")

            var score = 0
            if !waybillNo.isEmpty && joined.contains(waybillNo) { score += 4 }
            if !phoneKey.isEmpty && texts.contains(where: { $0.contains("*") && $0.filter { $0.isNumber } == phoneKey }) { score += 3 }
            if !name.isEmpty && joined.contains(name) { score += 2 }

            if score > bestScore {
                bestScore = score
                best = v
            }
        }
        if bestScore >= 3, let best = best {
            return best
        }
        return nil
    }

    public static func navigateToOrderDetail(for cellView: UIView?, in presenter: UIViewController) {
        guard let cellView = cellView else { return }

        if let cell = findParentCell(cellView) as? UITableViewCell,
           let tv = findParentTableView(cell) {
            if let indexPath = tv.indexPath(for: cell) {
                tv.selectRow(at: indexPath, animated: true, scrollPosition: .none)
                tv.delegate?.tableView?(tv, didSelectRowAt: indexPath)
                return
            }
        }

        if let cell = findParentCell(cellView) as? UICollectionViewCell,
           let cv = findParentCollectionView(cell) {
            if let indexPath = cv.indexPath(for: cell) {
                cv.selectItem(at: indexPath, animated: true, scrollPosition: [])
                cv.delegate?.collectionView?(cv, didSelectItemAt: indexPath)
                return
            }
        }

        for sub in [cellView] + allSubviews(in: cellView) {
            if let gestures = sub.gestureRecognizers {
                for g in gestures {
                    if let tap = g as? UITapGestureRecognizer {
                        tap.state = .ended
                        return
                    }
                }
            }
        }
    }

    private static func findParentCell(_ view: UIView) -> UIView? {
        var current: UIView? = view
        while let v = current {
            if v is UITableViewCell || v is UICollectionViewCell { return v }
            current = v.superview
        }
        return nil
    }

    private static func findParentTableView(_ view: UIView) -> UITableView? {
        var current: UIView? = view
        while let v = current {
            if let tv = v as? UITableView { return tv }
            current = v.superview
        }
        return nil
    }

    private static func findParentCollectionView(_ view: UIView) -> UICollectionView? {
        var current: UIView? = view
        while let v = current {
            if let cv = v as? UICollectionView { return cv }
            current = v.superview
        }
        return nil
    }

    public static func triggerGestureRecognizer(_ gesture: UIGestureRecognizer) {
        guard let targets = gesture.value(forKey: "_targets") as? [NSObject] else { return }
        for t in targets {
            guard let target = t.value(forKey: "_target") as? NSObject,
                  let actionSelector = t.value(forKey: "_action") as? Selector else { continue }
            if target.responds(to: actionSelector) {
                target.perform(actionSelector, with: gesture)
            }
        }
    }

    public static func pinWaybillInUserDefaults(_ waybillNo: String) {
        guard !waybillNo.isEmpty else { return }
        let key = "delivery_home_top_waybill_ids"
        var topList = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
        if !topList.contains(waybillNo) {
            topList.insert(waybillNo, at: 0)
            UserDefaults.standard.set(topList, forKey: key)
        }
    }

    public static func pinOrderInCell(_ cellView: UIView?, waybillNo: String = "") {
        guard let cellView = cellView, cellView.window != nil else { return }

        let pinnedKey = "delivery_home_top_waybill_ids"
        let pinnedWaybills = (UserDefaults.standard.array(forKey: pinnedKey) as? [String]) ?? []
        let isAlreadyPinned = !waybillNo.isEmpty && pinnedWaybills.contains(waybillNo)

        if !waybillNo.isEmpty {
            pinWaybillInUserDefaults(waybillNo)
        }
        guard !isAlreadyPinned else { return }

        let cardWidth = cellView.bounds.width
        let nameKeywords = ["waybill_tag", "bookmark", "ghim", "pin", "favorite", "collect"]
        let blockedKeywords = ["sign", "relation", "proxy", "call", "phone", "sms", "contact", "ký nhận", "gọi", "quan hệ"]

        // Vung nut ghim: goc tren-phai cua the (icon bookmark nho ~36pt)
        func inPinZone(_ v: UIView) -> Bool {
            guard v.bounds.width > 0, v.bounds.height > 0, v.bounds.width <= 70, v.bounds.height <= 70 else { return false }
            let c = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: cellView)
            return c.x > cardWidth * 0.82 && c.y >= 0 && c.y < 56.0
        }

        func nameOf(_ v: UIView) -> String {
            var parts: [String] = []
            if let b = v as? UIButton {
                parts.append(String(describing: b.currentImage as Any))
                parts.append(String(describing: b.backgroundImage(for: .normal) as Any))
                parts.append(b.currentTitle ?? "")
                parts.append(b.accessibilityLabel ?? "")
                parts.append(b.accessibilityIdentifier ?? "")
                parts.append((b.allTargets.flatMap { b.actions(forTarget: $0, forControlEvent: .touchUpInside) ?? [] }).joined(separator: " "))
            }
            if let iv = v as? UIImageView { parts.append(String(describing: iv.image as Any)) }
            parts.append(v.accessibilityIdentifier ?? "")
            parts.append(v.accessibilityLabel ?? "")
            return parts.joined(separator: " ").lowercased()
        }

        func isSafePinControl(_ control: UIControl) -> Bool {
            guard control.window != nil, !control.isHidden, control.alpha > 0.01, control.isEnabled else { return false }
            let metadata = nameOf(control)
            return !blockedKeywords.contains(where: metadata.contains)
        }

        func activate(_ control: UIControl) -> Bool {
            guard isSafePinControl(control) else { return false }
            control.sendActions(for: .touchUpInside)
            return true
        }

        let zoneViews = allSubviews(in: cellView).filter { $0 !== cellView && inPinZone($0) }

        // 1. Uu tien view trong vung ghim co ten/anh khop tu khoa
        for v in zoneViews where nameKeywords.contains(where: { nameOf(v).contains($0) }) {
            if let control = v as? UIControl, activate(control) { return }
            if let tap = v.gestureRecognizers?.compactMap({ $0 as? UITapGestureRecognizer }).first,
               !blockedKeywords.contains(where: nameOf(v).contains) {
                triggerGestureRecognizer(tap)
                return
            }
        }

        // Fall back only to the small control at the bookmark's known top-right position.
        let probe = CGPoint(x: cardWidth - 30, y: 24)
        var candidate = cellView.hitTest(probe, with: nil)
        while let view = candidate, view !== cellView {
            if let control = view as? UIControl, activate(control) { return }
            candidate = view.superview
        }

    }

    // MARK: - Camera OCR (nút camera ở màn chi tiết) -> quay về danh sách

    private static var signFlowToken = 0

    /// The don (cell) vua bam "Goi" con dang nam tren man hinh => dang o danh sach.
    public static func isTappedCellOnScreen() -> Bool {
        guard let tapped = lastTappedView, tapped.window != nil else { return false }
        return findParentCell(tapped) != nil
    }

    private static func normalizedVN(_ s: String?) -> String {
        return (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Tìm nút camera (nút icon, không chữ, nằm trong DeliveryCompoundDetailBottomBar) của màn chi tiết và bấm nó
    /// => app tự mở DeliverySignCaptureViewController (Camera OCR). Không bấm nút đỏ "Ký nhận" để tránh ký nhận luôn.
    @discardableResult
    public static func tapCameraButton(in vc: UIViewController?) -> Bool {
        guard let root = vc?.view else { return false }

        func inBottomBar(_ v: UIView) -> Bool {
            var cur: UIView? = v
            while let c = cur {
                if String(describing: type(of: c)).contains("BottomBar") { return true }
                cur = c.superview
            }
            return false
        }

        var candidates: [UIButton] = []
        for v in allSubviews(in: root) {
            guard let b = v as? UIButton, b.window != nil, !b.isHidden, b.alpha > 0.01,
                  b.isEnabled, b.isUserInteractionEnabled, b.bounds.width > 0, b.bounds.height > 0 else { continue }
            guard inBottomBar(b) else { continue }
            let title = (b.currentTitle ?? b.titleLabel?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.isEmpty, allLabels(in: b).isEmpty else { continue }
            candidates.append(b)
        }

        // Xác định nút theo selector (lấy từ log): camera = "handleCameraTap", checkbox "Chọn tất cả" = "handleSelectAllTap"
        func hasAction(_ b: UIButton, _ name: String) -> Bool {
            for t in b.allTargets {
                let acts = b.actions(forTarget: t, forControlEvent: .touchUpInside) ?? []
                if acts.contains(name) { return true }
            }
            return false
        }

        if let exact = candidates.first(where: { hasAction($0, "handleCameraTap") }) {
            exact.sendActions(for: .touchUpInside)
            return true
        }

        // Dự phòng: nút vuông nhỏ nhất, nhưng loại checkbox "Chọn tất cả"
        let fallback = candidates.filter { !hasAction($0, "handleSelectAllTap") }
        guard let camera = fallback.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            return false
        }
        camera.sendActions(for: .touchUpInside)
        return true
    }

    /// Bam "Ky nhan" (co thu lai vai lan cho man hinh san sang), roi theo doi den khi OCR luu xong de ve danh sach.
    public static func tapSignButtonAndWatch(from host: UIViewController, completion: @escaping (Bool) -> Void, onSaved: ((UIViewController) -> Void)? = nil) {
        signFlowToken += 1
        let token = signFlowToken
        var attempts = 0

        func attempt() {
            guard token == signFlowToken else { return }
            let vc = UIApplication.shared.topViewController() ?? host
            if tapCameraButton(in: vc) {
                completion(true)
                watchSignFlow(detailVC: vc, token: token, onSaved: onSaved)
                return
            }
            attempts += 1
            if attempts < 15 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { attempt() }
            } else {
                completion(false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt() }
    }

    /// Theo dõi màn hình chụp ảnh đến khi đóng và chạy tiếp luồng sau khi lưu.
    private static func watchSignFlow(detailVC: UIViewController, token: Int, onSaved: ((UIViewController) -> Void)? = nil) {
        weak var weakDetail: UIViewController? = detailVC
        var sawOther = false
        var ticks = 0

        func tick() {
            guard token == signFlowToken else { return }
            ticks += 1
            guard ticks <= 2500 else { return }

            let top = UIApplication.shared.topViewController()
            let topName = top.map { String(describing: type(of: $0)) } ?? "<none>"

            guard let detail = weakDetail else { return }

            var ancestor = top
            var captureStillActive = false
            while let controller = ancestor {
                if String(describing: type(of: controller)).contains("SignCapture") {
                    captureStillActive = true
                    break
                }
                ancestor = controller.presentingViewController
            }
            if topName.contains("SignCapture") { sawOther = true }
            let returnedToDetail = top === detail
            let detailWasRemoved = top !== detail && detail.isViewLoaded && detail.view.window == nil && !captureStillActive
            if sawOther && (returnedToDetail || detailWasRemoved) {
                signFlowToken += 1
                if let onSaved = onSaved {
                    onSaved(detail)
                    return
                }
                if let nav = detail.navigationController {
                    nav.popToRootViewController(animated: true)
                } else {
                    detail.dismiss(animated: true, completion: nil)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { tick() }
    }

    public static func findTargetCellOrCardView(for sheet: UIViewController, in presenter: UIViewController) -> UIView? {
        if let tapped = lastTappedView {
            if let cell = findParentCell(tapped) {
                return cell
            }
            if tapped.bounds.height > 80 && tapped.bounds.width > 200 && tapped != presenter.view {
                return tapped
            }
        }

        if let sourceView = sheet.popoverPresentationController?.sourceView {
            var current: UIView? = sourceView
            while let view = current {
                if view is UITableViewCell || view is UICollectionViewCell {
                    return view
                }
                if view.bounds.height > 80 && view.bounds.width > 200 && view != presenter.view {
                    return view
                }
                current = view.superview
            }
            return sourceView
        }

        if let view = presenter.view {
            if let cell = findSelectedCell(in: view) {
                return cell
            }
        }

        return nil
    }

    private static func findSelectedCell(in view: UIView) -> UIView? {
        if let tv = view as? UITableView {
            if let indexPath = tv.indexPathForSelectedRow, let cell = tv.cellForRow(at: indexPath) {
                return cell
            }
            for cell in tv.visibleCells {
                if cell.isHighlighted || cell.isSelected {
                    return cell
                }
            }
        }
        if let cv = view as? UICollectionView {
            if let indexPaths = cv.indexPathsForSelectedItems, let first = indexPaths.first, let cell = cv.cellForItem(at: first) {
                return cell
            }
            for cell in cv.visibleCells {
                if cell.isHighlighted || cell.isSelected {
                    return cell
                }
            }
        }
        for sub in view.subviews {
            if let cell = findSelectedCell(in: sub) {
                return cell
            }
        }
        return nil
    }

    private static func findLabelProperties(in view: UIView, font: inout UIFont?, color: inout UIColor?) {
        if let label = view as? UILabel {
            if font == nil { font = label.font }
            if color == nil { color = label.textColor }
            return
        }
        if let btn = view as? UIButton {
            if font == nil { font = btn.titleLabel?.font }
            if color == nil { color = btn.titleColor(for: .normal) }
            return
        }
        for sub in view.subviews {
            findLabelProperties(in: sub, font: &font, color: &color)
            if font != nil && color != nil { break }
        }
    }

    public static func fallbackSendSTK(from presenter: UIViewController) {
        let (phone, amount) = extractPhoneAndAmountFromViews(in: presenter)
        let workflow = HNCompactWorkflow.shared

        let finalPhone = phone.isEmpty ? workflow.currentPhoneNumber : phone
        let finalAmount = amount == "0" ? workflow.currentCodAmount : amount

        if !finalPhone.isEmpty && !finalPhone.contains("*") {
            workflow.sendSTKQuick(
                phoneNumber: finalPhone,
                codAmountText: finalAmount,
                barCodeListStr: workflow.currentBarCodeListStr,
                from: presenter
            )
        } else {
            workflow.currentCodAmount = finalAmount
            showQuickSTKInputDialog(from: presenter)
        }
    }

    public static func showQuickSTKInputDialog(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "Gửi STK",
            message: "Xác nhận số điện thoại và số tiền người nhận",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Số điện thoại người nhận"
            field.keyboardType = .phonePad
            let currentPhone = HNCompactWorkflow.shared.currentPhoneNumber
            field.text = currentPhone.contains("*") ? "" : currentPhone
        }
        alert.addTextField { field in
            field.placeholder = "Số tiền COD (ví dụ: 190,000)"
            field.keyboardType = .decimalPad
            let currentAmount = HNCompactWorkflow.shared.currentCodAmount
            field.text = currentAmount == "0" ? "" : currentAmount
        }

        alert.addAction(UIAlertAction(title: "Gửi", style: .default) { _ in
            guard let phone = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let amount = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !phone.isEmpty else {
                return
            }

            HNCompactWorkflow.shared.sendSTKQuick(
                phoneNumber: phone,
                codAmountText: amount,
                barCodeListStr: HNCompactWorkflow.shared.currentBarCodeListStr,
                from: presenter
            )
        })
        alert.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
        presenter.present(alert, animated: true)
    }

    public static func extractWaybillNo(from vc: UIViewController?) -> String {
        guard let vc = vc else { return "" }

        var mirrorClass: AnyClass? = type(of: vc)
        while let cls = mirrorClass, cls != UIViewController.self {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(cls, &count) {
                for i in 0..<Int(count) {
                    let ivar = ivars[i]
                    guard let nameCStr = ivar_getName(ivar) else { continue }
                    let name = String(cString: nameCStr).lowercased()
                    if name.contains("waybill") || name.contains("billno") || name.contains("orderno") || name.contains("expressno") {
                        if let value = object_getIvar(vc, ivar) as? String, !value.isEmpty {
                            free(ivars)
                            return value
                        }
                    }
                }
                free(ivars)
            }
            mirrorClass = class_getSuperclass(cls)
        }

        if let view = vc.view {
            let labels = allLabels(in: view)
            for label in labels {
                let text = label.text ?? ""
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = clean.filter { $0.isNumber }
                if digits.count >= 10 && digits.count <= 16 {
                    return digits
                }
            }
        }

        return ""
    }

    public static func extractAllVisibleTexts(in view: UIView) -> [String] {
        var text: [String] = []
        if let label = view as? UILabel, let value = label.text, !value.isEmpty {
            text.append(value)
        }
        if let button = view as? UIButton, let value = button.currentTitle, !value.isEmpty {
            text.append(value)
        }
        if let value = view.accessibilityLabel, !value.isEmpty {
            text.append(value)
        }
        return text + view.subviews.flatMap { extractAllVisibleTexts(in: $0) }
    }

    public static func extractPhoneAndAmountFromViews(in vc: UIViewController?) -> (phone: String, amount: String) {
        guard let vc = vc, let view = vc.view else { return ("", "0") }

        var phone = ""
        var amount = "0"

        let labels = allLabels(in: view)
        for label in labels {
            let text = label.text ?? ""
            if text.isEmpty { continue }

            if amount == "0" {
                let clean = text.replacingOccurrences(of: "VND", with: "")
                                .replacingOccurrences(of: "VNĐ", with: "")
                                .replacingOccurrences(of: "đ", with: "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = clean.filter { $0.isNumber }
                if !digits.isEmpty && (text.contains("đ") || text.contains(",") || text.contains(".")) {
                    if let num = Int(digits), num > 100 {
                        amount = "\(num)"
                    }
                }
            }

            if phone.isEmpty {
                let digits = text.filter { $0.isNumber }
                if digits.count >= 10 && digits.count <= 11 && (digits.hasPrefix("0") || digits.hasPrefix("84")) {
                    phone = digits
                }
            }
        }

        return (phone, amount)
    }

    private static func allLabels(in view: UIView) -> [UILabel] {
        var results: [UILabel] = []
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            results.append(label)
        }
        for sub in view.subviews {
            results.append(contentsOf: allLabels(in: sub))
        }
        return results
    }

    private static func visibleText(in view: UIView) -> [String] {
        var text: [String] = []
        if let label = view as? UILabel, let value = label.text {
            text.append(value)
        }
        if let button = view as? UIButton, let value = button.currentTitle {
            text.append(value)
        }
        if let value = view.accessibilityLabel {
            text.append(value)
        }
        return text + view.subviews.flatMap { visibleText(in: $0) }
    }

    private static func allSubviews(in view: UIView) -> [UIView] {
        var list: [UIView] = [view]
        for sub in view.subviews {
            list.append(contentsOf: allSubviews(in: sub))
        }
        return list
    }

    public static func hasPODPhoto(for waybillNo: String) -> Bool {
        let fileManager = FileManager.default

        let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? ""
        let photoStoreDir = (appSupport as NSString).appendingPathComponent("DeliveryCompoundDetailPhotoStore")

        if fileManager.fileExists(atPath: photoStoreDir) {
            if let files = try? fileManager.contentsOfDirectory(atPath: photoStoreDir), !files.isEmpty {
                for f in files {
                    if f.lowercased().hasSuffix(".jpg") || f.lowercased().hasSuffix(".png") {
                        let fullPath = (photoStoreDir as NSString).appendingPathComponent(f)
                        if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                           let modDate = attrs[.modificationDate] as? Date {
                            if Date().timeIntervalSince(modDate) < 24 * 3600 {
                                return true
                            }
                        }
                    }
                }
            }
        }

        let cacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
        let docDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""

        for dir in [cacheDir, docDir] {
            let subDir = (dir as NSString).appendingPathComponent("DeliveryCompoundDetailPhotoStore")
            if fileManager.fileExists(atPath: subDir) {
                if let files = try? fileManager.contentsOfDirectory(atPath: subDir), !files.isEmpty {
                    return true
                }
            }
        }

        return false
    }

    public static func showToast(message: String, in containerView: UIView) {
        let toastLabel = UILabel()
        toastLabel.text = message
        toastLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.layer.cornerRadius = 14
        toastLabel.clipsToBounds = true
        toastLabel.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(toastLabel)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            toastLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor, constant: -40),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor, constant: 24),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -24),
            toastLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])

        UIView.animate(withDuration: 0.3, delay: 2.8, options: .curveEaseOut, animations: {
            toastLabel.alpha = 0.0
        }) { _ in
            toastLabel.removeFromSuperview()
        }
    }
}

// MARK: - UIApplication Extension

extension UIApplication {
    static var isSendEventSwizzled = false

    static func swizzleSendEvent() {
        guard !isSendEventSwizzled else { return }
        isSendEventSwizzled = true

        let cls = UIApplication.self
        if let orig = class_getInstanceMethod(cls, #selector(UIApplication.sendEvent(_:))),
           let swiz = class_getInstanceMethod(cls, #selector(UIApplication.hn_sendEvent(_:))) {
            method_exchangeImplementations(orig, swiz)
        }
    }

    @objc func hn_sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touch = event.allTouches?.first, touch.phase == .began {
            if let touchedView = touch.view {
                let className = String(describing: type(of: touchedView))
                // Chi ghi nho view khi cham TRUNG vao mot cell (the don hang).
                // Cham vao sheet / HN Flash / alert / nut HN khong duoc ghi de, neu khong se mat the dang chon.
                var ancestor: UIView? = touchedView
                var insideCell = false
                while let v = ancestor {
                    if v is UITableViewCell || v is UICollectionViewCell { insideCell = true; break }
                    ancestor = v.superview
                }
                if insideCell && !className.contains("HNFloatingMenu") {
                    HNJTSheetHook.lastTappedView = touchedView
                }
            }
        }
        hn_sendEvent(event)
    }

    @objc public func topViewController(_ base: UIViewController? = nil) -> UIViewController? {
        let baseVC = base ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
        if let nav = baseVC as? UINavigationController {
            return topViewController(nav.visibleViewController)
        }
        if let tab = baseVC as? UITabBarController {
            return topViewController(tab.selectedViewController)
        }
        if let presented = baseVC?.presentedViewController {
            return topViewController(presented)
        }
        return baseVC
    }
}

// MARK: - HN Flash gắn thẳng trên thẻ đơn (cạnh nút "Ký nhận")

extension HNJTSheetHook {
    fileprivate static let cellFlashButtonId = "hnmod-cell-flash"

    /// Gắn nút "Flash ⚡" ngay trước nút "Ký nhận" trong thẻ đơn của danh sách.
    fileprivate static func injectCellFlashButton(into cell: UITableViewCell) {
        if (objc_getAssociatedObject(cell, &HNJTSheetAssociations.cellFlashButtonKey) as? UIButton)?.superview != nil {
            return
        }

        let signButton = allSubviews(in: cell.contentView)
            .compactMap { $0 as? UIButton }
            .first { b in
                b.allTargets.contains { t in
                    (b.actions(forTarget: t, forControlEvent: .touchUpInside) ?? []).contains("handleSignTap")
                }
            }
        guard let signButton = signButton, let stack = signButton.superview as? UIStackView else { return }

        let thin = signButton.subviews.first { $0.bounds.width > 0 && $0.bounds.width <= 2.5 && $0.bounds.height > 10 }
        let thinColor = thin?.backgroundColor ?? UIColor(white: 0.867, alpha: 1)
        let thinWidth = max(thin?.bounds.width ?? 0, 1)

        // Nút "Zalo/SMS" (chạy luồng HN Flash rồi chọn Zalo hoặc SMS)
        let flash = UIButton(type: .custom)
        flash.accessibilityIdentifier = cellFlashButtonId
        flash.setTitle("ZSMS", for: .normal)
        flash.setTitleColor(UIColor(red: 0.0, green: 0.5, blue: 0.8, alpha: 1.0), for: .normal)
        flash.titleLabel?.font = signButton.titleLabel?.font ?? UIFont.systemFont(ofSize: 15)
        flash.titleLabel?.adjustsFontSizeToFitWidth = true
        flash.titleLabel?.minimumScaleFactor = 0.6
        flash.backgroundColor = signButton.backgroundColor
        flash.layer.borderWidth = signButton.layer.borderWidth
        flash.layer.borderColor = signButton.layer.borderColor

        let target = HNJTSheetHNFlashTarget()
        flash.addTarget(target, action: #selector(HNJTSheetHNFlashTarget.runHNFlashFlow), for: .touchUpInside)
        objc_setAssociatedObject(flash, &HNJTSheetAssociations.cellFlashTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let sep = UIView()
        sep.isUserInteractionEnabled = false
        sep.backgroundColor = thinColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        flash.addSubview(sep)
        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: flash.leadingAnchor),
            sep.topAnchor.constraint(equalTo: flash.topAnchor),
            sep.bottomAnchor.constraint(equalTo: flash.bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: thinWidth)
        ])

        let index = stack.arrangedSubviews.firstIndex(of: signButton) ?? stack.arrangedSubviews.count
        stack.insertArrangedSubview(flash, at: index)
        objc_setAssociatedObject(cell, &HNJTSheetAssociations.cellFlashButtonKey, flash, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

extension UITableViewCell {
    private static var isHNFlashLayoutSwizzled = false

    static func swizzleLayoutForHNFlash() {
        guard !isHNFlashLayoutSwizzled else { return }
        isHNFlashLayoutSwizzled = true

        if let orig = class_getInstanceMethod(UITableViewCell.self, #selector(UITableViewCell.layoutSubviews)),
           let swiz = class_getInstanceMethod(UITableViewCell.self, #selector(UITableViewCell.hn_layoutSubviews)) {
            method_exchangeImplementations(orig, swiz)
        }
    }

    @objc func hn_layoutSubviews() {
        hn_layoutSubviews() // sau khi swizzle: gọi layoutSubviews gốc
        if String(describing: type(of: self)).contains("DeliveryHomeCompoundCell") {
            HNJTSheetHook.injectCellFlashButton(into: self)
            HNJTSheetHook.updateZaloBadge(in: self)
        }
    }
}

// MARK: - Gửi Zalo / SMS (gộp HN Flash + Gửi Zalo, chọn kênh theo HNZaloConfig)

/// Sau khi mở Zalo, đợi người dùng quay lại app rồi hỏi có Ký nhận luôn không
/// (Zalo không báo lại là đã gửi hay chưa nên phải hỏi).
private final class HNZaloReturnWatcher {
    private static var current: HNZaloReturnWatcher?
    private var observers: [NSObjectProtocol] = []
    private var wentBackground = false
    private let onReturn: () -> Void

    private init(onReturn: @escaping () -> Void) {
        self.onReturn = onReturn
    }

    static func start(onReturn: @escaping () -> Void) {
        current?.stop()
        let watcher = HNZaloReturnWatcher(onReturn: onReturn)
        current = watcher
        watcher.begin()
    }

    static func cancel() {
        current?.stop()
    }

    private func begin() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wentBackground = true
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.wentBackground else { return }
            let callback = self.onReturn
            self.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: callback)
        })
        // Mở Zalo thất bại (app không bao giờ xuống nền) -> dọn observer
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, !self.wentBackground else { return }
            self.stop()
        }
    }

    private func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if HNZaloReturnWatcher.current === self { HNZaloReturnWatcher.current = nil }
    }
}

extension HNJTSheetHook {

    /// Điểm vào duy nhất cho "Gửi Zalo/SMS". `phone` phải là SĐT đầy đủ (không có dấu *).
    /// Tra HNZaloConfig: có Zalo -> ảnh QR + mở Zalo; không có -> SMS (luồng STK cũ);
    /// chưa có trong cấu hình -> hỏi 1 lần rồi ghi nhớ.
    static func dispatchZaloOrSMS(phone: String,
                                  waybillNo: String,
                                  orders: [(waybillNo: String, amountText: String, goodsName: String)] = [],
                                  name: String = "",
                                  from vc: UIViewController) {
        let workflow = HNCompactWorkflow.shared
        let targetPhone = HNZaloConfig.shared.effectivePhone(phone)

        let sendSMS = {
            workflow.autoOcrPending = true
            workflow.sendSTKQuick(
                phoneNumber: targetPhone,
                codAmountText: workflow.currentCodAmount,
                barCodeListStr: waybillNo.isEmpty ? workflow.currentBarCodeListStr : waybillNo,
                from: vc
            )
        }
        let sendZalo = {
            // Giữ SĐT GỐC trong workflow (Update SĐT / Copy SĐT về sau còn tra đúng khách); Zalo mở bằng targetPhone
            workflow.currentPhoneNumber = phone
            HNJTSheetHook.sendViaZalo(phone: targetPhone, waybillNo: waybillNo, orders: orders, from: vc)
        }

        // Đã nhập SĐT backup/Zalo cho khách => gửi Zalo tới số đó, không hỏi lại "có Zalo không" cho số backup
        let hasBackup = HNZaloConfig.shared.getBackupPhone(phone) != nil
        let known = HNZaloConfig.shared.hasZalo(targetPhone) ?? (hasBackup ? true : nil)
        HNLog.write("Zalo/SMS: targetPhone=\(targetPhone) (gốc=\(phone)) kênh=\(known == nil ? "chưa có trong cấu hình" : (known! ? "Zalo" : "SMS")) waybill=\(waybillNo.isEmpty ? "EMPTY" : waybillNo)")

        if let hasZalo = known {
            if hasZalo { sendZalo() } else { sendSMS() }
            return
        }

        // Chưa biết khách này có Zalo không -> hỏi 1 lần, nhớ vào file cấu hình
        let host = UIApplication.shared.topViewController() ?? vc
        let customerName = name.isEmpty ? workflow.currentReceiverName : name
        let sheet = UIAlertController(
            title: "Khách này có Zalo không?",
            message: "Chọn 1 lần, app sẽ nhớ cho SĐT này (lưu trong \(HNZaloConfig.fileName)).",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "💬 Có Zalo - gửi Zalo", style: .default) { _ in
            HNZaloConfig.shared.setZalo(targetPhone, true, name: customerName)
            HNJTSheetHook.refreshZaloBadges()
            sendZalo()
        })
        sheet.addAction(UIAlertAction(title: "✉️ Không có - gửi SMS", style: .default) { _ in
            HNZaloConfig.shared.setZalo(targetPhone, false, name: customerName)
            HNJTSheetHook.refreshZaloBadges()
            sendSMS()
        })
        sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        host.present(sheet, animated: true)
    }

    /// Dựng QR thanh toán chỉ cho đúng đơn đang chọn (không tự động gộp các đơn khác của cùng SĐT).
    private static func sendViaZalo(phone: String,
                                    waybillNo: String,
                                    orders: [(waybillNo: String, amountText: String, goodsName: String)],
                                    from vc: UIViewController) {
        let workflow = HNCompactWorkflow.shared

        let retryLastQR: () -> Bool = {
            guard let retry = HNZaloQRRetryCache.entry(forWaybill: waybillNo, phone: phone) else { return false }
            HNLog.write("Zalo QR: dùng lại ảnh đã tạo cho vận đơn \(waybillNo)")
            performSendViaZalo(phone: phone, waybillNo: waybillNo, orders: [], from: vc, existingQR: retry.image, existingAmount: retry.amount)
            return true
        }

        var candidates = orders
        if candidates.isEmpty, !waybillNo.isEmpty {
            let cachedTarget = workflow.cachedOrderInfo(forWaybill: waybillNo)
            let amount = cachedTarget?.codAmount ?? workflow.currentCodAmount
            let goods = cachedTarget?.goodsName ?? ""
            candidates = [(waybillNo: waybillNo, amountText: amount, goodsName: goods)]
        }

        var seenWaybills = Set<String>()
        candidates = candidates.compactMap { order in
            let wb = order.waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wb.isEmpty,
                  workflow.cachedSignedStatus(forWaybill: wb) != true,
                  seenWaybills.insert(wb).inserted else { return nil }
            return (waybillNo: wb, amountText: order.amountText, goodsName: order.goodsName)
        }

        if candidates.isEmpty, retryLastQR() { return }

        guard !candidates.isEmpty else {
            showZaloSendError("Không tìm thấy thông tin đơn hàng để tạo QR.")
            return
        }

        let kept = candidates.filter { workflow.cachedSignedStatus(forWaybill: $0.waybillNo) != true }
        guard !kept.isEmpty else {
            if retryLastQR() { return }
            showZaloSendError("Đơn hàng này đã ký nhận; không tạo QR thanh toán.")
            return
        }

        performSendViaZalo(phone: phone, waybillNo: waybillNo, orders: kept, from: vc)
    }

    private static func showZaloSendError(_ message: String) {
        guard let presenter = UIApplication.shared.topViewController() else {
            HNLog.write("Zalo QR error: \(message)")
            return
        }
        let alert = UIAlertController(title: "Không thể tạo QR", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    /// Copy ảnh QR (đúng số tiền, tài khoản trong cài đặt) -> mở Zalo tới số khách -> bạn chỉ cần Dán + Gửi.
    private static func performSendViaZalo(phone: String,
                                    waybillNo: String,
                                    orders: [(waybillNo: String, amountText: String, goodsName: String)],
                                    from vc: UIViewController,
                                    existingQR: UIImage? = nil,
                                    existingAmount: Int? = nil) {
        let workflow = HNCompactWorkflow.shared

        let list = orders.filter { workflow.cachedSignedStatus(forWaybill: $0.waybillNo) != true }

        var cleanPhone = phone.filter(\.isNumber)
        if cleanPhone.hasPrefix("84") {
            cleanPhone = "0" + String(cleanPhone.dropFirst(2))
        } else if !cleanPhone.hasPrefix("0") {
            cleanPhone = "0" + cleanPhone
        }

        // Để lúc quay lại app Ký nhận đúng đơn đang mở (SĐT gốc đã được giữ ở dispatchZaloOrSMS)
        if !waybillNo.isEmpty { workflow.currentBarCodeListStr = waybillNo }

        // Mở Zalo; khi quay lại app thì gọi onReturn
        let openZalo: (@escaping () -> Void) -> Void = { onReturn in
            var profileComponents = URLComponents()
            profileComponents.scheme = "https"
            profileComponents.host = "zalo.me"
            profileComponents.path = "/\(cleanPhone)"
            guard let profileURL = profileComponents.url else {
                if let top = UIApplication.shared.topViewController() {
                    HNJTSheetHook.showToast(message: "Không tạo được liên kết Zalo. Ảnh QR vẫn đang ở clipboard.", in: top.view)
                }
                return
            }

            HNZaloReturnWatcher.start(onReturn: onReturn)
            HNLog.write("Zalo handoff: opening https://zalo.me/<phone> directly.")
            UIApplication.shared.open(profileURL, options: [:]) { opened in
                HNLog.write("Zalo handoff: direct HTTPS open result=\(opened).")
                guard !opened else { return }
                HNZaloReturnWatcher.cancel()
                if let top = UIApplication.shared.topViewController() {
                    HNJTSheetHook.showToast(message: "Không mở được liên kết https://zalo.me. Ảnh QR vẫn đang ở clipboard.", in: top.view)
                }
            }
        }

        if let existingQR = existingQR {
            let copiedWhat = "ảnh QR \(HNVietQRBuilder.formatVND(existingAmount ?? 0)) đ"
            UIPasteboard.general.image = existingQR
            showToast(message: "Đã copy \(copiedWhat). Đang mở khách trong Zalo; ảnh sẽ tự dán khi vào chat.", in: (UIApplication.shared.topViewController() ?? vc).view)
            openZalo({})
            return
        }

        guard !list.isEmpty else {
            showZaloSendError("Không tìm thấy đơn COD chưa ký để tạo QR.")
            return
        }

        let bankConfig = (name: HNBankConfig.bankName, account: HNBankConfig.accountNumber, owner: HNBankConfig.accountName)
        guard let prepared = prepareZaloQRData(for: list, bankConfig: bankConfig) else {
            showZaloSendError("Không tạo được ảnh QR. Kiểm tra ngân hàng, số tài khoản và COD của các đơn chưa ký.")
            return
        }

        let totalAmount = prepared.totalAmount
        let copiedWhat = "ảnh QR \(HNVietQRBuilder.formatVND(totalAmount)) đ"

        // Dựng ảnh QR + lưu cache ở background song song với việc mở camera (tránh block main thread)
        let qrGroup = DispatchGroup()
        var renderedQR: UIImage?
        qrGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            if let img = renderZaloQRBill(prepared) {
                renderedQR = img
                HNZaloQRRetryCache.save(image: img, phone: phone, waybillNo: waybillNo, amount: totalAmount)
            }
            qrGroup.leave()
        }

        let deliverQRAndOpenZalo: (Bool, @escaping () -> Void) -> Void = { shouldMarkSigned, onReturn in
            let finishWithImage: () -> Void = {
                guard let qrBillImage = renderedQR else {
                    HNLog.write("Zalo QR: không tạo được ảnh (amount=\(totalAmount), bank=\(bankConfig.name))")
                    showZaloSendError("Không tạo được ảnh QR. Kiểm tra ngân hàng, số tài khoản và COD của các đơn chưa ký.")
                    return
                }
                UIPasteboard.general.image = qrBillImage
                showToast(message: "Đã copy \(copiedWhat). Đang mở khách trong Zalo; ảnh sẽ tự dán khi vào chat.", in: (UIApplication.shared.topViewController() ?? vc).view)
                if shouldMarkSigned {
                    // Mark signed only after the QR image has been copied.
                    workflow.didSign(waybills: [waybillNo], recheck: list.map { $0.waybillNo })
                }
                openZalo(onReturn)
            }

            if qrGroup.wait(timeout: .now()) == .success {
                finishWithImage()
            } else {
                qrGroup.notify(queue: .main, execute: finishWithImage)
            }
        }

        // Luồng mới: Chi tiết -> Mở Chụp Ảnh -> Save -> Copy QR -> Zalo -> quay lại app thì tự về Danh sách
        // Tránh observer cũ (handleOCRSavedNotification) tự về danh sách sớm trước khi gửi Zalo
        NotificationCenter.default.removeObserver(workflow, name: NSNotification.Name("HNOCRSavedSuccessNotification"), object: nil)

        let host = UIApplication.shared.topViewController() ?? vc
        HNJTSheetHook.tapSignButtonAndWatch(from: host, completion: { found in
            guard !found else { return }
            deliverQRAndOpenZalo(false, {})
        }, onSaved: { detail in
            weak var weakDetail: UIViewController? = detail
            deliverQRAndOpenZalo(true) {
                guard let d = weakDetail else { return }
                if let nav = d.navigationController {
                    nav.popToRootViewController(animated: true)
                } else if d.presentingViewController != nil {
                    d.dismiss(animated: true, completion: nil)
                }
            }
        })
    }
}

// MARK: - Icon "Z" xanh cạnh nút ghim cho đơn của khách có Zalo

extension HNJTSheetHook {
    fileprivate static let zaloBadgeId = "hnmod-zalo-badge"

    /// Vẽ lại icon trên mọi thẻ đơn đang hiển thị (sau khi đổi cấu hình Zalo).
    static func refreshZaloBadges() {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
        func walk(_ view: UIView) {
            if let cell = view as? UITableViewCell, String(describing: type(of: cell)).contains("DeliveryHomeCompoundCell") {
                objc_setAssociatedObject(cell, &HNJTSheetAssociations.zaloBadgeSignatureKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                cell.setNeedsLayout()
                return
            }
            view.subviews.forEach(walk)
        }
        walk(window)
    }

    /// View nhỏ nằm ở góc trên-phải thẻ (tab nút ghim); lấy view ngoài cùng bên trái để đặt icon sát bên trái nó.
    private static func zaloBadgeAnchor(in root: UIView) -> UIView? {
        let width = root.bounds.width
        guard width > 0 else { return nil }
        var best: (view: UIView, minX: CGFloat)?
        for view in allSubviews(in: root) where view !== root && view.accessibilityIdentifier != zaloBadgeId {
            guard !view.isHidden, view.alpha > 0.01,
                  view.bounds.width >= 20, view.bounds.width <= 70,
                  view.bounds.height >= 20, view.bounds.height <= 70 else { continue }
            let frame = view.convert(view.bounds, to: root)
            guard frame.midX > width * 0.82, frame.midY >= 0, frame.midY < 56 else { continue }
            if best == nil || frame.minX < best!.minX { best = (view, frame.minX) }
        }
        return best?.view
    }

    fileprivate static func updateZaloBadge(in cell: UITableViewCell) {
        let root = cell.contentView
        let details = extractCellOrderDetails(from: root)
        let signature = "\(details.name)|\(details.maskedPhone)|\(details.waybillNo)|\(HNZaloConfig.shared.currentVersion)"
        if let last = objc_getAssociatedObject(cell, &HNJTSheetAssociations.zaloBadgeSignatureKey) as? String, last == signature {
            return
        }

        // Có SĐT đầy đủ (đã giải mã) thì tra chính xác, không thì khớp tên + số cuối
        let workflow = HNCompactWorkflow.shared
        var fullPhone: String? = nil
        let texts = extractAllVisibleTexts(in: root)
        if let order = workflow.findCachedOrder(maskedPhone: details.maskedPhone, name: details.name, textInViews: texts) {
            fullPhone = workflow.decryptedPhone(forWaybill: order.waybillId)
        }
        let hasZalo = HNZaloConfig.shared.cellHasZalo(name: details.name, maskedPhone: details.maskedPhone, fullPhone: fullPhone)

        var badge = objc_getAssociatedObject(cell, &HNJTSheetAssociations.zaloBadgeKey) as? UILabel
        if hasZalo && badge?.superview == nil {
            guard let anchor = zaloBadgeAnchor(in: root) else { return } // chưa dựng xong thẻ -> thử lại ở lần layout sau

            let label = UILabel()
            label.accessibilityIdentifier = zaloBadgeId
            label.text = "Z"
            label.font = UIFont.systemFont(ofSize: 10, weight: .heavy)
            label.textColor = .white
            label.textAlignment = .center
            label.backgroundColor = UIColor(red: 0.0, green: 0.41, blue: 1.0, alpha: 1.0)
            label.layer.cornerRadius = 4
            label.alpha = 0.6
            label.clipsToBounds = true
            label.isUserInteractionEnabled = false
            label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(label)
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalToConstant: 16),
                label.heightAnchor.constraint(equalToConstant: 16),
                label.trailingAnchor.constraint(equalTo: anchor.leadingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: anchor.centerYAnchor)
            ])
            objc_setAssociatedObject(cell, &HNJTSheetAssociations.zaloBadgeKey, label, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            badge = label
        }
        badge?.isHidden = !hasZalo
        objc_setAssociatedObject(cell, &HNJTSheetAssociations.zaloBadgeSignatureKey, signature, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}