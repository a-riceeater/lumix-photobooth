import Foundation

// Platform-neutral PTP (ISO 15740) codec, ported from
// lumix-usb-research/src/lumix_usb/ptp.py. Everything is little-endian.

enum PTPOp {
    static let getDeviceInfo: UInt16 = 0x1001
    static let getStorageIDs: UInt16 = 0x1004
    static let getObjectInfo: UInt16 = 0x1008
    static let getObject: UInt16 = 0x1009
    static let getPartialObject: UInt16 = 0x101B
}

enum PTPResponseCode {
    static let ok: UInt16 = 0x2001
    static let generalError: UInt16 = 0x2002
    static let sessionNotOpen: UInt16 = 0x2003
    static let operationNotSupported: UInt16 = 0x2005
    static let parameterNotSupported: UInt16 = 0x2006
    static let invalidStorageID: UInt16 = 0x2008
    static let invalidObjectHandle: UInt16 = 0x2009
    static let deviceBusy: UInt16 = 0x2019
    static let invalidParameter: UInt16 = 0x201D

    static func name(_ code: UInt16) -> String {
        switch code {
        case 0x2001: return "OK"
        case 0x2002: return "GeneralError"
        case 0x2003: return "SessionNotOpen"
        case 0x2005: return "OperationNotSupported"
        case 0x2006: return "ParameterNotSupported"
        case 0x2008: return "InvalidStorageID"
        case 0x2009: return "InvalidObjectHandle"
        case 0x2019: return "DeviceBusy"
        case 0x201D: return "InvalidParameter"
        default: return String(format: "0x%04X", code)
        }
    }
}

enum PTPObjectFormat {
    static let association: UInt16 = 0x3001   // folder
    static let jpeg: UInt16 = 0x3801          // EXIF/JPEG
    static let undefinedImage: UInt16 = 0x3800 // RW2 on Panasonic
}

/// The camera answered, but not with OK (protocol-level error, not a transport failure).
struct PTPError: Error, CustomStringConvertible, Equatable {
    let opcode: UInt16
    let code: UInt16
    var description: String { String(format: "op 0x%04X -> %@ (0x%04X)", opcode, PTPResponseCode.name(code), code) }
}

struct PTPResponse {
    let opcode: UInt16
    let code: UInt16
    var params: [UInt32] = []
    var data = Data()

    var isOK: Bool { code == PTPResponseCode.ok }

    @discardableResult
    func check() throws -> PTPResponse {
        guard isOK else { throw PTPError(opcode: opcode, code: code) }
        return self
    }
}

struct PTPEvent: Equatable, Sendable {
    let code: UInt16
    var params: [UInt32] = []
}

enum PTPContainerType: UInt16 {
    case command = 1, data = 2, response = 3, event = 4
}

/// USB PTP container helpers (12-byte header: u32 length, u16 type, u16 code, u32 tid).
enum PTPContainer {
    static func command(opcode: UInt16, transactionID: UInt32, params: [UInt32]) -> Data {
        precondition(params.count <= 5, "PTP allows at most 5 parameters")
        var d = Data()
        d.appendLE(UInt32(12 + 4 * params.count))
        d.appendLE(PTPContainerType.command.rawValue)
        d.appendLE(opcode)
        d.appendLE(transactionID)
        for p in params { d.appendLE(p) }
        return d
    }

    /// Parses a response container (type 3) into code + params.
    static func parseResponse(_ data: Data) throws -> (code: UInt16, params: [UInt32]) {
        var r = ByteReader(data)
        let length = try r.u32()
        let type = try r.u16()
        let code = try r.u16()
        _ = try r.u32()
        guard type == PTPContainerType.response.rawValue else { throw ByteReader.Failure.malformed("container type \(type) is not a response") }
        var params: [UInt32] = []
        let end = min(Int(length), data.count)
        while r.position + 4 <= end && params.count < 5 { params.append(try r.u32()) }
        return (code, params)
    }

    /// Parses an event container (type 4). Returns nil for anything else.
    static func parseEvent(_ data: Data) -> PTPEvent? {
        var r = ByteReader(data)
        guard let length = try? r.u32(), let type = try? r.u16(), let code = try? r.u16(), (try? r.u32()) != nil,
              type == PTPContainerType.event.rawValue else { return nil }
        var params: [UInt32] = []
        let end = min(Int(length), data.count)
        while r.position + 4 <= end && params.count < 3, let p = try? r.u32() { params.append(p) }
        return PTPEvent(code: code, params: params)
    }
}

/// Sequential little-endian reader for PTP datasets.
struct ByteReader {
    enum Failure: Error { case truncated(Int), malformed(String) }

    private let bytes: [UInt8]
    private(set) var position: Int

    init(_ data: Data, offset: Int = 0) {
        bytes = [UInt8](data)
        position = offset
    }

    var remaining: Int { bytes.count - position }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard position + n <= bytes.count else { throw Failure.truncated(position) }
        defer { position += n }
        return bytes[position..<(position + n)]
    }

    private mutating func le<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let s = try take(MemoryLayout<T>.size)
        return s.reversed().reduce(T(0)) { ($0 << 8) | T($1) }
    }

    mutating func u8() throws -> UInt8 { try le(UInt8.self) }
    mutating func u16() throws -> UInt16 { try le(UInt16.self) }
    mutating func u32() throws -> UInt32 { try le(UInt32.self) }
    mutating func u64() throws -> UInt64 { try le(UInt64.self) }
    mutating func skip(_ n: Int) throws { _ = try take(n) }

    /// PTP string: u8 char count (incl. NUL), then UTF-16LE code units.
    mutating func string() throws -> String {
        let n = Int(try u8())
        if n == 0 { return "" }
        let raw = try take(2 * n)
        var units: [UInt16] = []
        var it = raw.makeIterator()
        while let lo = it.next(), let hi = it.next() { units.append(UInt16(lo) | UInt16(hi) << 8) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func array16() throws -> [UInt16] {
        let n = Int(try u32())
        guard n <= remaining / 2 else { throw Failure.truncated(position) }
        return try (0..<n).map { _ in try u16() }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }

    func le<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        var r = ByteReader(self, offset: offset)
        switch MemoryLayout<T>.size {
        case 1: return (try? r.u8()).map(T.init)
        case 2: return (try? r.u16()).map(T.init)
        case 4: return (try? r.u32()).map(T.init)
        default: return (try? r.u64()).map { T(truncatingIfNeeded: $0) }
        }
    }

    var hexPrefix: String { prefix(32).map { String(format: "%02x", $0) }.joined() }
}

struct DeviceInfo {
    var standardVersion: UInt16
    var vendorExtensionID: UInt32
    var operations: [UInt16]
    var events: [UInt16]
    var manufacturer: String
    var model: String
    var deviceVersion: String
    var serialNumber: String

    static func parse(_ data: Data) throws -> DeviceInfo {
        var r = ByteReader(data)
        let std = try r.u16()
        let vendor = try r.u32()
        _ = try r.u16()            // vendor extension version
        _ = try r.string()         // vendor extension desc
        _ = try r.u16()            // functional mode
        let ops = try r.array16()
        let events = try r.array16()
        _ = try r.array16()        // device props
        _ = try r.array16()        // capture formats
        _ = try r.array16()        // image formats
        return DeviceInfo(standardVersion: std, vendorExtensionID: vendor, operations: ops, events: events,
                          manufacturer: try r.string(), model: try r.string(),
                          deviceVersion: try r.string(), serialNumber: try r.string())
    }
}

struct ObjectInfo {
    var storageID: UInt32
    var format: UInt16
    var compressedSize: UInt64
    var width: UInt32
    var height: UInt32
    var filename: String

    var isJPEG: Bool { format == PTPObjectFormat.jpeg }

    /// Standard 0x1008 ObjectInfo dataset.
    static func parse(_ data: Data) throws -> ObjectInfo {
        var r = ByteReader(data)
        return try parseBody(&r, storage: try r.u32(), format: try r.u16(), protection: try r.u16(), size: UInt64(try r.u32()))
    }

    /// Panasonic 0x9110 variant (LUMIX Tether): u32 header, then ObjectInfo with u64 size.
    static func parsePanasonic(_ data: Data) throws -> ObjectInfo {
        var r = ByteReader(data, offset: 4)
        return try parseBody(&r, storage: try r.u32(), format: try r.u16(), protection: try r.u16(), size: try r.u64())
    }

    private static func parseBody(_ r: inout ByteReader, storage: UInt32, format: UInt16, protection _: UInt16, size: UInt64) throws -> ObjectInfo {
        _ = try r.u16()  // thumb format
        _ = try r.u32()  // thumb size
        _ = try r.u32()  // thumb width
        _ = try r.u32()  // thumb height
        let w = try r.u32()
        let h = try r.u32()
        _ = try r.u32()  // bit depth
        _ = try r.u32()  // parent
        _ = try r.u16()  // association type
        _ = try r.u32()  // association desc
        _ = try r.u32()  // sequence number
        let name = try r.string()
        return ObjectInfo(storageID: storage, format: format, compressedSize: size, width: w, height: h, filename: name)
    }
}
