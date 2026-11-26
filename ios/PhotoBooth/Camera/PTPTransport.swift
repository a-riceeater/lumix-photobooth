import Foundation

/// Failures below the PTP protocol: the transaction did not complete.
enum CameraTransportError: Error, LocalizedError, Equatable {
    case notAuthorized
    case noCamera
    case disconnected
    case timeout(opcode: UInt16)
    case sessionFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access was not allowed. Enable it in Settings ▸ Privacy."
        case .noCamera: return "No camera connected."
        case .disconnected: return "The camera was disconnected."
        case .timeout(let op): return String(format: "The camera did not answer (op 0x%04X).", op)
        case .sessionFailed(let m): return "Could not open the camera session: \(m)"
        case .commandFailed(let m): return "Camera command failed: \(m)"
        }
    }
}

/// One open connection to one PTP camera.
///
/// The contract mirrors ImageCaptureCore's `requestSendPTPCommand` (and the
/// research `Transport.execute`): opcode + up to 5 params + optional outgoing
/// data; returns response code/params and any incoming data. Implementations
/// must serialize transactions (one in flight at a time).
protocol PTPTransport: AnyObject, Sendable {
    var name: String { get }
    /// Events from the interrupt endpoint, in arrival order.
    var events: AsyncStream<PTPEvent> { get }
    func execute(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval) async throws -> PTPResponse
    func close() async
}

extension PTPTransport {
    func read(_ opcode: UInt16, _ params: UInt32..., timeout: TimeInterval = 10) async throws -> PTPResponse {
        try await execute(opcode, params: params, outData: nil, timeout: timeout)
    }

    func command(_ opcode: UInt16, _ params: UInt32..., timeout: TimeInterval = 10) async throws -> PTPResponse {
        try await execute(opcode, params: params, outData: nil, timeout: timeout)
    }

    func write(_ opcode: UInt16, data: Data, _ params: UInt32..., timeout: TimeInterval = 10) async throws -> PTPResponse {
        try await execute(opcode, params: params, outData: data, timeout: timeout)
    }
}

/// FIFO async mutex: serializes PTP transactions across tasks.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let v = try await body()
            unlock()
            return v
        } catch {
            unlock()
            throw error
        }
    }
}

/// Runs `operation` but gives up after `seconds` (the operation keeps running
/// in the background; callers treat the transport as broken afterwards).
func withTimeout<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Error,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw onTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
