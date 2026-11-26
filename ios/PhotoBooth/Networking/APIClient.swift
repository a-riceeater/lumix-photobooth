import Foundation

enum APIError: Error, LocalizedError, Equatable {
    case invalidServerURL
    case missingAPIKey
    case unauthorized
    case network(String)
    case http(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "The server URL is not valid"
        case .missingAPIKey: return "No API key is configured"
        case .unauthorized: return "The server rejected the API key"
        case .network(let m): return "Network: \(m)"
        case .http(let s, let c, let m): return "HTTP \(s) \(c): \(m)"
        }
    }

    /// Errors worth retrying automatically (connectivity, server hiccups, rate limits).
    var isTransient: Bool {
        switch self {
        case .network: return true
        case .http(let status, _, _): return status >= 500 || status == 429 || status == 408 || status == 404 || status == 422
        default: return false
        }
    }
}

struct ServerConfig: Decodable, Equatable {
    var publicBaseUrl: String
    var emailEnabled: Bool
    var authenticated: Bool
    var maxUploadBytes: Int
}

struct ServerSessionStatus: Decodable, Equatable {
    struct Photo: Decodable, Equatable {
        var index: Int
        var sha256: String
    }
    var id: String
    var status: String
    var photoCount: Int
    var photos: [Photo]
    var missing: [Int]
    var galleryUrl: String
}

struct DesignInfo: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var photoCount: Int
}

/// Thin client for the photo booth server REST API (see README "API").
struct APIClient {
    var baseURL: String
    var apiKey: String
    var session: URLSession = .shared

    static func makeURLSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 10 * 60
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var comps = URLComponents(string: trimmed + path), let scheme = comps.scheme, ["http", "https"].contains(scheme), comps.host != nil else {
            throw APIError.invalidServerURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let u = comps.url else { throw APIError.invalidServerURL }
        return u
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil, auth: Bool = true) throws -> URLRequest {
        var r = URLRequest(url: try url(path, query: query))
        r.httpMethod = method
        if auth {
            guard !apiKey.isEmpty else { throw APIError.missingAPIKey }
            r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func check(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw APIError.network("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError.http(status: http.statusCode, code: body?["error"] as? String ?? "",
                                message: body?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    private func send(_ r: URLRequest) async throws -> Data {
        do {
            let (data, resp) = try await session.data(for: r)
            return try check(data, resp)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    // MARK: Endpoints

    func config() async throws -> ServerConfig {
        var r = try request("GET", "/api/config", auth: false)
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return try JSONDecoder().decode(ServerConfig.self, from: try await send(r))
    }

    func designs(photoCount: Int? = nil) async throws -> [DesignInfo] {
        struct Wrap: Decodable { var designs: [DesignInfo] }
        let query = photoCount.map { [URLQueryItem(name: "photoCount", value: String($0))] } ?? []
        let r = try request("GET", "/api/designs", query: query, auth: false)
        return try JSONDecoder().decode(Wrap.self, from: try await send(r)).designs
    }

    func createSession(_ s: LocalSession, deviceName: String) async throws {
        var body: [String: Any] = [
            "id": s.id, "eventId": s.eventId, "eventName": s.eventName, "photoCount": s.photoCount,
            "capturedAt": ISO8601DateFormatter().string(from: s.createdAt), "deviceName": deviceName,
        ]
        if let d = s.designId { body["designId"] = d }
        _ = try await send(try request("POST", "/api/sessions", json: body))
    }

    func uploadPhoto(sessionId: String, index: Int, sha256: String, file: URL) async throws {
        var r = try request("POST", "/api/sessions/\(sessionId)/photos",
                            query: [URLQueryItem(name: "index", value: String(index)), URLQueryItem(name: "sha256", value: sha256)])
        r.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 300
        do {
            let (data, resp) = try await session.upload(for: r, fromFile: file)
            _ = try check(data, resp)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    func requestEmail(sessionId: String, address: String) async throws {
        _ = try await send(try request("POST", "/api/sessions/\(sessionId)/email", json: ["email": address]))
    }

    func complete(sessionId: String, sha256: [String]) async throws {
        _ = try await send(try request("POST", "/api/sessions/\(sessionId)/complete", json: ["sha256": sha256]))
    }

    func status(sessionId: String) async throws -> ServerSessionStatus {
        try JSONDecoder().decode(ServerSessionStatus.self, from: try await send(try request("GET", "/api/sessions/\(sessionId)/status")))
    }
}
