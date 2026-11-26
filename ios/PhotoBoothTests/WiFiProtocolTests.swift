import XCTest
@testable import PhotoBooth

/// Wi-Fi codecs against payloads recorded from the S5II (fw 3.61) during research
/// (docs/lan-research-log.md, session 2).
final class WiFiProtocolTests: XCTestCase {
    private func sample(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext), "missing \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    func testDeviceDescription() throws {
        let d = try XCTUnwrap(WiFiCameraDescription(ddd: String(decoding: try sample("wifi_ddd", "xml"), as: UTF8.self)))
        XCTAssertEqual(d.modelNumber, "DC-S5M2")
        XCTAssertEqual(d.friendlyName, "S5M2-E86421")
        XCTAssertEqual(d.udn, "4D454930-0100-1000-8000-A0CDF3E86421")
        XCTAssertEqual(d.firmware, "3.61")
        XCTAssertNil(WiFiCameraDescription(ddd: "<root><manufacturer>Other</manufacturer><UDN>uuid:x</UDN></root>"))
    }

    func testPairingQueryMatchesTheVerifiedEncoding() {
        // Exactly what was sent (and granted) on the camera.
        let q = CamCGI.pairingQuery(udn: "4D454930-0100-1000-8000-A0CDF3E86421", clientName: "S5II Bridge")
        XCTAssertEqual(q, "mode=accctrl&type=req_acc_e&value=34443435343933302d303130302d313030302d383030302d413043444633453836343231&value2=53003500490049002000420072006900640067006500")
    }

    func testPairStates() {
        XCTAssertEqual(WiFiPairState(csv: "ok,S5M2-E86421,remote,open,E0010062B70E5467\n"), .granted("E0010062B70E5467"))
        XCTAssertEqual(WiFiPairState(csv: "ok_under_research,S5M2-E86421,remote,open"), .promptingOperator)
        XCTAssertEqual(WiFiPairState(csv: "ok_under_research_no_msg,S5M2-E86421,remote,open"), .decidingSilently)
        XCTAssertEqual(WiFiPairState(csv: "err_user_refused"), .refused)
        XCTAssertEqual(WiFiPairState(csv: "err_others_requesting"), .othersRequesting)
        XCTAssertEqual(WiFiPairState(csv: "<camrply><result>err_critical</result></camrply>"), .critical)
    }

    func testStateParsing() {
        let body = "<camrply><result>ok</result><state><batt>5/5</batt><rec>off</rec><cammode>rec</cammode><sd_access>off</sd_access><sd2_access>on</sd2_access></state></camrply>"
        XCTAssertEqual(CamCGI.result(body), "ok")
        let s = WiFiCameraState(raw: CamCGI.state(body))
        XCTAssertTrue(s.isRecordMode)
        XCTAssertFalse(s.isRecordingVideo)
        XCTAssertTrue(s.isWritingCard, "sd2_access counts as a card write")
        XCTAssertEqual(LumixWiFiCameraService.batteryPercent("5/5"), 100)
        XCTAssertEqual(LumixWiFiCameraService.batteryPercent("2/5"), 40)
        XCTAssertNil(LumixWiFiCameraService.batteryPercent("-1/0"))
    }

    func testContentInfoParsing() {
        let body = "<camrply>\n<result>ok</result>\n<current_position>8</current_position>\n<total_content_number>9</total_content_number>\n<content_number>9</content_number>\n</camrply>"
        XCTAssertEqual(CamCGI.tag("total_content_number", in: body).flatMap { Int($0) }, 9)
    }

    func testBrowseResponsePicksTheOriginalJPEG() throws {
        let items = ContentDirectory.items(fromBrowseResponse: String(decoding: try sample("wifi_browse_response", "xml"), as: UTF8.self))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "11542444")
        XCTAssertEqual(items[0].originalFileName, "P1542444.JPG")
        XCTAssertEqual(items[0].size, 11_601_920)
        XCTAssertEqual(items[0].jpegURL.absoluteString, "http://10.0.0.177:50001/DO11542444.JPG")
    }

    func testBrowseBodyUsesTheVerifiedShape() {
        let body = String(decoding: ContentDirectory.browseBody(start: 8, count: 1), as: UTF8.self)
        XCTAssertTrue(body.contains("<ObjectID>0</ObjectID>"))
        XCTAssertTrue(body.contains("<StartingIndex>8</StartingIndex><RequestedCount>1</RequestedCount>"))
        XCTAssertTrue(body.contains("<pana:X_FromCP>LumixLink2.0</pana:X_FromCP>"))
        XCTAssertTrue(body.contains("xmlns:pana=\"urn:schemas-panasonic-com:pana\""))
    }

    func testLiveViewDatagram() throws {
        let d = try sample("wifi_liveview_datagram", "bin")
        let jpeg = try XCTUnwrap(WiFiLiveViewParser.jpeg(fromDatagram: d))
        XCTAssertEqual(jpeg.count, d.count - 262)
        let img = try XCTUnwrap(PreviewFeed.decode(jpeg))
        XCTAssertEqual([img.width, img.height], [640, 480])
        XCTAssertNil(WiFiLiveViewParser.jpeg(fromDatagram: Data(repeating: 0, count: 100)))
    }
}
