import XCTest
@testable import PhotoBooth

/// Parsers checked against real S5II payloads from lumix-usb-research/samples
/// (expected values produced by the verified Python implementation).
final class PTPTests: XCTestCase {
    private func sample(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "bin"), "missing sample \(name)")
        return try Data(contentsOf: url)
    }

    func testCommandContainerMatchesDocumentedBytes() {
        // docs: liveview start = 10 00 00 00 01 00 12 94 TT TT TT TT 10 00 00 0d
        let d = PTPContainer.command(opcode: 0x9412, transactionID: 0, params: [0x0D00_0010])
        XCTAssertEqual([UInt8](d), [0x10, 0, 0, 0, 0x01, 0, 0x12, 0x94, 0, 0, 0, 0, 0x10, 0, 0, 0x0d])
    }

    func testResponseAndEventContainers() throws {
        var resp = Data()
        resp.appendLE(UInt32(16)); resp.appendLE(UInt16(3)); resp.appendLE(UInt16(0x2001)); resp.appendLE(UInt32(7)); resp.appendLE(UInt32(0x0001_0001))
        let (code, params) = try PTPContainer.parseResponse(resp)
        XCTAssertEqual(code, PTPResponseCode.ok)
        XCTAssertEqual(params, [0x0001_0001])

        var ev = Data()
        ev.appendLE(UInt32(16)); ev.appendLE(UInt16(4)); ev.appendLE(UInt16(0xC109)); ev.appendLE(UInt32(0)); ev.appendLE(UInt32(0x1234_5678))
        XCTAssertEqual(PTPContainer.parseEvent(ev), PTPEvent(code: 0xC109, params: [0x1234_5678]))
        XCTAssertNil(PTPContainer.parseEvent(resp))
    }

    func testDeviceInfoSample() throws {
        let info = try DeviceInfo.parse(try sample("deviceinfo_wpd"))
        XCTAssertEqual(info.vendorExtensionID, 0x1C)
        XCTAssertEqual(info.model, "DC-S5M2")
        XCTAssertEqual(info.manufacturer, "Panasonic")
    }

    func testPanasonicObjectInfoSample() throws {
        let oi = try ObjectInfo.parsePanasonic(try sample("objectinfo_9110_tether"))
        XCTAssertEqual(oi.filename, "P1542443.JPG")
        XCTAssertEqual(oi.format, PTPObjectFormat.jpeg)
        XCTAssertEqual(oi.compressedSize, 13_059_072)
        XCTAssertEqual(oi.width, 6000)
        XCTAssertEqual(oi.height, 4000)
    }

    func testLiveviewFrameSample() throws {
        let raw = try sample("liveview_raw_1")
        let jpeg = try XCTUnwrap(LiveviewFrameParser.jpeg(from: raw))
        XCTAssertEqual(jpeg.count, raw.count - 244)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertNotNil(PreviewFeed.decode(jpeg))
        XCTAssertNil(LiveviewFrameParser.jpeg(from: Data([1, 2, 3, 4])))
    }

    func testStatusDumpAFField() throws {
        let tlv = TLV.parse(try sample("ack_9401_01000010"))
        XCTAssertEqual(tlv.count, 13)
        let af = try XCTUnwrap(tlv[PanasonicParam.statusAF]?.le(UInt16.self, at: 0))
        XCTAssertEqual(AFState(rawValue: af), .ended)
    }

    func testTLVEncodeRoundTripAndLiveviewSettings() {
        // docs: ISO 400 = 21 00 00 02 04 00 00 00 90 01 00 00
        XCTAssertEqual([UInt8](TLV.encode(code: 0x0200_0021, value: 400, size: 4)), [0x21, 0, 0, 0x02, 4, 0, 0, 0, 0x90, 0x01, 0, 0])
        let parsed = TLV.parse(TLV.encode(code: 0x0800_0091, value: 1, size: 2))
        XCTAssertEqual(parsed[0x0800_0091].flatMap(TLV.value), 1)
        // docs: Tether chose 1100800d 08000000 d002 c003 fa00 1e00 (720x960, 250, 30)
        let s = LiveviewSetting(height: 720, width: 960, frameKB: 250, fps: 30)
        XCTAssertEqual(s.pack().map { String(format: "%02x", $0) }.joined(), "1100800d08000000d002c003fa001e00")
        XCTAssertEqual(LiveviewSetting.parseCurrent(s.pack()), s)
    }

    func testSessionIdsMatchServerFormat() {
        let ids = (0..<200).map { _ in LocalSession.newID() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids { XCTAssertNotNil(id.range(of: "^[A-Za-z0-9_-]{22}$", options: .regularExpression)) }
    }

    func testEmailValidation() {
        XCTAssertTrue(isValidEmail("guest@example.com"))
        XCTAssertFalse(isValidEmail("guest@example"))
        XCTAssertFalse(isValidEmail("a b@example.com"))
        XCTAssertEqual(maskEmail("jane@example.com"), "j***@example.com")
    }
}
