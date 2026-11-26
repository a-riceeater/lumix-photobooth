import Foundation

// Wire formats for the S5II's Wi-Fi interface (DC-S5M2 fw 3.61):
//  * /cam.cgi on :80 — XML replies, except accctrl pairing which is CSV
//    (ported from ~/Developer/S5II-Bridge LumixKit/CamCGI.swift)
//  * UPnP ContentDirectory on :60606 — photo listing (needs X-SESSION_ID)
//  * :50001 — photo downloads
//  * UDP live view — one JPEG per datagram after a header
// Everything here was exercised on the camera; see docs/lan-research-log.md.

enum LumixWiFiError: Error, LocalizedError, Equatable {
    /// The camera refused pairing. Never retried: repeated refusals lock it out.
    case refused
    case notArmed(String)
    case notFound
    /// err_busy or an unexpected timeout: all traffic is halted until a person checks the camera.
    case halted(String)
    case camera(String)
    case transport(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .refused:
            return "The camera refused the connection. Arm it: MENU → Setup → IN/OUT → LAN/Wi-Fi → Wi-Fi Function → New Connection → Remote Shooting & View."
        case .notArmed(let s): return "The camera is not accepting connections (\(s)). Re-arm remote shooting on the camera."
        case .notFound: return "No LUMIX camera found on this Wi-Fi network."
        case .halted(let s): return "Stopped talking to the camera (\(s)). Check the camera, then tap Reconnect."
        case .camera(let s): return "Camera returned \(s)."
        case .transport(let s): return "Network error: \(s)."
        case .badResponse(let s): return "Unexpected reply: \(s)."
        }
    }
}

/// Result of a `req_acc_e` poll (CSV reply).
enum WiFiPairState: Equatable {
    case granted(String)
    case promptingOperator
    case decidingSilently
    case refused
    case othersRequesting
    case critical
    case unknown(String)

    init(csv raw: String) {
        let csv = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.first ?? "" {
        case "ok":
            if parts.count >= 2, let sid = parts.last, !sid.isEmpty { self = .granted(sid) } else { self = .unknown(csv) }
        case "ok_under_research": self = .promptingOperator
        case "ok_under_research_no_msg": self = .decidingSilently
        case "err_user_refused": self = .refused
        case "err_others_requesting": self = .othersRequesting
        default: self = csv.contains("err_critical") ? .critical : .unknown(String(csv.prefix(60)))
        }
    }
}

enum CamCGI {
    static func result(_ body: String) -> String? { tag("result", in: body) }

    static func tag(_ name: String, in body: String) -> String? {
        guard let open = body.range(of: "<\(name)>"),
              let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex) else { return nil }
        return String(body[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Flat <tag>value</tag> pairs of a getstate reply.
    static func state(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let re = try? NSRegularExpression(pattern: #"<([A-Za-z_][\w-]*)>([^<>]*)</\1>"#) else { return out }
        let ns = body as NSString
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    /// `value` = camera UDN as ASCII hex; `value2` = client name as hex of UTF-16LE
    /// (what the camera renders on its connect prompt).
    static func pairingQuery(udn: String, clientName: String) -> String {
        let v1 = Data(udn.utf8).map { String(format: "%02x", $0) }.joined()
        let v2 = clientName.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }.map { String(format: "%02x", $0) }.joined()
        return "mode=accctrl&type=req_acc_e&value=\(v1)&value2=\(v2)"
    }
}

/// getstate, reduced to what the booth needs.
struct WiFiCameraState: Equatable {
    var raw: [String: String]
    var camMode: String { raw["cammode"] ?? "?" }
    var isRecordMode: Bool { camMode == "rec" }
    var isPlayMode: Bool { camMode == "play" }
    var isRecordingVideo: Bool { raw["rec"] == "on" }
    /// Card activity on either slot (the S5II reports sd_access and sd2_access).
    var isWritingCard: Bool { raw["sd_access"] == "on" || raw["sd2_access"] == "on" }
    var battery: String { raw["batt"] ?? "?" }
}

/// UPnP device description served at :60606/Lumix/Server0/ddd.
struct WiFiCameraDescription: Equatable, Codable {
    var friendlyName: String
    var modelNumber: String
    var udn: String
    var firmware: String

    /// Nil unless it is a Panasonic device with a UDN (a hung camera still accepts TCP).
    init?(ddd xml: String) {
        let udn = CamCGI.tag("UDN", in: xml) ?? ""
        guard !udn.isEmpty, (CamCGI.tag("manufacturer", in: xml) ?? "").lowercased().contains("panasonic") else { return nil }
        self.udn = udn.hasPrefix("uuid:") ? String(udn.dropFirst(5)) : udn
        friendlyName = CamCGI.tag("friendlyName", in: xml) ?? ""
        modelNumber = CamCGI.tag("modelNumber", in: xml) ?? ""
        firmware = CamCGI.tag("pana:X_FirmVersion", in: xml) ?? ""
    }
}

/// One photo listed by the camera's ContentDirectory.
struct CameraContentItem: Equatable {
    var id: String
    /// e.g. "P1542445.JPG"
    var originalFileName: String
    var size: Int
    /// Full-resolution JPEG, e.g. http://10.0.0.177:50001/DO11542445.JPG
    var jpegURL: URL
    /// Camera-made preview (DL….JPG, CAM_LRGTN): 1620×1080, ~700 KB on the S5II (the listing says 100000).
    var previewURL: URL? = nil
}

enum ContentDirectory {
    /// SOAP Browse of `count` items starting at `start` (verified shape: ObjectID 0,
    /// X_FromCP LumixLink2.0). Never browse from 0 over a whole card — that hung the camera.
    static func browseBody(start: Int, count: Int) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\" "
            + "xmlns:pana=\"urn:schemas-panasonic-com:pana\"><ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter>"
            + "<StartingIndex>\(start)</StartingIndex><RequestedCount>\(count)</RequestedCount><SortCriteria></SortCriteria>"
            + "<pana:X_FromCP>LumixLink2.0</pana:X_FromCP></u:Browse></s:Body></s:Envelope>").utf8)
    }

    static let browseHeaders = [
        "Content-Type": "text/xml; charset=\"utf-8\"",
        "SOAPAction": "\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"",
        "User-Agent": "Panasonic Android/1 DM-CP",
    ]

    /// Parses a BrowseResponse (the DIDL is XML-escaped inside <Result>) into
    /// items that have an original JPEG (`DO….JPG`, OriginalFileName *.JPG).
    static func items(fromBrowseResponse soap: String) -> [CameraContentItem] {
        let didl = unescape(CamCGI.tag("Result", in: soap) ?? soap)
        var out: [CameraContentItem] = []
        var cursor = didl.startIndex
        while let open = didl.range(of: "<item ", range: cursor..<didl.endIndex),
              let close = didl.range(of: "</item>", range: open.upperBound..<didl.endIndex) {
            let item = String(didl[open.lowerBound..<close.upperBound])
            cursor = close.upperBound
            let id = attribute("id", in: item) ?? ""
            // Each <res protocolInfo="…OriginalFileName='X.JPG'" size="N">URL</res>
            var original: CameraContentItem?
            var preview: URL?
            var resCursor = item.startIndex
            while let r = item.range(of: "<res ", range: resCursor..<item.endIndex),
                  let gt = item.range(of: ">", range: r.upperBound..<item.endIndex),
                  let end = item.range(of: "</res>", range: gt.upperBound..<item.endIndex) {
                resCursor = end.upperBound
                let attrs = String(item[r.upperBound..<gt.lowerBound])
                let urlText = String(item[gt.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard let url = URL(string: urlText) else { continue }
                let file = url.lastPathComponent.uppercased()
                if file.hasPrefix("DL"), file.hasSuffix(".JPG") { preview = url }
                if original == nil, let name = originalFileName(in: attrs), name.uppercased().hasSuffix(".JPG"), file.hasPrefix("DO") {
                    original = CameraContentItem(id: id, originalFileName: name, size: Int(attribute("size", in: attrs) ?? "") ?? 0, jpegURL: url)
                }
            }
            if var o = original {
                o.previewURL = preview
                out.append(o)
            }
        }
        return out
    }

    static func attribute(_ name: String, in s: String) -> String? {
        guard let r = s.range(of: " \(name)=\"") ?? (s.hasPrefix("\(name)=\"") ? s.range(of: "\(name)=\"") : nil),
              let end = s.range(of: "\"", range: r.upperBound..<s.endIndex) else { return nil }
        return String(s[r.upperBound..<end.lowerBound])
    }

    private static func originalFileName(in attrs: String) -> String? {
        guard let r = attrs.range(of: "OriginalFileName='"), let end = attrs.range(of: "'", range: r.upperBound..<attrs.endIndex) else { return nil }
        return String(attrs[r.upperBound..<end.lowerBound])
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Live-view datagrams: a header, then ONE complete JPEG to the end of the
/// datagram. Header length = 32 + big-endian u16 at offset 30 (262 on the S5II).
enum WiFiLiveViewParser {
    static func jpeg(fromDatagram d: Data) -> Data? {
        let b = [UInt8](d)
        if b.count > 34 {
            let offset = 32 + (Int(b[30]) << 8 | Int(b[31]))
            if offset + 3 < b.count, b[offset] == 0xFF, b[offset + 1] == 0xD8 { return Data(b[offset...]) }
        }
        guard b.count >= 3 else { return nil }
        for i in 0..<(b.count - 2) where b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF { return Data(b[i...]) }
        return nil
    }
}
