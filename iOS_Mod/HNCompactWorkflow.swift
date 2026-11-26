//
//  HNCompactWorkflow.swift
//  Runner - Compact Workflow Mod for iOS
//

import UIKit
import MessageUI

public struct CachedOrderInfo {
    public let waybillId: String
    public let receiverName: String
    public let maskedPhone: String
    public let encPhone: String
    public let codAmount: String
    public let taxAfterFee: String
    public let goodsName: String
    public let address: String
    public let isSigned: Bool

    public init(waybillId: String, receiverName: String, maskedPhone: String, encPhone: String, codAmount: String, taxAfterFee: String = "0", goodsName: String = "", address: String = "", isSigned: Bool = false) {
        self.waybillId = waybillId
        self.receiverName = receiverName
        self.maskedPhone = maskedPhone
        self.encPhone = encPhone
        self.codAmount = codAmount
        self.taxAfterFee = taxAfterFee
        self.goodsName = goodsName
        self.address = address
        self.isSigned = isSigned
    }
}

public struct JTPayResponseData {
    public let paymentReferenceId: Int64?
    public let totalMoney: Int
    public let payload: String
    public let customerCode: String
    public let createTime: String
    public let expireTime: String

    public init(paymentReferenceId: Int64?, totalMoney: Int, payload: String, customerCode: String, createTime: String, expireTime: String) {
        self.paymentReferenceId = paymentReferenceId
        self.totalMoney = totalMoney
        self.payload = payload
        self.customerCode = customerCode
        self.createTime = createTime
        self.expireTime = expireTime
    }
}

@objc(HNCompactWorkflow)
public class HNCompactWorkflow: NSObject, MFMessageComposeViewControllerDelegate {

    @objc public static let shared = HNCompactWorkflow()

    /// Flag indicating whether auto OCR should be triggered after SMS flow
    @objc public var autoOcrPending: Bool = false

    /// Cached bar code list for multi/single order OCR
    @objc public var currentBarCodeListStr: String = ""

    /// Current phone and COD used for the quick STK SMS flow
    @objc public var currentPhoneNumber: String = ""
    @objc public var currentCodAmount: String = "0"

    /// Current receiver name captured from J&T detail API
    @objc public var currentReceiverName: String = ""

    /// Current receiver address
    @objc public var currentAddress: String = ""

    /// Current J&T waybill number used to auto-load detail
    @objc public var currentWaybillNo: String = ""

    /// Token đăng nhập thật của app (bắt từ chính request của app tới J&T, xem HNURLProtocol).
    /// Chưa bắt được thì dùng token cũ làm dự phòng.
    private static let fallbackAuthToken = "bb595975a7684522b99a753c8bc08e6e"
    private var liveAuthToken: String?

    var currentAuthToken: String {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }
        return liveAuthToken ?? HNCompactWorkflow.fallbackAuthToken
    }

    @objc public func updateLiveAuthToken(_ token: String) {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != HNCompactWorkflow.fallbackAuthToken else { return }
        cachedOrdersLock.lock()
        let changed = liveAuthToken != clean
        liveAuthToken = clean
        cachedOrdersLock.unlock()
        if changed { HNLog.write("HNAuth: đã bắt authToken mới từ app (\(clean.count) ký tự)") }
    }

    private(set) public var capturedJtHeaders: [String: String] = [:]

    @objc public func updateCapturedJtHeaders(_ headers: [String: String]) {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }
        for (k, v) in headers {
            if !k.isEmpty && !v.isEmpty {
                capturedJtHeaders[k] = v
            }
        }
    }

    @objc public func resetState() {
        currentPhoneNumber = ""
        currentCodAmount = "0"
        currentReceiverName = ""
        currentAddress = ""
        currentWaybillNo = ""
        currentBarCodeListStr = ""
        autoOcrPending = false
    }

    // MARK: - Order Cache from List & Decryption APIs

    private var cachedOrdersLock = NSLock()
    public var cachedOrdersByWaybill: [String: CachedOrderInfo] = [:]
    public var cachedOrdersByMaskedPhone: [String: [CachedOrderInfo]] = [:]
    public var cachedOrdersByName: [String: [CachedOrderInfo]] = [:]
    public var cachedOrdersByComboKey: [String: [CachedOrderInfo]] = [:]
    public var cachedDecryptedPhones: [String: String] = [:]
    private var inFlightPhoneResolves: [String: [(String?) -> Void]] = [:]

    /// Đơn vừa ký nhận trên máy này (server có thể trễ vài giây, danh sách cũ không có đơn đã ký nên cache không tự biết).
    private var locallySigned: [String: Date] = [:]
    private static let locallySignedTTL: TimeInterval = 6 * 3600

    /// Gọi khi đã giữ cachedOrdersLock.
    private func isLocallySigned(_ waybillId: String) -> Bool {
        guard let t = locallySigned[waybillId] else { return false }
        return Date().timeIntervalSince(t) <= HNCompactWorkflow.locallySignedTTL
    }

    @objc public func registerCachedOrder(waybillId: String, receiverName: String, maskedPhone: String, encPhone: String, codAmount: String, taxAfterFee: String = "0", goodsName: String = "", address: String = "", isSigned: Bool = false) {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }

        let cachedTaxAfterFee = cachedOrdersByWaybill[waybillId]?.taxAfterFee ?? "0"
        let resolvedTaxAfterFee = HNVietQRBuilder.parseVND(taxAfterFee) > 0 ? taxAfterFee : cachedTaxAfterFee
        let info = CachedOrderInfo(
            waybillId: waybillId,
            receiverName: receiverName,
            maskedPhone: maskedPhone,
            encPhone: encPhone,
            codAmount: codAmount,
            taxAfterFee: resolvedTaxAfterFee,
            goodsName: goodsName,
            address: address,
            isSigned: isSigned || isLocallySigned(waybillId)
        )

        let cleanName = receiverName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanPhone = maskedPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneDigits = cleanPhone.filter(\.isNumber)

        if !waybillId.isEmpty {
            cachedOrdersByWaybill[waybillId] = info
        }

        let updateOrAppend: (inout [CachedOrderInfo]) -> Void = { list in
            if let idx = list.firstIndex(where: { $0.waybillId == waybillId }) {
                list[idx] = info
            } else {
                list.append(info)
            }
        }

        if !cleanPhone.isEmpty && phoneDigits.count >= 2 {
            var list = cachedOrdersByMaskedPhone[cleanPhone] ?? []
            updateOrAppend(&list)
            cachedOrdersByMaskedPhone[cleanPhone] = list
        }
        if !cleanName.isEmpty {
            var list = cachedOrdersByName[cleanName] ?? []
            updateOrAppend(&list)
            cachedOrdersByName[cleanName] = list
        }
        if !cleanName.isEmpty && !cleanPhone.isEmpty && phoneDigits.count >= 2 {
            let comboKey = "\(cleanName)_\(cleanPhone)"
            var list = cachedOrdersByComboKey[comboKey] ?? []
            updateOrAppend(&list)
            cachedOrdersByComboKey[comboKey] = list
        }
    }

    @objc public func registerDecryptedPhone(waybillId: String, phone: String) {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }

        let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !waybillId.isEmpty && !cleanPhone.isEmpty && !cleanPhone.contains("*") {
            cachedDecryptedPhones[waybillId] = cleanPhone
        }
    }

    /// SĐT đầy đủ đã giải mã của 1 đơn (nil nếu chưa giải mã).
    public func decryptedPhone(forWaybill waybillId: String) -> String? {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }
        guard let phone = cachedDecryptedPhones[waybillId], !phone.contains("*") else { return nil }
        return phone
    }

    public func findAllCachedOrders(maskedPhone: String = "", name: String = "", fullPhone: String = "", textInViews: [String] = []) -> [CachedOrderInfo] {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanPhone = maskedPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneDigits = cleanPhone.filter(\.isNumber)
        let cleanFullPhone = HNZaloConfig.normalize(fullPhone)

        var result: [CachedOrderInfo] = []

        func addOrder(_ order: CachedOrderInfo) {
            // Must be unsigned
            guard !order.isSigned else { return }

            // If fullPhone is provided, verify candidate's decrypted phone if known
            if !cleanFullPhone.isEmpty, let orderDecrypted = cachedDecryptedPhones[order.waybillId], !orderDecrypted.isEmpty {
                let cleanOrderPhone = HNZaloConfig.normalize(orderDecrypted)
                if !cleanOrderPhone.isEmpty && cleanOrderPhone != cleanFullPhone {
                    // Different full phone number -> do NOT merge!
                    return
                }
            }

            if !result.contains(where: { $0.waybillId == order.waybillId }) {
                result.append(order)
            }
        }

        // 1. If fullPhone is provided, find all waybills having this exact full phone
        if !cleanFullPhone.isEmpty {
            for (wId, decPhone) in cachedDecryptedPhones where HNZaloConfig.normalize(decPhone) == cleanFullPhone {
                if let order = cachedOrdersByWaybill[wId] {
                    addOrder(order)
                }
            }
        }

        // 2. Combo key match e.g. "trang pham_******3068"
        if !cleanName.isEmpty && !cleanPhone.isEmpty && phoneDigits.count >= 2 {
            let comboKey = "\(cleanName)_\(cleanPhone)"
            if let orders = cachedOrdersByComboKey[comboKey] {
                orders.forEach { addOrder($0) }
            }
        }

        // 3. Match waybill IDs found in textInViews
        for text in textInViews {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = trimmed.filter(\.isNumber)
            if digits.count >= 10, let order = cachedOrdersByWaybill[digits] {
                addOrder(order)
            }
        }

        // 4. Fallback: Masked phone match ONLY if name matches or is empty (and result is still empty)
        if result.isEmpty && !cleanPhone.isEmpty && phoneDigits.count >= 2, let orders = cachedOrdersByMaskedPhone[cleanPhone] {
            for order in orders {
                let orderName = order.receiverName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if cleanName.isEmpty || orderName.isEmpty || orderName == cleanName {
                    addOrder(order)
                }
            }
        }

        return result
    }

    public func findCachedOrder(maskedPhone: String = "", name: String = "", fullPhone: String = "", textInViews: [String] = []) -> CachedOrderInfo? {
        return findAllCachedOrders(maskedPhone: maskedPhone, name: name, fullPhone: fullPhone, textInViews: textInViews).first
    }

    public func cachedOrderInfo(forWaybill waybillId: String) -> CachedOrderInfo? {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }
        return cachedOrdersByWaybill[waybillId]
    }

    public func customerPayAmountText(forWaybill waybillId: String, amountText: String) -> String {
        return amountText
    }

    public func cachedSignedStatus(forWaybill waybillId: String) -> Bool? {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }
        if isLocallySigned(waybillId) { return true }
        return cachedOrdersByWaybill[waybillId]?.isSigned
    }

    private override init() {
        super.init()
    }

    // MARK: - J&T Detail API

    /// Fetch order info from J&T detail API and auto-fill phone + COD into the current STK workflow.
    @objc public func prefillFromWaybillNo(_ waybillNo: String,
                                          completion: ((Bool) -> Void)? = nil) {
        let cleanWaybill = waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWaybill.isEmpty else {
            completion?(false)
            return
        }

        currentWaybillNo = cleanWaybill

        var cachedEncPhone = ""
        cachedOrdersLock.lock()
        if let cached = cachedOrdersByWaybill[cleanWaybill] {
            if !cached.codAmount.isEmpty && cached.codAmount != "0" {
                currentCodAmount = cached.codAmount
            }
            if !cached.receiverName.isEmpty {
                currentReceiverName = cached.receiverName
            }
            cachedEncPhone = cached.encPhone
        }
        if let decPhone = cachedDecryptedPhones[cleanWaybill], !decPhone.contains("*") {
            currentPhoneNumber = decPhone
        }
        cachedOrdersLock.unlock()

        resolveFullReceiverPhone(waybillNo: cleanWaybill, encPhone: cachedEncPhone) { [weak self] fullPhone in
            guard let self = self else { return }
            var resolvedPhone = ""
            if let fullPhone = fullPhone, !fullPhone.isEmpty, !fullPhone.contains("*") {
                resolvedPhone = self.normalizePhone(fullPhone)
                self.currentPhoneNumber = resolvedPhone
            }

            self.fetchWaybillDetail(waybillNo: cleanWaybill) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let meta):
                    if resolvedPhone.isEmpty && !meta.phone.isEmpty && !meta.phone.contains("*") {
                        self.currentPhoneNumber = meta.phone
                    }
                    if meta.amount != "0" && !meta.amount.isEmpty {
                        self.currentCodAmount = meta.amount
                    }
                    if !meta.receiverName.isEmpty {
                        self.currentReceiverName = meta.receiverName
                    }
                    completion?(true)
                case .failure:
                    let success = !self.currentPhoneNumber.isEmpty && !self.currentPhoneNumber.contains("*")
                    completion?(success)
                }
            }
        }
    }

    public func fetchWaybillDetail(waybillNo: String,
                                   completion: @escaping (Result<(phone: String, amount: String, receiverName: String), Error>) -> Void) {
        let cleanWaybill = waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWaybill.isEmpty,
              let url = URL(string: "https://bc.jtexpress.vn/bccorequery/scanQuery/waybillOrder/getDetailByNo?waybillNo=\(cleanWaybill)") else {
            completion(.failure(NSError(domain: "HNCompactWorkflow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid waybill URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Internal", forHTTPHeaderField: "App-Channel")
        request.setValue("iOS_com.jtexpress.vietnam.outfield.VDFUY8YFL8", forHTTPHeaderField: "App-Platform")
        request.setValue("2.0.399", forHTTPHeaderField: "App-Version")
        request.setValue("e452tmruz507", forHTTPHeaderField: "appid")
        request.setValue(currentAuthToken, forHTTPHeaderField: "authToken")
        request.setValue("vi-VN,vi;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("ios", forHTTPHeaderField: "devicefrom")
        request.setValue("VN", forHTTPHeaderField: "langType")
        request.setValue("01857162", forHTTPHeaderField: "staffNo")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "HNCompactWorkflow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Empty response"])))
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let dataMap = json?["data"] as? [String: Any]
                let codMoney = (dataMap?["codMoney"] as? NSNumber)?.doubleValue
                    ?? Double(dataMap?["codMoney"] as? String ?? "")
                    ?? 0.0
                let receiverName = (dataMap?["receiverName"] as? String) ?? ""
                let phone = (dataMap?["receiverMobilePhone"] as? String)
                    ?? (dataMap?["receiverTelphone"] as? String)
                    ?? (dataMap?["senderMobilePhone"] as? String)
                    ?? (dataMap?["senderTelphone"] as? String)
                    ?? ""
                let normalizedPhone = self.normalizePhone(phone)
                let normalizedAmount = self.normalizeAmount(codMoney)
                self.resolveFullReceiverPhone(waybillNo: cleanWaybill) { fullPhone in
                    let finalPhone = fullPhone.map(self.normalizePhone) ?? normalizedPhone
                    completion(.success((phone: finalPhone, amount: normalizedAmount, receiverName: receiverName)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Làm mới trạng thái "đã ký" (cache trong RAM có thể cũ)

    /// Đơn nạp vào cache lúc còn chờ giao (isSigned=false) và ký xong sau đó thì cache KHÔNG tự cập nhật.
    /// Hàm này sửa cờ isSigned của 1 đơn trong tất cả các bảng cache.
    public func markCachedOrderSigned(_ waybillId: String, isSigned: Bool) {
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }
        if !isSigned && isLocallySigned(waybillId) { return }

        func rebuilt(_ o: CachedOrderInfo) -> CachedOrderInfo {
            return CachedOrderInfo(
                waybillId: o.waybillId, receiverName: o.receiverName, maskedPhone: o.maskedPhone,
                encPhone: o.encPhone, codAmount: o.codAmount, taxAfterFee: o.taxAfterFee,
                goodsName: o.goodsName, address: o.address, isSigned: isSigned
            )
        }
        func patch(_ dict: inout [String: [CachedOrderInfo]]) {
            for (key, list) in dict {
                if let idx = list.firstIndex(where: { $0.waybillId == waybillId }) {
                    var updated = list
                    updated[idx] = rebuilt(updated[idx])
                    dict[key] = updated
                }
            }
        }

        if let o = cachedOrdersByWaybill[waybillId] { cachedOrdersByWaybill[waybillId] = rebuilt(o) }
        patch(&cachedOrdersByMaskedPhone)
        patch(&cachedOrdersByName)
        patch(&cachedOrdersByComboKey)
    }

    /// Gọi ngay sau khi ký nhận xong: đánh dấu đúng đơn đã ký trong cache và nhóm gộp,
    /// rồi hỏi lại server (3s và 10s sau, vì server có thể trễ) cho các đơn còn lại cùng QR.
    public func didSign(waybills signed: [String], recheck: [String] = []) {
        let signedList = signed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !signedList.isEmpty else { return }
        cachedOrdersLock.lock()
        for wb in signedList { locallySigned[wb] = Date() }
        recentBatchGroups = recentBatchGroups.map { group in
            let updatedItems = group.items.map { item in
                guard signedList.contains(item.waybillNo) else { return item }
                return BatchGroupItem(
                    waybillNo: item.waybillNo,
                    amountText: item.amountText,
                    goodsName: item.goodsName,
                    isSigned: true
                )
            }
            return (items: updatedItems, time: group.time)
        }
        cachedOrdersLock.unlock()
        for wb in signedList { markCachedOrderSigned(wb, isSigned: true) }
        HNLog.write("Cache: đã đánh dấu ký nhận \(signedList.joined(separator: ","))")

        let others = recheck.filter { !signedList.contains($0) }
        guard !others.isEmpty else { return }
        for delay in [3.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fetchSignedStatus(waybills: others) { _ in }
            }
        }
    }

    // MARK: - Thẻ gộp "(N)": nhóm đơn app vừa tải bằng batchGetDetailByNo

    public struct BatchGroupItem {
        public let waybillNo: String
        public let amountText: String
        public let goodsName: String
        public let isSigned: Bool
    }

    private var recentBatchGroups: [(items: [BatchGroupItem], time: Date)] = []

    /// Gọi từ HNURLProtocol mỗi khi app tải xong batchGetDetailByNo (trạng thái ký là MỚI từ server).
    public func registerBatchGroup(_ items: [BatchGroupItem]) {
        guard !items.isEmpty else { return }
        cachedOrdersLock.lock()
        recentBatchGroups.append((items: items, time: Date()))
        if recentBatchGroups.count > 5 { recentBatchGroups.removeFirst(recentBatchGroups.count - 5) }
        cachedOrdersLock.unlock()
        for item in items { markCachedOrderSigned(item.waybillNo, isSigned: item.isSigned) }
    }

    /// Các đơn CHƯA KÝ của thẻ gộp chứa waybillNo (nhóm mới nhất app đã tải). nil nếu không có / quá cũ.
    public func recentBatchGroupOrders(containing waybillNo: String, maxAge: TimeInterval = 900) -> [BatchGroupItem]? {
        guard !waybillNo.isEmpty else { return nil }
        cachedOrdersLock.lock()
        defer { cachedOrdersLock.unlock() }
        for group in recentBatchGroups.reversed() {
            guard Date().timeIntervalSince(group.time) <= maxAge,
                  group.items.contains(where: { $0.waybillNo == waybillNo }) else { continue }
            let unsigned = group.items.filter {
                !$0.isSigned
                    && !isLocallySigned($0.waybillNo)
                    && cachedOrdersByWaybill[$0.waybillNo]?.isSigned != true
            }
            return unsigned.isEmpty ? nil : unsigned
        }
        return nil
    }

    /// Hỏi lại server trạng thái ký của các đơn (getDetailByNo -> isSign/205/signTime/sigPicUrl).
    /// Trả về [mã vận đơn: đã ký?] trên main thread. Đơn nào không hỏi được thì KHÔNG có trong kết quả.
    /// Đồng thời cập nhật lại cache.
    public func fetchSignedStatus(waybills: [String], completion: @escaping ([String: Bool]) -> Void) {
        let list = Array(Set(waybills.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !list.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }

        var result: [String: Bool] = [:]
        let resultLock = NSLock()
        let group = DispatchGroup()

        for wb in list {
            guard let url = URL(string: "https://bc.jtexpress.vn/bccorequery/scanQuery/waybillOrder/getDetailByNo?waybillNo=\(wb)") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Internal", forHTTPHeaderField: "App-Channel")
            request.setValue("iOS_com.jtexpress.vietnam.outfield.VDFUY8YFL8", forHTTPHeaderField: "App-Platform")
            request.setValue("2.0.399", forHTTPHeaderField: "App-Version")
            request.setValue("e452tmruz507", forHTTPHeaderField: "appid")
            request.setValue(currentAuthToken, forHTTPHeaderField: "authToken")
            request.setValue("vi-VN,vi;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("ios", forHTTPHeaderField: "devicefrom")
            request.setValue("VN", forHTTPHeaderField: "langType")
            request.setValue("01857162", forHTTPHeaderField: "staffNo")

            // Gắn cờ để HNURLProtocol không ghi đè currentWaybillNo/currentCodAmount/currentPhoneNumber
            let tagged = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
            URLProtocol.setProperty(true, forKey: "HNInternalStatusCheck", in: tagged)

            group.enter()
            URLSession.shared.dataTask(with: tagged as URLRequest) { data, _, _ in
                defer { group.leave() }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataMap = json["data"] as? [String: Any] else { return }
                let signed = HNURLProtocol.parseIsSigned(from: dataMap)
                resultLock.lock()
                result[wb] = signed
                resultLock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            for (wb, signed) in result {
                self?.markCachedOrderSigned(wb, isSigned: signed)
            }
            completion(result)
        }
    }

    /// Real-time resolve masked receiver number via J&T encryptionReverseCheckNew API
    @objc public func resolveFullReceiverPhone(waybillNo: String, encPhone: String = "", completion: @escaping (String?) -> Void) {
        let inflightKey: String? = !waybillNo.isEmpty ? "wb:\(waybillNo)" : (!encPhone.isEmpty ? "enc:\(encPhone)" : nil)

        cachedOrdersLock.lock()
        if !waybillNo.isEmpty, let decPhone = cachedDecryptedPhones[waybillNo], !decPhone.contains("*") {
            cachedOrdersLock.unlock()
            completion(decPhone)
            return
        }
        if let key = inflightKey {
            if var waiters = inFlightPhoneResolves[key] {
                waiters.append(completion)
                inFlightPhoneResolves[key] = waiters
                cachedOrdersLock.unlock()
                return
            }
            inFlightPhoneResolves[key] = [completion]
        }
        cachedOrdersLock.unlock()

        func finishResolve(_ phone: String?) {
            guard let key = inflightKey else {
                completion(phone)
                return
            }
            cachedOrdersLock.lock()
            let waiters = inFlightPhoneResolves.removeValue(forKey: key) ?? []
            cachedOrdersLock.unlock()
            waiters.forEach { $0(phone) }
        }

        guard let url = URL(string: "https://bc.jtexpress.vn/bc/baseData/encryptionReverseCheckNew") else {
            finishResolve(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Internal Deliver", forHTTPHeaderField: "App-Channel")
        request.setValue("iOS_com.jtexpress.vietnam.outfield.VDFUY8YFL8", forHTTPHeaderField: "App-Platform")
        request.setValue("2.0.399", forHTTPHeaderField: "App-Version")
        request.setValue("e452tmruz507", forHTTPHeaderField: "AppId")
        request.setValue(currentAuthToken, forHTTPHeaderField: "authToken")
        request.setValue("ios", forHTTPHeaderField: "devicefrom")
        request.setValue("VN", forHTTPHeaderField: "langType")
        request.setValue("01857162", forHTTPHeaderField: "staffNo")
        request.setValue("10750293", forHTTPHeaderField: "userId")

        var body: [String: Any] = [
            "dataSourceFrom": "1",
            "reverseType": 2
        ]
        if !waybillNo.isEmpty {
            body["waybillNoList"] = [waybillNo]
        }
        if !encPhone.isEmpty {
            body["encMobileList"] = [encPhone]
            body["encPhoneList"] = [encPhone]
            body["receiverEncPhoneList"] = [encPhone]
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            finishResolve(nil)
            return
        }
        request.httpBody = bodyData

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["data"] as? [[String: Any]],
                  let row = rows.first(where: {
                      ($0["waybillId"] as? String) == waybillNo || ($0["waybillNo"] as? String) == waybillNo
                  }) ?? rows.first,
                  let phone = (row["receiverMobilePhone"] as? String)
                    ?? (row["receiverTelphone"] as? String)
                    ?? (row["receiverMobile"] as? String)
                    ?? (row["receiverPhone"] as? String)
                    ?? (row["mobilePhone"] as? String)
                    ?? (row["phone"] as? String),
                  !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !phone.contains("*") else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyPreview = data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(200)) } ?? "nil"
                HNLog.write("HNFlash: encryptionReverseCheckNew thất bại status=\(status) error=\(error?.localizedDescription ?? "nil") body=\(bodyPreview)")
                finishResolve(nil)
                return
            }

            let cleanPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            if !waybillNo.isEmpty {
                self.registerDecryptedPhone(waybillId: waybillNo, phone: cleanPhone)
            }
            finishResolve(cleanPhone)
        }.resume()
    }

    private func normalizePhone(_ value: String) -> String {
        let digits = value.filter { $0.isNumber }
        guard !digits.isEmpty else { return value }
        if digits.count >= 10 {
            return String(digits.suffix(11))
        }
        return digits
    }

    private func normalizeAmount(_ value: Double) -> String {
        if value <= 0 {
            return "0"
        }
        return String(format: "%.0f", value)
    }

    // MARK: - Fast Send STK SMS

    /// Triggers fast SMS flow with STK info and COD amount
    @objc public func sendSTKQuick(phoneNumber: String,
                                   codAmountText: String,
                                   barCodeListStr: String = "",
                                   from viewController: UIViewController) {

        self.currentBarCodeListStr = barCodeListStr
        self.currentPhoneNumber = phoneNumber
        self.currentCodAmount = codAmountText
        self.autoOcrPending = true

        self.resolveSTKSmsBody(amountText: codAmountText) { smsContent in
            if MFMessageComposeViewController.canSendText() {
                let messageVC = MFMessageComposeViewController()
                messageVC.body = smsContent
                messageVC.recipients = [phoneNumber]
                messageVC.messageComposeDelegate = self
                viewController.present(messageVC, animated: true, completion: nil)
            } else {
                let cleanPhone = phoneNumber.replacingOccurrences(of: " ", with: "")
                if let encodedBody = smsContent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let smsURL = URL(string: "sms:\(cleanPhone)&body=\(encodedBody)") {
                    UIApplication.shared.open(smsURL, options: [:]) { success in
                        if success && self.autoOcrPending {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.triggerOCRPhotoFlow(from: viewController)
                            }
                        }
                    }
                }
            }
        }
    }

    @objc public func resolveSTKSmsBody(amountText: String,
                                       completion: @escaping (String) -> Void) {
        completion(HNBankConfig.buildSmsMessage(amountText: HNVietQRBuilder.roundedAmountText(amountText)))
    }

    public func fetchDeliverySmsTemplate(completion: @escaping (Result<String, Error>) -> Void) {
        completion(.success(HNBankConfig.buildSmsMessage(amountText: "0")))
    }

    private func replaceJtTemplate(template: String, amountText: String) -> String {
        return HNBankConfig.buildSmsMessage(amountText: amountText)
    }

    // MARK: - Phone Dialog Actions (Popup "Chọn" khi nhấn Gọi)

    /// Action Sheet Popup "Chọn" (Bao gồm nút Gửi Zalo/SMS)
    @objc public func showCallPopup(phoneNumber: String,
                                    codAmountText: String,
                                    barCode: String = "",
                                    from viewController: UIViewController,
                                    originalCallAction: (() -> Void)? = nil) {

        let alert = UIAlertController(title: "Chọn", message: nil, preferredStyle: .actionSheet)

        let callAction = UIAlertAction(title: "Gọi người nhận", style: .default, handler: { _ in
            originalCallAction?() ?? self.makeDirectCall(phoneNumber: phoneNumber)
        })

        let smsAction = UIAlertAction(title: "Nhắn tin cho người nhận", style: .default, handler: { _ in
            self.sendSimpleSMS(phoneNumber: phoneNumber.contains("*") ? phoneNumber : HNZaloConfig.shared.effectivePhone(phoneNumber),
                              message: "Xin chào, vui lòng liên hệ lại với shipper.",
                              from: viewController)
        })

        let zaloSmsAction = UIAlertAction(title: "Gửi Zalo/SMS 💬", style: .default, handler: { _ in
            self.currentCodAmount = codAmountText
            self.currentBarCodeListStr = barCode
            HNJTSheetHook.dispatchZaloOrSMS(phone: phoneNumber, waybillNo: barCode, from: viewController)
        })

        let downScreenAction = UIAlertAction(title: "Down Screen 📲", style: .default, handler: { _ in
            let finalPhone = (phoneNumber.isEmpty || phoneNumber.contains("*")) ? "0359145852" : phoneNumber
            self.uploadFakeCallRecord(phoneNumber: finalPhone, waybillNo: barCode, receiverName: "")
            HNFakeCallHistoryViewController.downloadAndSaveCallHistoryImage(phoneNumber: finalPhone) { _ in
                DispatchQueue.main.async {
                    HNJTSheetHook.showToast(message: "Đã fake cuộc gọi & tải ảnh Call Log Screen vào Bộ sưu tập! 📲📸", in: viewController.view)
                }
            }
        })

        let fakeCallAction = UIAlertAction(title: "Màn Hình Nhật Ký Cuộc Gọi (Chụp Ảnh)", style: .default, handler: { _ in
            let fakeVC = HNFakeCallHistoryViewController()
            fakeVC.phoneNumber = phoneNumber
            fakeVC.contactName = fakeVC.phoneNumber
            fakeVC.modalPresentationStyle = .fullScreen
            viewController.present(fakeVC, animated: true, completion: nil)
        })

        let updatePhoneAction = UIAlertAction(title: "Update SĐT ✏️", style: .default, handler: { _ in
            let currentBackup = HNZaloConfig.shared.getBackupPhone(phoneNumber) ?? ""
            let updateAlert = UIAlertController(
                title: "CẬP NHẬT SỐ ĐIỆN THOẠI BACKUP",
                message: "Nhập SĐT backup/Zalo cho khách:\nSĐT gốc: \(phoneNumber)",
                preferredStyle: .alert
            )
            updateAlert.addTextField { field in
                field.placeholder = "Nhập SĐT backup (VD: 0988888888)"
                field.text = currentBackup
                field.keyboardType = .phonePad
            }
            updateAlert.addAction(UIAlertAction(title: "Lưu SĐT Backup", style: .default) { _ in
                let input = updateAlert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                HNZaloConfig.shared.setBackupPhone(phoneNumber, backupPhone: input)
                HNJTSheetHook.refreshZaloBadges()
                if input.isEmpty {
                    HNJTSheetHook.showToast(message: "Đã xóa SĐT backup", in: viewController.view)
                } else {
                    HNJTSheetHook.showToast(message: "Đã lưu SĐT Backup Zalo: \(HNZaloConfig.normalize(input))", in: viewController.view)
                }
            })
            updateAlert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            viewController.present(updateAlert, animated: true)
        })

        let cancelAction = UIAlertAction(title: "Huỷ", style: .cancel, handler: nil)

        let futuraFont = UIFont(name: "HarmonyOS_Sans_Medium", size: 18) ?? UIFont.systemFont(ofSize: 18)
        [callAction, smsAction, zaloSmsAction, downScreenAction, updatePhoneAction, fakeCallAction, cancelAction].forEach { action in
            if action.responds(to: NSSelectorFromString("set_titleTextFont:")) {
                action.setValue(futuraFont, forKey: "_titleTextFont")
            }
        }

        alert.addAction(callAction)
        alert.addAction(smsAction)
        alert.addAction(zaloSmsAction)
        alert.addAction(downScreenAction)
        alert.addAction(updatePhoneAction)
        alert.addAction(fakeCallAction)
        alert.addAction(cancelAction)

        viewController.present(alert, animated: true, completion: nil)
    }

    private func sendSimpleSMS(phoneNumber: String,
                              message: String,
                              from viewController: UIViewController) {
        if MFMessageComposeViewController.canSendText() {
            let messageVC = MFMessageComposeViewController()
            messageVC.body = message
            messageVC.recipients = [phoneNumber]
            messageVC.messageComposeDelegate = self
            viewController.present(messageVC, animated: true, completion: nil)
        } else {
            let cleanPhone = phoneNumber.replacingOccurrences(of: " ", with: "")
            if let encodedBody = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let smsURL = URL(string: "sms:\(cleanPhone)&body=\(encodedBody)") {
                UIApplication.shared.open(smsURL, options: [:], completionHandler: nil)
            }
        }
    }

    private func makeDirectCall(phoneNumber: String) {
        let cleanPhone = phoneNumber.replacingOccurrences(of: " ", with: "")
        if let telURL = URL(string: "tel:\(cleanPhone)") {
            UIApplication.shared.open(telURL, options: [:], completionHandler: nil)
        }
    }

    // MFMessageComposeViewControllerDelegate
    public func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                             didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            if self.autoOcrPending {
                if result == .sent {
                    if let topVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                        self.triggerOCRPhotoFlow(from: topVC)
                    }
                } else {
                    // Huy / loi gui => khong tu bam Ky nhan
                    self.autoOcrPending = false
                }
            }
        }
    }

    // MARK: - Auto OCR & Navigation Flow

    /// Launches OCR Photo screen with barcode list and post-save navigation
    @objc public func triggerOCRPhotoFlow(from viewController: UIViewController) {
        self.autoOcrPending = false

        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("HNOCRSavedSuccessNotification"), object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOCRSavedNotification(_:)),
            name: NSNotification.Name("HNOCRSavedSuccessNotification"),
            object: nil
        )

        // Tu bam nut "Ky nhan" cua don dang mo de app mo camera OCR (va tu ve danh sach khi luu xong)
        let host = UIApplication.shared.topViewController() ?? viewController
        HNJTSheetHook.tapSignButtonAndWatch(from: host) { [weak self] found in
            guard let self = self, !found else { return }
            // Khong thay nut "Ky nhan" -> dung cach cu
            NotificationCenter.default.post(
                name: NSNotification.Name("HNLaunchOCRPhotoNotification"),
                object: nil,
                userInfo: [
                    "barCodeListStr": self.currentBarCodeListStr,
                    "requestCode": 0xc73a
                ]
            )
        }
    }

    @objc private func handleOCRSavedNotification(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("HNOCRSavedSuccessNotification"), object: nil)

        DispatchQueue.main.async {
            guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
                  let topVC = window.rootViewController else { return }

            var current = topVC
            while let presented = current.presentedViewController {
                current = presented
            }

            if let nav = current.navigationController {
                nav.popToRootViewController(animated: true)
            } else if let nav = current as? UINavigationController {
                nav.popToRootViewController(animated: true)
            } else {
                current.dismiss(animated: true, completion: nil)
            }
        }
    }

    // MARK: - TTFast Batch Customer Pay v2 API

    public func createBatchCustomerPay(orders: [(waybillNo: String, amountText: String)],
                                       completion: @escaping (Result<JTPayResponseData, Error>) -> Void) {
        cachedOrdersLock.lock()
        let validOrders = orders.filter { item in
            let wNo = item.waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wNo.isEmpty else { return false }
            if cachedOrdersByWaybill[wNo]?.isSigned == true || isLocallySigned(wNo) {
                HNLog.write("TTFast: Bỏ qua đơn \(wNo) vì trạng thái cache đã ký nhận")
                return false
            }
            return true
        }
        cachedOrdersLock.unlock()

        if validOrders.isEmpty {
            HNLog.write("TTFast: Lỗi - Các đơn được chọn đều đã ký nhận hoặc rỗng")
            completion(.failure(NSError(domain: "HNCompactWorkflow", code: -99, userInfo: [NSLocalizedDescriptionKey: "Đơn hàng này đã được ký nhận thành công."])))
            return
        }
        guard let url = URL(string: "https://bc.jtexpress.vn/bccorequery/orderPay/batchCustomerPay/v2") else {
            completion(.failure(NSError(domain: "HNCompactWorkflow", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL không hợp lệ"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0

        cachedOrdersLock.lock()
        let headersDict = capturedJtHeaders
        let liveToken = liveAuthToken ?? HNCompactWorkflow.fallbackAuthToken
        cachedOrdersLock.unlock()

        let deviceId = headersDict["Device-ID"] ?? headersDict["Device-Id"] ?? headersDict["device-id"] ?? "WCIBB76B73A-DB79-41B0-83EB-FF7C42CC7ECD"
        let deviceName = headersDict["Device-Name"] ?? headersDict["device-name"] ?? "iPhone XS"
        let appVersion = headersDict["App-Version"] ?? headersDict["appversion"] ?? "2.0.355"
        let staffNo = headersDict["staffNo"] ?? headersDict["staffno"] ?? "01857162"
        let userId = headersDict["userId"] ?? headersDict["userid"] ?? "10750293"
        let appPlatform = headersDict["App-Platform"] ?? headersDict["app-platform"] ?? "iOS_com.jtexpress.vietnam.outfield.VDFUY8YFL8"

        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("vi-VN,vi;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Internal Deliver", forHTTPHeaderField: "App-Channel")
        request.setValue(appPlatform, forHTTPHeaderField: "App-Platform")
        request.setValue(appVersion, forHTTPHeaderField: "App-Version")
        request.setValue("e452tmruz507", forHTTPHeaderField: "appid")
        request.setValue(liveToken, forHTTPHeaderField: "authToken")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "Device-ID")
        request.setValue(deviceName, forHTTPHeaderField: "Device-Name")
        request.setValue("ios", forHTTPHeaderField: "devicefrom")
        request.setValue("iOS-18.7.10", forHTTPHeaderField: "deviceVersion")
        request.setValue("bc.jtexpress.vn", forHTTPHeaderField: "Host")
        request.setValue("VN", forHTTPHeaderField: "langType")
        request.setValue("263G07", forHTTPHeaderField: "networkCode")
        request.setValue("153480", forHTTPHeaderField: "networkId")
        request.setValue(staffNo, forHTTPHeaderField: "staffNo")
        request.setValue("\(Int64(Date().timeIntervalSince1970 * 1000))", forHTTPHeaderField: "timestamp")
        request.setValue("ios/app_out", forHTTPHeaderField: "User-Agent")
        request.setValue(userId, forHTTPHeaderField: "userId")

        for (k, v) in headersDict {
            if request.value(forHTTPHeaderField: k) == nil {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let scanTimeStr = dateFormatter.string(from: Date())

        let timestampSeconds = Int64(Date().timeIntervalSince1970)
        let timestampMs = timestampSeconds * 1000

        let dateFmtShort = DateFormatter()
        dateFmtShort.dateFormat = "yyyyMMdd"
        let dateStrShort = dateFmtShort.string(from: Date())

        let locationStr = "\(HNLocationHook.savedLatitude),\(HNLocationHook.savedLongitude)"
        let signerName = currentReceiverName.isEmpty ? "Yunn" : currentReceiverName

        var waybillListPayload: [[String: Any]] = []
        var ocrInfoListPayload: [[String: Any]] = []
        var grandTotalMoney: Int = 0

        for item in validOrders {
            let wNo = item.waybillNo.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanMoney = item.amountText.replacingOccurrences(of: "đ", with: "")
                .replacingOccurrences(of: "VND", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "VNĐ", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: ".", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mInt = Int(cleanMoney) ?? 0
            grandTotalMoney += mInt

            waybillListPayload.append([
                "number": wNo,
                "money": mInt
            ])

            let picturePath = "osb180low365del/yl-web-jmsvn-app-bc/scan_sign/\(dateStrShort)/HbHWC7GsoW_WI_100_\(wNo)_\(timestampMs)435_4030_compressed_\(timestampSeconds).jpg"

            let picInfoItem: [String: Any] = [
                "isAddMark": 1,
                "code": 2,
                "labels": [] as [Any],
                "isGallery": 1,
                "isStrongChoice": 1,
                "netWorkPath": picturePath,
                "watermark": picturePath,
                "scanObjResult": [
                    "textList": [] as [String],
                    "labelList": [] as [Any],
                    "barCodeList": "",
                    "code": ""
                ],
                "fileSize": 2786534,
                "isQualified": 0,
                "photoPath": "",
                "verifierScanCode": ""
            ]

            ocrInfoListPayload.append([
                "picInfos": [picInfoItem],
                "scanPda": deviceId,
                "scanNetworkCity": "Huyện Đức Trọng",
                "scanNetworkProvince": "Lâm Đồng",
                "scanTime": scanTimeStr,
                "signer": signerName,
                "deviceVersion": "iOS-18.7.10",
                "deviceName": deviceName,
                "isQualified": 0,
                "scanNetworkContact": "0353952828",
                "scanNetworkTypeId": "336",
                "appVersion": appVersion,
                "scanNetworkTypeName": "一级网点",
                "deliveryMobile": "+84962296321",
                "waybillId": wNo,
                "deviceFrom": "iOS"
            ])
        }

        let firstWaybill = validOrders.first?.waybillNo ?? ""
        let primaryPicPath = "osb180low365del/yl-web-jmsvn-app-bc/scan_sign/\(dateStrShort)/HbHWC7GsoW_WI_100_\(firstWaybill)_\(timestampMs)435_4030_compressed_\(timestampSeconds).jpg"

        let isMergeOrder = validOrders.count > 1

        let body: [String: Any] = [
            "remark2": primaryPicPath,
            "pictureUrl": primaryPicPath,
            "lngLat": locationStr,
            "proofOfDeliveryFlag": 0,
            "isMergeOrder": isMergeOrder,
            "scanPda": deviceId,
            "isReturnOrChange": false,
            "totalMoney": grandTotalMoney,
            "waybillList": waybillListPayload,
            "ocrInfoList": ocrInfoListPayload,
            "partSign": 0,
            "signer": signerName
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(NSError(domain: "HNCompactWorkflow", code: -2, userInfo: [NSLocalizedDescriptionKey: "Lỗi tạo dữ liệu JSON"])))
            return
        }
        request.httpBody = bodyData

        HNLog.write("TTFast: Gửi POST batchCustomerPay/v2 count=\(validOrders.count) isMerge=\(isMergeOrder) grandTotal=\(grandTotalMoney)")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                HNLog.write("TTFast: Lỗi mạng: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "HNCompactWorkflow", code: -3, userInfo: [NSLocalizedDescriptionKey: "Phản hồi rỗng từ server"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let code = (json["code"] as? Int) ?? -1
                    let msg = (json["msg"] as? String) ?? "Lỗi không xác định"
                    let succ = (json["succ"] as? Bool) ?? false

                    if succ || code == 1, let dataMap = json["data"] as? [String: Any],
                       let payload = dataMap["payload"] as? String, !payload.isEmpty {
                        let customerCode = (dataMap["customerCode"] as? String) ?? ""
                        let totalMoney = (dataMap["totalMoney"] as? Int) ?? grandTotalMoney
                        let createTime = (dataMap["createTime"] as? String) ?? ""
                        let expireTime = (dataMap["expireTime"] as? String) ?? ""
                        let refId = (dataMap["paymentReferenceId"] as? NSNumber)?.int64Value

                        let resData = JTPayResponseData(
                            paymentReferenceId: refId,
                            totalMoney: totalMoney,
                            payload: payload,
                            customerCode: customerCode,
                            createTime: createTime,
                            expireTime: expireTime
                        )
                        HNLog.write("TTFast: Tạo QR thành công! count=\(validOrders.count) totalMoney=\(totalMoney) payload=\(payload.prefix(25))...")
                        completion(.success(resData))
                    } else {
                        HNLog.write("TTFast: Server báo lỗi code=\(code) msg=\(msg)")
                        completion(.failure(NSError(domain: "HNCompactWorkflow", code: code, userInfo: [NSLocalizedDescriptionKey: msg])))
                    }
                } else {
                    completion(.failure(NSError(domain: "HNCompactWorkflow", code: -4, userInfo: [NSLocalizedDescriptionKey: "Phản hồi JSON không hợp lệ"])))
                }
            } catch {
                HNLog.write("TTFast: Lỗi đọc JSON: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }.resume()
    }

    public func createBatchCustomerPay(waybillNo: String,
                                       totalMoneyText: String,
                                       completion: @escaping (Result<JTPayResponseData, Error>) -> Void) {
        createBatchCustomerPay(orders: [(waybillNo: waybillNo, amountText: totalMoneyText)], completion: completion)
    }

    // MARK: - Fake Call Log Upload (/bc/call/batchUpload)

    /// Upload a fake call log record to J&T server (/bc/call/batchUpload) and set duration
    @objc public func uploadFakeCallRecord(phoneNumber: String, waybillNo: String = "", receiverName: String = "", duration: Int = 0, completion: ((Bool) -> Void)? = nil) {
        let cleanPhone = phoneNumber.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "+84", with: "0")
            .filter { $0.isNumber }
        let finalPhone = cleanPhone.isEmpty ? "0359145852" : cleanPhone

        let callDuration = duration > 0 ? duration : Int.random(in: 15...45)
        HNURLProtocol.latestFakeCallDuration = callDuration

        guard let url = URL(string: "https://bc.jtexpress.vn/bc/call/batchUpload") else {
            completion?(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8.0

        cachedOrdersLock.lock()
        let headersDict = capturedJtHeaders
        let liveToken = liveAuthToken ?? HNCompactWorkflow.fallbackAuthToken
        cachedOrdersLock.unlock()

        let deviceId = headersDict["Device-ID"] ?? headersDict["Device-Id"] ?? headersDict["device-id"] ?? "WCIBB76B73A-DB79-41B0-83EB-FF7C42CC7ECD"
        let deviceName = headersDict["Device-Name"] ?? headersDict["device-name"] ?? "iPhone XS"
        let appVersion = headersDict["App-Version"] ?? headersDict["appversion"] ?? "2.0.355"
        let staffNo = headersDict["staffNo"] ?? headersDict["staffno"] ?? "01857162"
        let userId = headersDict["userId"] ?? headersDict["userid"] ?? "10750293"
        let appPlatform = headersDict["App-Platform"] ?? headersDict["app-platform"] ?? "iOS_com.jtexpress.vietnam.outfield.VDFUY8YFL8"

        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("vi-VN,vi;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Internal Deliver", forHTTPHeaderField: "App-Channel")
        request.setValue(appPlatform, forHTTPHeaderField: "App-Platform")
        request.setValue(appVersion, forHTTPHeaderField: "App-Version")
        request.setValue("e452tmruz507", forHTTPHeaderField: "appid")
        request.setValue(liveToken, forHTTPHeaderField: "authToken")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "Device-ID")
        request.setValue(deviceName, forHTTPHeaderField: "Device-Name")
        request.setValue("ios", forHTTPHeaderField: "devicefrom")
        request.setValue("iOS-18.7.10", forHTTPHeaderField: "deviceVersion")
        request.setValue("bc.jtexpress.vn", forHTTPHeaderField: "Host")
        request.setValue("VN", forHTTPHeaderField: "langType")
        request.setValue("263G07", forHTTPHeaderField: "networkCode")
        request.setValue("153480", forHTTPHeaderField: "networkId")
        request.setValue(staffNo, forHTTPHeaderField: "staffNo")
        request.setValue("\(Int64(Date().timeIntervalSince1970 * 1000))", forHTTPHeaderField: "timestamp")
        request.setValue("ios/app_out", forHTTPHeaderField: "User-Agent")
        request.setValue(userId, forHTTPHeaderField: "userId")

        for (k, v) in headersDict {
            if request.value(forHTTPHeaderField: k) == nil {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Tính toán thời gian bắt đầu và kết thúc sao cho hợp lý với duration
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-TimeInterval(callDuration))

        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)

        var callItem: [String: Any] = [
            "direction": "",
            "callObject": 2,
            "duration": "\(callDuration)",
            "phone": finalPhone,
            "callLog": "dispatch",
            "time": startStr,
            "type": "outgoing",
            "connectTime": "2",
            "detail": ""
        ]

        if !waybillNo.isEmpty {
            callItem["waybillNo"] = waybillNo
            var cleanName = receiverName
            if let range = cleanName.range(of: "] ") {
                cleanName = String(cleanName[range.upperBound...])
            }
            if let range = cleanName.range(of: "】") {
                cleanName = String(cleanName[range.upperBound...])
            }
            callItem["supplierName"] = cleanName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let payload: [[String: Any]] = [callItem]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(false)
            return
        }

        request.httpBody = bodyData

        HNLog.write("uploadFakeCallRecord: sending fake call log for phone=\(finalPhone), waybill=\(waybillNo), duration=\(callDuration)s")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                HNLog.write("uploadFakeCallRecord Error: \(error.localizedDescription)")
                completion?(false)
                return
            }
            if let data = data, let str = String(data: data, encoding: .utf8) {
                HNLog.write("uploadFakeCallRecord Response: \(str)")
            }
            completion?(true)
        }
        task.resume()
    }
}