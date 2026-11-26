import Darwin
import Foundation

/// HTTP to one S5II over Wi-Fi. Requests are strictly serialized (one in
/// flight) and guarded by a circuit breaker: the first `err_busy`, or a timeout
/// outside an expected unresponsive window, halts ALL traffic until `clearHalt()`.
/// That rule comes from two lock-ups during research (docs/lan-research-log.md).
actor LumixWiFiClient {
    let host: String
    private(set) var sessionID: String?
    private(set) var haltReason: String?
    /// While set (mode switches), timeouts are expected and do not halt.
    private var tolerateTimeoutsUntil: Date?
    private let gate = AsyncLock()
    private let session: URLSession
    var log: @Sendable (String) -> Void = { _ in }

    init(host: String) {
        self.host = host
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.httpMaximumConnectionsPerHost = 1
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    func setLogger(_ l: @escaping @Sendable (String) -> Void) { log = l }
    func setSession(_ id: String?) { sessionID = id }
    func clearHalt() { haltReason = nil }
    func expectUnresponsive(for seconds: TimeInterval) { tolerateTimeoutsUntil = Date().addingTimeInterval(seconds) }

    private func halt(_ why: String) {
        guard haltReason == nil else { return }
        haltReason = why
        log("HALT: \(why) — no further camera traffic until Reconnect")
    }

    /// One request through the gate. Returns (status, body).
    func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                 timeout: TimeInterval, withSession: Bool = true, label: String) async throws -> (Int, Data) {
        try await gate.withLock {
            if let h = haltReason { throw LumixWiFiError.halted(h) }
            var r = URLRequest(url: url)
            r.httpMethod = method
            r.timeoutInterval = timeout
            r.httpBody = body
            headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            if withSession, let sid = sessionID { r.setValue(sid, forHTTPHeaderField: "X-SESSION_ID") }
            let started = Date()
            do {
                let (data, resp) = try await session.data(for: r)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if label != "mode=getstate" {
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    let text = String(decoding: data.prefix(200), as: UTF8.self)
                    let summary = text.contains("<result>") ? (CamCGI.result(text) ?? "?") : text.hasPrefix("ok") || text.hasPrefix("err") ? String(text.prefix(40)) : "\(data.count) bytes"
                    log("\(label) → \(status) \(summary) (\(ms) ms)")
                }
                if let text = String(data: data.prefix(300), encoding: .utf8), text.contains("<result>err_busy</result>") {
                    halt("err_busy on \(label)")
                    throw LumixWiFiError.halted("err_busy on \(label)")
                }
                return (status, data)
            } catch let e as LumixWiFiError {
                throw e
            } catch {
                let tolerated = (tolerateTimeoutsUntil.map { Date() < $0 } ?? false)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if !tolerated { halt("\(label) failed after \(ms) ms: \(error.localizedDescription)") }
                throw LumixWiFiError.transport("\(label): \(error.localizedDescription)")
            }
        }
    }

    // MARK: cam.cgi

    func cgi(_ query: String, timeout: TimeInterval = 8, withSession: Bool = true) async throws -> String {
        guard let url = URL(string: "http://\(host)/cam.cgi?\(query)") else { throw LumixWiFiError.badResponse(query) }
        let (_, data) = try await request(url, timeout: timeout, withSession: withSession, label: query)
        return String(decoding: data, as: UTF8.self)
    }

    func state(timeout: TimeInterval = 4) async throws -> WiFiCameraState {
        let body = try await cgi("mode=getstate", timeout: timeout)
        guard CamCGI.result(body) == "ok" else { throw LumixWiFiError.camera(CamCGI.result(body) ?? "no result") }
        return WiFiCameraState(raw: CamCGI.state(body))
    }

    /// `camcmd` and other commands that answer <result>ok</result>.
    @discardableResult
    func command(_ query: String, timeout: TimeInterval = 8) async throws -> String {
        let body = try await cgi(query, timeout: timeout)
        let result = CamCGI.result(body) ?? "no result"
        guard result == "ok" else { throw LumixWiFiError.camera("\(result) for \(query)") }
        return body
    }

    // MARK: ContentDirectory and downloads

    func browse(start: Int, count: Int) async throws -> [CameraContentItem] {
        guard let url = URL(string: "http://\(host):60606/Server0/CDS_control") else { throw LumixWiFiError.badResponse("CDS URL") }
        let (status, data) = try await request(url, method: "POST", headers: ContentDirectory.browseHeaders,
                                               body: ContentDirectory.browseBody(start: start, count: count),
                                               timeout: 10, label: "Browse \(start)+\(count)")
        guard status == 200 else { throw LumixWiFiError.badResponse("Browse HTTP \(status)") }
        return ContentDirectory.items(fromBrowseResponse: String(decoding: data, as: UTF8.self))
    }

    func download(_ url: URL, expectedBytes: Int) async throws -> Data {
        // ~1.5–3 MB/s measured on Wi-Fi; generous but bounded.
        let timeout = max(30, Double(expectedBytes) / 500_000)
        let (status, data) = try await request(url, timeout: timeout, label: "GET \(url.lastPathComponent)")
        guard status == 200 else { throw LumixWiFiError.badResponse("download HTTP \(status)") }
        return data
    }
}

// MARK: - Discovery (port of S5II-Bridge LumixDiscovery: /24 sweep on :60606, no multicast entitlement)

enum LumixWiFiDiscovery {
    struct Found: Equatable {
        var host: String
        var description: WiFiCameraDescription
    }

    /// The device's own description, or nil (short timeout; used by the sweep).
    static func describe(host: String, timeout: TimeInterval = 1.5) async -> WiFiCameraDescription? {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.waitsForConnectivity = false
        let s = URLSession(configuration: c)
        defer { s.finishTasksAndInvalidate() }
        for path in ["/Lumix/Server0/ddd", "/Server0/ddd"] {
            guard let url = URL(string: "http://\(host):60606\(path)"),
                  let (data, resp) = try? await s.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let d = WiFiCameraDescription(ddd: String(decoding: data, as: UTF8.self)) else { continue }
            return d
        }
        return nil
    }

    /// Cached/explicit host first, then a bounded-concurrency sweep of the Wi-Fi /24.
    static func find(preferredHost: String?) async -> Found? {
        if let h = preferredHost, !h.isEmpty, let d = await describe(host: h, timeout: 2) { return Found(host: h, description: d) }
        for hosts in localSubnets() {
            if let f = await sweep(hosts) { return f }
        }
        return nil
    }

    private static func sweep(_ hosts: [String]) async -> Found? {
        await withTaskGroup(of: Found?.self) { group in
            var index = 0
            func add() {
                let h = hosts[index]
                index += 1
                group.addTask { await describe(host: h).map { Found(host: h, description: $0) } }
            }
            while index < min(48, hosts.count) { add() }
            while let result = await group.next() {
                if let f = result { group.cancelAll(); return f }
                if index < hosts.count { add() }
            }
            return nil
        }
    }

    /// Hosts of each up, non-loopback IPv4 interface (Wi-Fi en0 first), capped at a /24.
    static func localSubnets() -> [[String]] {
        var out: [(String, [String])] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = p {
            defer { p = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let a = ptr.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let m = ptr.pointee.ifa_netmask else { continue }
            let ip = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if mask < 0xFFFF_FF00 { mask = 0xFFFF_FF00 }
            let net = ip & mask, bcast = net | ~mask
            guard bcast > net + 1 else { continue }
            let hosts = (net + 1..<bcast).filter { $0 != ip }.map { "\($0 >> 24 & 255).\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)" }
            out.append((String(cString: ptr.pointee.ifa_name), hosts))
        }
        return out.sorted { ($0.0 == "en0" ? 0 : 1) < ($1.0 == "en0" ? 0 : 1) }.map(\.1)
    }
}
