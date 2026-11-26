import Foundation
import Security

/// One guest session as persisted on the device (session.json next to the photos).
struct LocalSession: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// Photos are being taken; not uploaded yet.
        case capturing
        /// All photos taken (or capture ended early); waiting for upload.
        case ready
        /// Server verified every photo; the gallery is live.
        case synced
        /// Upload hit an error that needs the operator (e.g. ID conflict).
        case failed
    }

    struct Photo: Codable, Equatable {
        var index: Int
        var filename: String
        var sha256: String
        var bytes: Int
        var uploaded = false
    }

    struct EmailRequest: Codable, Equatable, Identifiable {
        var id = UUID()
        /// Cleared once the server has accepted the request.
        var address: String?
        var masked: String
        var submittedAt: Date
        var delivered = false
        var note: String?
    }

    let id: String
    var eventId: String
    var eventName: String
    var createdAt: Date
    var photoCount: Int
    var designId: String?
    var galleryBaseURL: String
    var state: State = .capturing
    var photos: [Photo] = []
    var emails: [EmailRequest] = []
    var serverCreated = false
    var serverCompleted = false
    var attempts = 0
    var lastError: String?
    var nextAttemptAt: Date?
    var syncedAt: Date?
    var localFilesDeleted = false

    var galleryURL: URL? { URL(string: "\(galleryBaseURL)/s/\(id)") }
    var uploadedCount: Int { photos.filter(\.uploaded).count }
    var pendingEmails: [EmailRequest] { emails.filter { !$0.delivered && $0.address != nil } }

    /// 128 random bits, base64url (22 chars) — matches the server's SESSION_ID_RE.
    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "secure random generator failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func filename(for index: Int) -> String { String(format: "%02d.jpg", index + 1) }
}

/// "jane@example.com" -> "j***@example.com"
func maskEmail(_ s: String) -> String {
    guard let at = s.lastIndex(of: "@"), at > s.startIndex else { return "***" }
    return "\(s[s.startIndex])***\(s[at...])"
}

func isValidEmail(_ s: String) -> Bool {
    let pattern = #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$"#
    return s.count <= 254 && s.range(of: pattern, options: .regularExpression) != nil
}
