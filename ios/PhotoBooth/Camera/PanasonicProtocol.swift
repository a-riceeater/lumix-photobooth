import Foundation

// Panasonic LUMIX vendor protocol constants and payload parsers, ported from
// lumix-usb-research/src/lumix_usb/panasonic.py. Only operations marked
// VERIFIED in lumix-usb-research/docs/command-reference.md are used by the app.

enum PanasonicOp {
    static let openSession: UInt16 = 0x9102        // p1 = 0x00010001
    static let closeSession: UInt16 = 0x9103       // p1 = 0x00010001
    static let ackEvent: UInt16 = 0x9401           // p1 = param1 of event 0xC101 (data in: status dump)
    static let getProperty: UInt16 = 0x9402        // p1 = property/group code (data in: TLV)
    static let setProperty: UInt16 = 0x9403        // p1 = property code (data out: TLV)
    static let release: UInt16 = 0x9404            // p1 = 0x03000011 shutter
    static let afControl: UInt16 = 0x9405          // p1 = 0x03000024 one-shot AF, 0x03000025 clear
    static let getCaptureTarget: UInt16 = 0x940A   // p1 = 0x08000090
    static let setCaptureTarget: UInt16 = 0x940B   // p1 = 0
    static let liveview: UInt16 = 0x9412           // p1 = 0x0D000010 start / 0x0D000011 stop
    static let getStatus: UInt16 = 0x9414          // p1 = status code (data in: TLV)
    static let setLiveviewSetting: UInt16 = 0x9415 // p1 = 0x0D800011 (data out)
    static let liveviewImage: UInt16 = 0x9706      // data in: TLV header + JPEG
}

enum PanasonicEvent {
    static let ackRequired: UInt16 = 0xC101     // host answers with 0x9401(param1)
    static let propChanged: UInt16 = 0xC102
    static let objectAddedSD: UInt16 = 0xC108   // p1 = object handle (SD card)
    static let objectAddedPC: UInt16 = 0xC109   // p1 = 0x12345678 (camera RAM, target PC)
}

enum PanasonicParam {
    static let session: UInt32 = 0x0001_0001
    static let liveviewStart: UInt32 = 0x0D00_0010
    static let liveviewStop: UInt32 = 0x0D00_0011
    static let liveviewCurrent: UInt32 = 0x0D80_0011
    static let liveviewOptions: UInt32 = 0x0D80_0012
    static let releaseShutter: UInt32 = 0x0300_0011
    static let afOneShot: UInt32 = 0x0300_0024
    static let afLockClear: UInt32 = 0x0300_0025
    static let captureTargetQuery: UInt32 = 0x0800_0090
    static let captureTargetProp: UInt32 = 0x0800_0091
    static let sdramHandle: UInt32 = 0x1234_5678
    static let batteryGroup: UInt32 = 0x1600_0010
    static let batteryPercent: UInt32 = 0x1600_0011
    static let recordingGroup: UInt32 = 0x1200_0010
    static let remainingShots: UInt32 = 0x1200_0011
    static let afGroup: UInt32 = 0x0200_0070
    static let afMode: UInt32 = 0x0200_0071
    static let cameraModeGroup: UInt32 = 0x0200_0080
    static let driveMode: UInt32 = 0x0200_0081
    static let imageModeGroup: UInt32 = 0x0200_00A0
    static let imageQuality: UInt32 = 0x0200_00A2
    static let statusAF: UInt32 = 0x0100_0011   // field in the 0x9401 status dump
}

enum CaptureTarget: UInt16, CaseIterable, Codable {
    case sdCard = 0
    case pc = 1        // "SDRAM": image held in camera RAM, announced with 0xC109

    var label: String { self == .sdCard ? "SD card" : "Direct to app (camera RAM)" }
}

/// 0x020000A2 values (S5II: {0,1,3,4,5}; 0 and 4 verified).
enum ImageQuality: UInt16 {
    case fine = 0, standard = 1, raw = 3, rawFine = 4, rawStandard = 5
}

/// 0x02000071 AF mode (physical lever; read-only over USB).
enum FocusMode: UInt16 {
    case manual = 3, afs = 4, afc = 5, aff = 6
    var label: String {
        switch self {
        case .manual: return "MF"
        case .afs: return "AF-S"
        case .afc: return "AF-C"
        case .aff: return "AF-F"
        }
    }
}

/// Values of 0x01000011 in the 0x9401 status dump (verified, AF-S/AF-C).
enum AFState: UInt16 {
    case none = 0xFFFE
    case inFocus = 0x0000
    case failed = 0x0004
    case ended = 0xFFFF
}

/// Panasonic payloads: repeated {u32 code, u32 size, size bytes value}.
enum TLV {
    static func parse(_ data: Data) -> [UInt32: Data] {
        let bytes = [UInt8](data)
        var out: [UInt32: Data] = [:]
        var off = 0
        while off + 8 <= bytes.count {
            let code = u32(bytes, off)
            let size = Int(u32(bytes, off + 4))
            guard size >= 0, off + 8 + size <= bytes.count else { break }
            out[code] = Data(bytes[(off + 8)..<(off + 8 + size)])
            off += 8 + size
        }
        return out
    }

    static func value(_ body: Data) -> UInt32? {
        switch body.count {
        case 1: return UInt32(body[body.startIndex])
        case 2: return body.le(UInt16.self, at: 0).map(UInt32.init)
        case 4: return body.le(UInt32.self, at: 0)
        default: return nil
        }
    }

    static func encode(code: UInt32, value: UInt32, size: Int) -> Data {
        var d = Data()
        d.appendLE(code)
        d.appendLE(UInt32(size))
        switch size {
        case 1: d.append(UInt8(truncatingIfNeeded: value))
        case 2: d.appendLE(UInt16(truncatingIfNeeded: value))
        default: d.appendLE(value)
        }
        return d
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

/// Liveview size entry (0x9414 0x0D800011/12, 0x9415).
struct LiveviewSetting: Equatable, Codable, Hashable {
    var height: UInt16
    var width: UInt16
    var frameKB: UInt16
    var fps: UInt16

    var label: String { "\(width)×\(height) @ \(fps) fps" }

    func pack() -> Data {
        var d = Data()
        d.appendLE(PanasonicParam.liveviewCurrent)
        d.appendLE(UInt32(8))
        d.appendLE(height); d.appendLE(width); d.appendLE(frameKB); d.appendLE(fps)
        return d
    }

    static func parseCurrent(_ data: Data) -> LiveviewSetting? {
        guard let h = data.le(UInt16.self, at: 8), let w = data.le(UInt16.self, at: 10),
              let k = data.le(UInt16.self, at: 12), let f = data.le(UInt16.self, at: 14) else { return nil }
        return LiveviewSetting(height: h, width: w, frameKB: k, fps: f)
    }

    static func parseOptions(_ data: Data) -> [LiveviewSetting] {
        guard let count = data.le(UInt16.self, at: 8), let stride = data.le(UInt16.self, at: 10), stride >= 8 else { return [] }
        return (0..<Int(count)).compactMap { i in
            let o = 12 + i * Int(stride)
            guard let h = data.le(UInt16.self, at: o), let w = data.le(UInt16.self, at: o + 2),
                  let k = data.le(UInt16.self, at: o + 4), let f = data.le(UInt16.self, at: o + 6) else { return nil }
            return LiveviewSetting(height: h, width: w, frameKB: k, fps: f)
        }
    }
}

/// Extracts the JPEG from a 0x9706 payload. Verified layout on DC-S5M2 fw 3.6:
/// TLV tags 0x17xxxxxx; 0x17000001 body[4..8] = JPEG offset (244 on S5II);
/// JPEG runs to the end of the payload. Falls back to searching FF D8 FF.
enum LiveviewFrameParser {
    static func jpeg(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        var off = 0
        var jpegOffset: Int?
        while off + 8 <= bytes.count {
            let tag = UInt32(bytes[off]) | UInt32(bytes[off + 1]) << 8 | UInt32(bytes[off + 2]) << 16 | UInt32(bytes[off + 3]) << 24
            guard tag >> 24 == 0x17 else { break }
            let size = Int(UInt32(bytes[off + 4]) | UInt32(bytes[off + 5]) << 8 | UInt32(bytes[off + 6]) << 16 | UInt32(bytes[off + 7]) << 24)
            if tag == 0x1700_0001, size >= 8, off + 16 <= bytes.count {
                let b = off + 8 + 4
                jpegOffset = Int(UInt32(bytes[b]) | UInt32(bytes[b + 1]) << 8 | UInt32(bytes[b + 2]) << 16 | UInt32(bytes[b + 3]) << 24)
            }
            off += 8 + size
        }
        if let o = jpegOffset, o + 2 <= bytes.count, bytes[o] == 0xFF, bytes[o + 1] == 0xD8 {
            return Data(bytes[o...])
        }
        // Fallback: first SOI marker.
        if bytes.count >= 3 {
            for i in 0..<(bytes.count - 2) where bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
                return Data(bytes[i...])
            }
        }
        return nil
    }
}
