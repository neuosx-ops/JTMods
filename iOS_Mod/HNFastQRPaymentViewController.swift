//
//  HNFastQRPaymentViewController.swift
//  iOS_Mod - Fast COD transfer screen
//
//  Parses the original J&T EMV/VietQR payload and opens an autofill-capable
//  bank app through the official VietQR deeplink.
//

import UIKit
import CoreImage

// MARK: - VietQR App & Bank Directory

struct VietQRBank: Decodable {
    let bin: String
    let code: String
    let name: String
    let shortName: String
    let logo: String?
    let transferSupported: Int?
}

struct VietQRBankResponse: Decodable {
    let code: String
    let data: [VietQRBank]
}

struct VietQRApp: Decodable {
    let appId: String
    let appLogo: String?
    let appName: String
    let bankName: String
    let monthlyInstall: Int?
    let deeplink: String?
    let autofill: Int?

    var displayShortName: String {
        let id = appId.lowercased()
        switch id {
        case "bidv": return "BIDV"
        case "vcb": return "VCB (Vietcombank)"
        case "mb": return "MB"
        case "tcb": return "TECHCOMBANK"
        case "vpb": return "VPBANK"
        case "acb", "acb-biz": return "ACB"
        case "tpb": return "TPBANK"
        case "icb": return "VIETINBANK"
        case "vib-2": return "VIB"
        case "shb", "shbvn": return "SHB"
        case "ocb": return "OCB"
        case "lpb": return "LPBANK"
        case "hdb": return "HDBANK"
        case "vba": return "AGRIBANK"
        case "stb": return "SACOMBANK"
        case "msb": return "MSB"
        case "eib": return "EXIMBANK"
        case "seab": return "SEABANK"
        case "scb": return "SCB"
        case "cake": return "CAKE"
        case "timo": return "TIMO"
        case "abb": return "ABBANK"
        case "pvcb": return "PVCOMBANK"
        case "ncb": return "NCB"
        case "bvb": return "BVBANK"
        case "klb": return "KIENLONGBANK"
        case "vab": return "VIETABANK"
        default:
            return appId.uppercased()
        }
    }

}

struct VietQRAppResponse: Decodable {
    let apps: [VietQRApp]
}

/// Loads official VietQR iOS app deeplinks (https://api.vietqr.io/v2/ios-app-deeplinks)
/// and bank metadata (https://api.vietqr.io/v2/banks) for reliable deep linking.
final class VietQRBankDirectory {
    static let shared = VietQRBankDirectory()

    private(set) var apps: [VietQRApp] = []
    private(set) var banks: [VietQRBank] = []
    private var isLoading = false
    private var pendingCompletions: [() -> Void] = []

    private let fallbackApps: [VietQRApp] = [
        VietQRApp(appId: "icb", appLogo: nil, appName: "VietinBank iPay", bankName: "Ngân hàng TMCP Công thương Việt Nam", monthlyInstall: 200000, deeplink: "https://dl.vietqr.io/pay?app=icb", autofill: 1),
        VietQRApp(appId: "bidv", appLogo: nil, appName: "BIDV SmartBanking", bankName: "Ngân hàng TMCP Đầu tư và Phát triển Việt Nam", monthlyInstall: 100000, deeplink: "https://dl.vietqr.io/pay?app=bidv", autofill: 1),
        VietQRApp(appId: "acb", appLogo: nil, appName: "ACB ONE", bankName: "Ngân hàng TMCP Á Châu", monthlyInstall: 60000, deeplink: "https://dl.vietqr.io/pay?app=acb", autofill: 1),
        VietQRApp(appId: "ocb", appLogo: nil, appName: "OCB OMNI", bankName: "Ngân hàng TMCP Phương Đông", monthlyInstall: 60000, deeplink: "https://dl.vietqr.io/pay?app=ocb", autofill: 1),
        VietQRApp(appId: "mb", appLogo: nil, appName: "MB Bank", bankName: "Ngân hàng TMCP Quân đội", monthlyInstall: 400000, deeplink: "https://dl.vietqr.io/pay?app=mb", autofill: 1)
    ]

    fileprivate static let appsCacheKey = "HNVietQRAppsCache.v1"
    fileprivate static let banksCacheKey = "HNVietQRBanksCache.v1"

    private init() {
        apps = fallbackApps
        // Reuse the last successful network result immediately, so the bank
        // list never has to wait on api.vietqr.io before the app can open.
        let d = UserDefaults.standard
        if let data = d.data(forKey: VietQRBankDirectory.appsCacheKey),
           let decoded = try? JSONDecoder().decode(VietQRAppResponse.self, from: data) {
            apps = decoded.apps.filter { $0.autofill == 1 }
        }
        if let data = d.data(forKey: VietQRBankDirectory.banksCacheKey),
           let decoded = try? JSONDecoder().decode(VietQRBankResponse.self, from: data),
           !decoded.data.isEmpty {
            banks = decoded.data
        }
    }

    func ensureLoaded(completion: @escaping () -> Void) {
        pendingCompletions.append(completion)
        guard !isLoading else { return }
        isLoading = true

        let group = DispatchGroup()

        // 1. Fetch iOS app deeplinks (https://api.vietqr.io/v2/ios-app-deeplinks)
        group.enter()
        if let url1 = URL(string: "https://api.vietqr.io/v2/ios-app-deeplinks") {
            URLSession.shared.dataTask(with: url1) { [weak self] data, _, error in
                guard let self = self else {
                    group.leave()
                    return
                }
                guard let data = data, error == nil else {
                    HNLog.write("[VietQR] iOS app directory request failed: \(error?.localizedDescription ?? "empty response")")
                    group.leave()
                    return
                }
                guard let decoded = try? JSONDecoder().decode(VietQRAppResponse.self, from: data) else {
                    HNLog.write("[VietQR] iOS app directory response was invalid or empty.")
                    group.leave()
                    return
                }
                DispatchQueue.main.async {
                    self.apps = decoded.apps.filter { $0.autofill == 1 }
                    UserDefaults.standard.set(data, forKey: VietQRBankDirectory.appsCacheKey)
                    HNLog.write("[VietQR] filtered autofill apps=\(self.apps.map { $0.appId })")
                    group.leave()
                }
            }.resume()
        } else {
            group.leave()
        }

        // 2. Fetch banks (https://api.vietqr.io/v2/banks) for BIN / code mapping
        group.enter()
        if let url2 = URL(string: "https://api.vietqr.io/v2/banks") {
            URLSession.shared.dataTask(with: url2) { [weak self] data, _, error in
                guard let self = self else {
                    group.leave()
                    return
                }
                guard let data = data, error == nil else {
                    HNLog.write("[VietQR] bank directory request failed: \(error?.localizedDescription ?? "empty response")")
                    group.leave()
                    return
                }
                guard let decoded = try? JSONDecoder().decode(VietQRBankResponse.self, from: data),
                      !decoded.data.isEmpty else {
                    HNLog.write("[VietQR] bank directory response was invalid or empty.")
                    group.leave()
                    return
                }
                DispatchQueue.main.async {
                    self.banks = decoded.data
                    UserDefaults.standard.set(data, forKey: VietQRBankDirectory.banksCacheKey)
                    group.leave()
                }
            }.resume()
        } else {
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false
            HNLog.write("[VietQR] directory refreshed. apps=\(self.apps.count) banks=\(self.banks.count) appIds=\(self.apps.map { $0.appId })")
            self.flushCompletions()
        }
    }

    private func flushCompletions() {
        let callbacks = pendingCompletions
        pendingCompletions.removeAll()
        callbacks.forEach { $0() }
    }

    /// ⚠️ Do NOT use this to build the `ba=` deep link parameter — it resolves
    /// the bin of `app` itself (the app being opened), not the beneficiary's
    /// bank. Kept only in case something else in the project still calls it;
    /// `openBank(_:)` no longer does (see the fix there for why).
    func binOrCode(forApp app: VietQRApp, fallbackBin: String?) -> String {
        let appIdLower = app.appId.lowercased()
        let bankNameLower = app.bankName.lowercased()

        if let matched = banks.first(where: {
            $0.code.lowercased() == appIdLower ||
            bankNameLower.contains($0.shortName.lowercased()) ||
            $0.name.lowercased().contains(bankNameLower) ||
            bankNameLower.contains($0.name.lowercased())
        }) {
            return matched.bin
        }

        if let fallback = fallbackBin, !fallback.isEmpty {
            return fallback
        }

        switch appIdLower {
        case "icb": return "970415"
        case "bidv": return "970418"
        case "acb", "acb-biz": return "970416"
        case "ocb": return "970448"
        case "mb": return "970422"
        case "vcb": return "970436"
        case "tcb": return "970407"
        case "vpb", "cake": return "970432"
        case "vib-2": return "970441"
        case "shb": return "970443"
        case "lpb": return "970449"
        case "seab": return "970440"
        case "scb": return "970429"
        case "hdb": return "970437"
        case "vba": return "970405"
        case "tpb": return "970423"
        case "timo": return "970434"
        case "shbvn": return "970424"
        case "abb": return "970425"
        case "pvcb": return "970412"
        case "eib": return "970431"
        case "ncb": return "970439"
        case "bvb": return "970438"
        case "klb": return "970452"
        case "vab": return "970430"
        default: return "970436"
        }
    }

    func binOrCode(forNameGuess name: String) -> String {
        let lower = name.lowercased()
        if let matched = banks.first(where: {
            lower.contains($0.code.lowercased()) ||
            lower.contains($0.shortName.lowercased()) ||
            $0.name.lowercased().contains(lower)
        }) {
            return matched.bin
        }
        return "970418" // default BIDV BIN
    }
}

// MARK: - Minimal EMVCo (VietQR / napas247) TLV parser

/// Parses the EMVCo-style TLV payload used by VietQR (napas247) QR codes so
/// we can recover the real beneficiary account, bank BIN, amount and
/// transfer content instead of passing the raw QR string around as a black
/// box. NOTE: tag positions below follow the common napas247 layout; if a
/// particular QR source nests fields differently, log
/// `EMVQRParser.parse(payload)` to double-check before shipping.
enum EMVQRParser {

    struct Field { let id: String; let value: String }

    static func parse(_ payload: String) -> [Field] {
        var fields: [Field] = []
        let chars = Array(payload)
        var i = 0
        while i + 4 <= chars.count {
            let id = String(chars[i..<i+2])
            guard let len = Int(String(chars[i+2..<i+4])) else { break }
            let valueStart = i + 4
            let valueEnd = valueStart + len
            guard valueEnd <= chars.count else { break }
            fields.append(Field(id: id, value: String(chars[valueStart..<valueEnd])))
            i = valueEnd
        }
        return fields
    }

    struct VietQRInfo {
        var bin: String?
        var account: String?
        var amount: String?
        var content: String?
        var beneficiaryName: String?
    }

    /// tag 38 = merchant account info (napas247), tag 54 = amount,
    /// tag 59 = beneficiary/merchant name (EMVCo standard tag — VietQR uses
    /// it for the receiving account's display name), tag 62 / sub 08 =
    /// purpose / transfer content.
    static func extractVietQRInfo(from payload: String) -> VietQRInfo {
        var info = VietQRInfo()
        guard !payload.isEmpty else { return info }
        let top = parse(payload)

        if let tag54 = top.first(where: { $0.id == "54" }) {
            info.amount = tag54.value
        }

        if let tag38 = top.first(where: { $0.id == "38" }) {
            let sub = parse(tag38.value)
            if let beneficiary = sub.first(where: { $0.id == "01" }) {
                let nested = parse(beneficiary.value)
                info.bin = nested.first(where: { $0.id == "00" })?.value
                info.account = nested.first(where: { $0.id == "01" })?.value
            }
        }

        if let tag59 = top.first(where: { $0.id == "59" }) {
            info.beneficiaryName = tag59.value
        }

        if let tag62 = top.first(where: { $0.id == "62" }) {
            let sub = parse(tag62.value)
            info.content = sub.first(where: { $0.id == "08" })?.value
        }

        return info
    }
}

// MARK: - Shared VietQR payload utilities

/// Shared by other J&T messaging flows; the Fast COD screen uses the original
/// payload parser above and does not build a replacement QR.
enum HNVietQRBuilder {

    /// Parses "190,000đ", "190.000", "190000", "190000.00" … into whole VND.
    /// A separator followed by exactly 3+ digits is a thousands separator;
    /// followed by 1–2 digits it is a decimal part and is dropped (VND has none).
    static func parseVND(_ text: String) -> Int {
        let kept = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard let lastSep = kept.lastIndex(where: { $0 == "." || $0 == "," }) else {
            return Int(kept) ?? 0
        }
        let tail = String(kept[kept.index(after: lastSep)...])
        let head = kept[..<lastSep].filter { $0.isNumber }
        if tail.count >= 3 {
            return Int(head + tail) ?? 0
        }
        return Int(head) ?? 0
    }

    /// Làm tròn tiền thu hộ về nghìn đồng: phần lẻ từ 400đ trở lên thì làm tròn lên, dưới 400đ thì làm tròn xuống.
    /// 14.400 -> 15.000, 14.399 -> 14.000. (Tổng nhỏ hơn 400đ giữ nguyên để không về 0.)
    static func roundVND(_ value: Int) -> Int {
        guard value > 0 else { return value }
        let remainder = value % 1000
        let rounded = remainder >= 400 ? value - remainder + 1000 : value - remainder
        return rounded > 0 ? rounded : value
    }

    /// Chuỗi số tiền (kiểu "14,400" / "14400") -> chuỗi số nguyên đã làm tròn ("15000"); không đọc được thì giữ nguyên.
    static func roundedAmountText(_ text: String) -> String {
        let value = parseVND(text)
        return value > 0 ? String(roundVND(value)) : text
    }

    static func formatVND(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func crc16(_ s: String) -> String {
        var crc: UInt16 = 0xFFFF
        for b in s.utf8 {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1)
            }
        }
        return String(format: "%04X", crc)
    }

    private static func tlv(_ id: String, _ value: String) -> String {
        return id + String(format: "%02d", value.utf8.count) + value
    }

    /// ASCII only, no accents, max 25 chars (VietQR transfer-content limit).
    static func sanitizeContent(_ s: String, maxLength: Int = 25) -> String {
        let folded = s.replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN"))
        var out = ""
        for scalar in folded.unicodeScalars where scalar.value < 128 {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > maxLength {
            out = String(out.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    static func payload(bin: String, account: String, amount: Int, content: String) -> String {
        let acc = account.filter { $0.isLetter || $0.isNumber }
        let beneficiary = tlv("00", bin) + tlv("01", acc)
        let merchant = tlv("00", "A000000727") + tlv("01", beneficiary) + tlv("02", "QRIBFTTA")
        var p = tlv("00", "01") + tlv("01", amount > 0 ? "12" : "11") + tlv("38", merchant)
        p += tlv("53", "704")
        if amount > 0 { p += tlv("54", String(amount)) }
        p += tlv("58", "VN")
        let info = sanitizeContent(content)
        if !info.isEmpty { p += tlv("62", tlv("08", info)) }
        p += "6304"
        return p + crc16(p)
    }

    /// Bank name typed in the app settings -> napas BIN. nil if unknown.
    static func bin(forBankName name: String) -> String? {
        let key = name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        if key.isEmpty { return nil }
        if key.count == 6, key.allSatisfy({ $0.isNumber }) { return key }

        let table: [(keys: [String], bin: String)] = [
            (["vietcombank", "vcb"], "970436"),
            (["bidv"], "970418"),
            (["vietinbank", "icb", "ctg"], "970415"),
            (["agribank", "vba"], "970405"),
            (["mbbank", "mb"], "970422"),
            (["techcombank", "tcb"], "970407"),
            (["acb"], "970416"),
            (["vpbank", "vpb"], "970432"),
            (["tpbank", "tpb"], "970423"),
            (["sacombank", "stb"], "970403"),
            (["hdbank", "hdb"], "970437"),
            (["vib"], "970441"),
            (["shb"], "970443"),
            (["ocb"], "970448"),
            (["msb", "maritimebank"], "970426"),
            (["seabank", "seab"], "970440"),
            (["lpbank", "lienvietpostbank", "lpb"], "970449"),
            (["eximbank", "eib"], "970431"),
            (["scb"], "970429"),
            (["ncb"], "970419"),
            (["abbank", "abb"], "970425"),
            (["bacabank"], "970409"),
            (["vietabank"], "970427"),
            (["pvcombank", "pvcb"], "970412"),
            (["bvbank", "baovietbank"], "970438"),
            (["kienlongbank", "klb"], "970452"),
            (["namabank"], "970428")
        ]
        for entry in table {
            for k in entry.keys {
                let hit = k.count <= 4 ? (key == k || key.hasPrefix(k) || key.hasSuffix(k)) : key.contains(k)
                if hit { return entry.bin }
            }
        }

        // Fall back to the live VietQR bank list, if it has been loaded.
        let stripped: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        return VietQRBankDirectory.shared.banks.first(where: {
            stripped($0.code) == key || stripped($0.shortName) == key
        })?.bin
    }

    static func qrImage(from string: String, scale: CGFloat = 10) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// One shareable picture: QR + exact amount + account + order list,
    /// so a single paste into Zalo carries everything the customer needs.
    /// Values are drawn bold (fill + stroke, so it stays bold even if the
    /// host app swaps the system font for one without a bold weight).
    static func billImage(qr: UIImage, amount: Int, bankName: String, account: String, owner: String, content: String, orders: [(waybill: String, goods: String)]) -> UIImage {
        let width: CGFloat = 720
        let pad: CGFloat = 40
        let contentW = width - pad * 2
        let red = UIColor(red: 0.90, green: 0.22, blue: 0.21, alpha: 1.0)

        let center = NSMutableParagraphStyle()
        center.alignment = .center

        let bodyFont = UIFont.systemFont(ofSize: 28, weight: .regular)
        let boldFont = UIFont.boldSystemFont(ofSize: 29)
        let labelColor = UIColor(white: 0.50, alpha: 1)

        func boldText(_ s: String, font: UIFont, color: UIColor, stroke: CGFloat = -6, paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .strokeColor: color, .strokeWidth: stroke
            ]
            if let paragraph = paragraph { attrs[.paragraphStyle] = paragraph }
            return NSAttributedString(string: s, attributes: attrs)
        }
        func plainText(_ s: String) -> NSAttributedString {
            return NSAttributedString(string: s, attributes: [.font: bodyFont, .foregroundColor: labelColor])
        }
        func row(_ label: String, _ value: String) -> NSAttributedString {
            let m = NSMutableAttributedString(attributedString: plainText(label + " "))
            m.append(boldText(value, font: boldFont, color: .black))
            return m
        }

        var lines: [NSAttributedString] = [
            row("Ngân hàng:", bankName),
            row("STK:", account),
            row("Chủ TK:", owner),
            row("Nội dung:", content)
        ]
        if !orders.isEmpty {
            lines.append(plainText("Đơn hàng:"))
            for o in orders.prefix(8) {
                let m = NSMutableAttributedString(attributedString: plainText("• "))
                m.append(boldText(o.waybill, font: boldFont, color: .black))
                if !o.goods.isEmpty {
                    let goods = o.goods.count > 60 ? String(o.goods.prefix(60)) + "…" : o.goods
                    m.append(plainText(" - " + goods))
                }
                lines.append(m)
            }
            if orders.count > 8 { lines.append(plainText("… và \(orders.count - 8) đơn khác")) }
        }

        func textHeight(_ a: NSAttributedString) -> CGFloat {
            return ceil(a.boundingRect(
                with: CGSize(width: contentW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], context: nil).height)
        }

        let title = boldText("QUÉT MÃ ĐỂ THANH TOÁN", font: UIFont.systemFont(ofSize: 30, weight: .bold), color: red, stroke: -4, paragraph: center)
        let amountStr = boldText("\(formatVND(amount)) đ", font: UIFont.systemFont(ofSize: 60, weight: .heavy), color: red, stroke: -5, paragraph: center)

        let qrBox: CGFloat = 500
        var totalH = pad + 40 + 16 + qrBox + 20 + 76 + 16
        for l in lines { totalH += textHeight(l) + 8 }
        totalH += pad

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: totalH))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: totalH))

            var y = pad
            title.draw(in: CGRect(x: pad, y: y, width: contentW, height: 40))
            y += 40 + 16

            let qrRect = CGRect(x: (width - qrBox) / 2, y: y, width: qrBox, height: qrBox)
            UIColor.white.setFill()
            ctx.fill(qrRect)
            ctx.cgContext.interpolationQuality = .none
            qr.draw(in: qrRect.insetBy(dx: 16, dy: 16))
            ctx.cgContext.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
            ctx.cgContext.stroke(qrRect)
            y += qrBox + 20

            amountStr.draw(in: CGRect(x: pad, y: y, width: contentW, height: 76))
            y += 76 + 16

            for l in lines {
                let h = textHeight(l)
                l.draw(in: CGRect(x: pad, y: y, width: contentW, height: h))
                y += h + 8
            }
        }
    }
}

// MARK: - Official deeplink helpers

enum HNQRPrefs {
    static let lastBankKey = "HNLastPaidBankApp"
    static let lastOpenDateKey = "HNLastVietQROpenDate"
}

enum HNVietQRBankCodes {
    /// `url` is documented as required by dl.vietqr.io (return link after a
    /// successful payment). Swap for your own URL scheme if you have one.
    static let defaultReturnURL = "https://jtexpress.vn"

    private static let staticBinToCode: [String: String] = [
        "970436": "vcb", "970422": "mb",  "970418": "bidv", "970415": "icb",
        "970416": "acb", "970448": "ocb", "970407": "tcb",  "970432": "vpb",
        "970423": "tpb", "970403": "stb", "970437": "hdb",  "970443": "shb",
        "970426": "msb", "970441": "vib", "970440": "seab", "970449": "lpb",
        "970431": "eib", "970405": "vba", "963311": "vikki"
    ]

    /// `ba=` uses <account>@<bank code>, not the 6-digit BIN.
    /// Numeric BINs resolve through `/v2/banks` first and the static map second.
    static func deepLinkRef(for raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        let isNumericBIN = raw.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        guard isNumericBIN else { return raw.lowercased() }
        if let bank = VietQRBankDirectory.shared.banks.first(where: { $0.bin == raw }) {
            let code = bank.code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return code.isEmpty ? nil : code
        }
        return staticBinToCode[raw]
    }
}

// MARK: - View Controller

@objc(HNFastQRPaymentViewController)
public class HNFastQRPaymentViewController: UIViewController {

    public var payData: JTPayResponseData?
    public var waybillNo: String = ""
    public var amountText: String = "0"
    public var receiverName: String = ""

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let cardView = UIView()
    private let headerLogoLabel = UILabel()
    private let timerLabel = UILabel()
    private let infoStackView = UIStackView()
    private let bankSectionLabel = UILabel()
    private let bankGridStackView = UIStackView()
    private let backButton = UIButton(type: .system)

    private var countdownTimer: Timer?
    private var expireDate: Date?
    private var beneficiary: BeneficiaryInfo?
    private var bankApps: [VietQRApp] = []

    private struct BeneficiaryInfo {
        let account: String
        let bankBIN: String
        let amount: String
        let content: String
        let beneficiaryName: String
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        HNLog.write("[VietQR] Fast COD transfer screen opened. waybillNo=\(waybillNo)")
        setupUI()
        populateData()
        renderBankButtons()
        startCountdown()
        VietQRBankDirectory.shared.ensureLoaded { [weak self] in
            self?.renderBankButtons()
        }
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1.0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        let navView = UIView()
        navView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(navView)

        let titleLabel = UILabel()
        titleLabel.text = "Chuyển khoản COD"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        navView.addSubview(titleLabel)

        let closeHeaderButton = UIButton(type: .system)
        closeHeaderButton.setTitle("X", for: .normal)
        closeHeaderButton.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .semibold)
        closeHeaderButton.setTitleColor(.label, for: .normal)
        closeHeaderButton.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        closeHeaderButton.translatesAutoresizingMaskIntoConstraints = false
        navView.addSubview(closeHeaderButton)

        NSLayoutConstraint.activate([
            navView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            navView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            navView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            navView.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: navView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: navView.centerYAnchor),
            closeHeaderButton.trailingAnchor.constraint(equalTo: navView.trailingAnchor),
            closeHeaderButton.centerYAnchor.constraint(equalTo: navView.centerYAnchor),
            closeHeaderButton.widthAnchor.constraint(equalToConstant: 40),
            closeHeaderButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        cardView.backgroundColor = .white
        cardView.layer.cornerRadius = 16
        cardView.layer.borderWidth = 2.5
        cardView.layer.borderColor = UIColor(red: 0.90, green: 0.22, blue: 0.21, alpha: 1.0).cgColor
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOffset = CGSize(width: 0, height: 4)
        cardView.layer.shadowRadius = 8
        cardView.layer.shadowOpacity = 0.08
        cardView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cardView)

        headerLogoLabel.text = "THÔNG TIN THU HỘ J&T"
        headerLogoLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        headerLogoLabel.textColor = UIColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1.0)
        headerLogoLabel.textAlignment = .center
        headerLogoLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(headerLogoLabel)

        timerLabel.text = ""
        timerLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        timerLabel.textColor = UIColor(red: 0.1, green: 0.45, blue: 0.9, alpha: 1.0)
        timerLabel.textAlignment = .center
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(timerLabel)

        infoStackView.axis = .vertical
        infoStackView.spacing = 12
        infoStackView.alignment = .fill
        infoStackView.distribution = .fill
        infoStackView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(infoStackView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: navView.bottomAnchor, constant: 12),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            headerLogoLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            headerLogoLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            headerLogoLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            timerLabel.topAnchor.constraint(equalTo: headerLogoLabel.bottomAnchor, constant: 10),
            timerLabel.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            infoStackView.topAnchor.constraint(equalTo: timerLabel.bottomAnchor, constant: 18),
            infoStackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            infoStackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            infoStackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18)
        ])

        bankSectionLabel.text = "Chọn ngân hàng để mở màn chuyển tiền"
        bankSectionLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        bankSectionLabel.textColor = .label
        bankSectionLabel.numberOfLines = 0
        bankSectionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bankSectionLabel)

        bankGridStackView.axis = .vertical
        bankGridStackView.spacing = 10
        bankGridStackView.alignment = .fill
        bankGridStackView.distribution = .fill
        bankGridStackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bankGridStackView)

        backButton.setTitle("Hoàn tất / Về danh sách đơn", for: .normal)
        backButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        backButton.setTitleColor(.secondaryLabel, for: .normal)
        backButton.backgroundColor = UIColor(white: 0.92, alpha: 1.0)
        backButton.layer.cornerRadius = 12
        backButton.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backButton)

        NSLayoutConstraint.activate([
            bankSectionLabel.topAnchor.constraint(equalTo: cardView.bottomAnchor, constant: 20),
            bankSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            bankSectionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            bankGridStackView.topAnchor.constraint(equalTo: bankSectionLabel.bottomAnchor, constant: 10),
            bankGridStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bankGridStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            backButton.topAnchor.constraint(equalTo: bankGridStackView.bottomAnchor, constant: 18),
            backButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            backButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            backButton.heightAnchor.constraint(equalToConstant: 46),
            backButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    private func populateData() {
        guard let payload = payData?.payload, !payload.isEmpty else {
            HNLog.write("[VietQR] Original J&T QR payload is missing.")
            renderSummary()
            showToast(message: "Không có payload QR J&T để đọc thông tin thu hộ.")
            return
        }

        let parsed = EMVQRParser.extractVietQRInfo(from: payload)
        guard let account = parsed.account,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let bankBIN = parsed.bin,
              !bankBIN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let payloadAmount = parsed.amount,
              !payloadAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let content = parsed.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            HNLog.write("[VietQR] Original payload is missing account, bank BIN, amount, or transfer content.")
            renderSummary()
            showToast(message: "Payload QR thiếu số tài khoản, ngân hàng, số tiền hoặc nội dung.")
            return
        }

        let hasFacebookOrder = waybillNo.split(separator: ",").contains {
            let w = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return w.hasPrefix("80")
        }
        let requestedAmount = HNVietQRBuilder.parseVND(amountText)
        let cached = HNCompactWorkflow.shared.cachedOrdersByWaybill[waybillNo]
        let fee = hasFacebookOrder ? HNVietQRBuilder.parseVND(cached?.taxAfterFee ?? "0") : 0
        let totalRequested = requestedAmount + fee
        let amount = hasFacebookOrder && totalRequested > 0 ? String(totalRequested) : payloadAmount

        let parsedName = parsed.beneficiaryName ?? ""
        let name = parsedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "J&T EXPRESS" : parsedName
        beneficiary = BeneficiaryInfo(
            account: account,
            bankBIN: bankBIN,
            amount: amount,
            content: content,
            beneficiaryName: name
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let data = payData, let expiry = dateFormatter.date(from: data.expireTime) {
            expireDate = expiry
        } else {
            expireDate = Date().addingTimeInterval(2.5 * 3600)
        }
        renderSummary()
        HNLog.write("[VietQR] Parsed original J&T payload: BIN=\(bankBIN), account=\(account), amount=\(amount), content=\(content)")
    }

    private func renderSummary() {
        infoStackView.arrangedSubviews.forEach {
            infoStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let info = beneficiary
        infoStackView.addArrangedSubview(copyableRow(label: "Tài khoản thu hộ", value: info?.account ?? ""))
        infoStackView.addArrangedSubview(copyableRow(label: "Số tiền", value: info?.amount ?? ""))
        infoStackView.addArrangedSubview(copyableRow(label: "Nội dung", value: info?.content ?? ""))
    }

    private func copyableRow(label: String, value: String) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.distribution = .fill

        let details = UIStackView()
        details.axis = .vertical
        details.spacing = 4
        details.alignment = .fill

        let titleLabel = UILabel()
        titleLabel.text = label
        titleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .secondaryLabel

        let valueLabel = UILabel()
        valueLabel.text = value.isEmpty ? "Chưa có dữ liệu" : value
        valueLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 0
        valueLabel.lineBreakMode = .byCharWrapping

        details.addArrangedSubview(titleLabel)
        details.addArrangedSubview(valueLabel)

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Sao chép", for: .normal)
        copyButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        copyButton.accessibilityValue = value
        copyButton.addTarget(self, action: #selector(copySummaryValue(_:)), for: .touchUpInside)

        row.addArrangedSubview(details)
        row.addArrangedSubview(copyButton)
        details.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    @objc private func copySummaryValue(_ sender: UIButton) {
        guard let value = sender.accessibilityValue, !value.isEmpty else {
            showToast(message: "Không có thông tin để sao chép.")
            return
        }
        UIPasteboard.general.string = value
        showToast(message: "Đã sao chép thông tin.")
    }

    private func startCountdown() {
        guard expireDate != nil else {
            timerLabel.isHidden = true
            return
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateTimerLabel()
        }
        updateTimerLabel()
    }

    private func updateTimerLabel() {
        guard let expiry = expireDate else { return }
        let difference = Int(expiry.timeIntervalSinceNow)
        if difference <= 0 {
            timerLabel.text = "Hết hiệu lực"
            timerLabel.textColor = .systemRed
            countdownTimer?.invalidate()
            return
        }
        let hours = difference / 3600
        let minutes = (difference % 3600) / 60
        let seconds = difference % 60
        timerLabel.text = String(format: "Hiệu lực trong %02d:%02d:%02d", hours, minutes, seconds)
    }

    private func renderBankButtons() {
        bankGridStackView.arrangedSubviews.forEach {
            bankGridStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        bankApps = VietQRBankDirectory.shared.apps.filter { $0.autofill == 1 }
        let lastUsedID = UserDefaults.standard.string(forKey: HNQRPrefs.lastBankKey)
        if let lastIndex = bankApps.firstIndex(where: { $0.appId.caseInsensitiveCompare(lastUsedID ?? "") == .orderedSame }) {
            let lastUsedApp = bankApps.remove(at: lastIndex)
            bankApps.insert(lastUsedApp, at: 0)
        }

        guard !bankApps.isEmpty else {
            let emptyLabel = UILabel()
            emptyLabel.text = "Không có ứng dụng ngân hàng hỗ trợ tự điền."
            emptyLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            emptyLabel.textColor = .secondaryLabel
            emptyLabel.textAlignment = .center
            emptyLabel.numberOfLines = 0
            bankGridStackView.addArrangedSubview(emptyLabel)
            return
        }

        for index in stride(from: 0, to: bankApps.count, by: 2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .fill
            row.distribution = .fillEqually
            row.addArrangedSubview(bankButton(for: bankApps[index], lastUsedID: lastUsedID))
            if index + 1 < bankApps.count {
                row.addArrangedSubview(bankButton(for: bankApps[index + 1], lastUsedID: lastUsedID))
            } else {
                row.addArrangedSubview(UIView())
            }
            bankGridStackView.addArrangedSubview(row)
        }
    }

    private func bankButton(for app: VietQRApp, lastUsedID: String?) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(app.appName, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.setTitleColor(.label, for: .normal)
        let isLastUsed = app.appId.caseInsensitiveCompare(lastUsedID ?? "") == .orderedSame
        button.backgroundColor = isLastUsed ? UIColor(red: 1.0, green: 0.91, blue: 0.88, alpha: 1.0) : .white
        button.layer.cornerRadius = 12
        button.layer.borderWidth = isLastUsed ? 2 : 1
        if isLastUsed {
            button.layer.borderColor = UIColor(red: 0.90, green: 0.22, blue: 0.21, alpha: 1.0).cgColor
        } else {
            button.layer.borderColor = UIColor(white: 0.86, alpha: 1.0).cgColor
        }
        button.heightAnchor.constraint(equalToConstant: 58).isActive = true
        button.accessibilityIdentifier = app.appId
        button.addTarget(self, action: #selector(bankButtonTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func bankButtonTapped(_ sender: UIButton) {
        guard let appID = sender.accessibilityIdentifier,
              let app = bankApps.first(where: { $0.appId.caseInsensitiveCompare(appID) == .orderedSame }) else {
            HNLog.write("[VietQR] Could not resolve tapped bank app button.")
            showToast(message: "Không xác định được ứng dụng ngân hàng.")
            return
        }
        openBank(app)
    }

    private func percentEncode(_ value: String) -> String? {
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters)
    }

    private func officialDeepLink(appID: String, info: BeneficiaryInfo) -> URL? {
        guard let bankCode = HNVietQRBankCodes.deepLinkRef(for: info.bankBIN) else {
            HNLog.write("[VietQR] Cannot resolve beneficiary BIN to a VietQR bank code: \(info.bankBIN)")
            return nil
        }
        guard let encodedAppID = percentEncode(appID),
              let encodedAccount = percentEncode(info.account),
              let encodedBankCode = percentEncode(bankCode),
              let encodedAmount = percentEncode(info.amount),
              let encodedContent = percentEncode(info.content),
              let encodedName = percentEncode(info.beneficiaryName),
              let encodedReturnURL = percentEncode(HNVietQRBankCodes.defaultReturnURL) else {
            HNLog.write("[VietQR] Could not percent-encode one or more deeplink values.")
            return nil
        }

        let link = "https://dl.vietqr.io/pay?app=\(encodedAppID)&ba=\(encodedAccount)@\(encodedBankCode)&am=\(encodedAmount)&tn=\(encodedContent)&bn=\(encodedName)&url=\(encodedReturnURL)"
        guard let url = URL(string: link) else {
            HNLog.write("[VietQR] Could not create URL from official deeplink.")
            return nil
        }
        return url
    }

    private func openBank(_ app: VietQRApp) {
        guard let info = beneficiary else {
            HNLog.write("[VietQR] Open blocked: required transfer details are missing from the original J&T payload.")
            showToast(message: "Không mở ngân hàng vì payload QR thiếu thông tin thu hộ.")
            return
        }
        guard let url = officialDeepLink(appID: app.appId, info: info) else {
            showToast(message: "Không xác định được mã ngân hàng nhận từ payload QR.")
            return
        }

        let now = Date()
        if let previousOpen = UserDefaults.standard.object(forKey: HNQRPrefs.lastOpenDateKey) as? Date,
           now.timeIntervalSince(previousOpen) < 2 {
            showToast(message: "Vui lòng đợi ít nhất 2 giây trước khi mở ngân hàng tiếp theo.")
            return
        }
        UserDefaults.standard.set(now, forKey: HNQRPrefs.lastOpenDateKey)

        HNLog.write("[VietQR] Official deeplink = \(url.absoluteString)")
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            HNLog.write("[VietQR] UIApplication.open completion: appId=\(app.appId), success=\(success)")
            if success {
                UserDefaults.standard.set(app.appId, forKey: HNQRPrefs.lastBankKey)
            }
            guard let self = self else { return }
            DispatchQueue.main.async {
                if success {
                    self.renderBankButtons()
                } else {
                    self.showToast(message: "Không mở được ứng dụng ngân hàng. Bạn vẫn có thể sao chép thông tin để nhập tay.")
                }
            }
        }
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }


    private func showToast(message: String, duration: TimeInterval = 3.5) {
        let toastLabel = UILabel()
        toastLabel.text = message
        toastLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 16
        toastLabel.clipsToBounds = true
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.numberOfLines = 0
        view.addSubview(toastLabel)

        NSLayoutConstraint.activate([
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            toastLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])

        UIView.animate(withDuration: 0.3, delay: duration, options: .curveEaseOut, animations: {
            toastLabel.alpha = 0.0
        }) { _ in
            toastLabel.removeFromSuperview()
        }
    }
}
