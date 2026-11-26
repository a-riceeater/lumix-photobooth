import XCTest
@testable import PhotoBooth

/// Simulates the S5II's documented behaviour over PTP (docs/capture.md):
/// release → C109(0x12345678) → GetObjectInfo/GetObject, a FIFO SDRAM queue,
/// C101 status dumps carrying the AF result, and silent refusal after AF failure.
final class FakeS5Transport: PTPTransport, @unchecked Sendable {
    let name = "Fake S5II"
    let events: AsyncStream<PTPEvent>
    private let cont: AsyncStream<PTPEvent>.Continuation
    private let lock = NSLock()

    var focusFails = false
    var releaseGeneralErrors = 0
    var rawPlusJPEG = false
    var disconnected = false
    private(set) var log: [UInt16] = []
    private var queue: [(format: UInt16, data: Data, name: String)] = []
    private var captureTarget: UInt16 = 0
    private var quality: UInt16 = 4
    private var afState: UInt16 = 0xFFFE

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 64) + [0xFF, 0xD9])

    init() {
        var c: AsyncStream<PTPEvent>.Continuation!
        events = AsyncStream { c = $0 }
        cont = c
    }

    private func emit(_ code: UInt16, _ p: UInt32, after ms: UInt64) {
        Task {
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            cont.yield(PTPEvent(code: code, params: [p]))
        }
    }

    func execute(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval) async throws -> PTPResponse {
        try lock.withLock { try respond(opcode, params: params, outData: outData) }
    }

    private func respond(_ opcode: UInt16, params: [UInt32], outData: Data?) throws -> PTPResponse {
        if disconnected { throw CameraTransportError.disconnected }
        log.append(opcode)
        func ok(_ data: Data = Data()) -> PTPResponse { PTPResponse(opcode: opcode, code: PTPResponseCode.ok, data: data) }
        func err(_ c: UInt16) -> PTPResponse { PTPResponse(opcode: opcode, code: c) }
        switch opcode {
        case PTPOp.getDeviceInfo:
            return ok(try Data(contentsOf: Bundle(for: Self.self).url(forResource: "deviceinfo_wpd", withExtension: "bin")!))
        case PanasonicOp.openSession, PanasonicOp.closeSession, PanasonicOp.liveview:
            return ok()
        case PanasonicOp.getCaptureTarget:
            return ok(TLV.encode(code: PanasonicParam.captureTargetProp, value: UInt32(captureTarget), size: 2))
        case PanasonicOp.setCaptureTarget:
            captureTarget = TLV.parse(outData!)[PanasonicParam.captureTargetProp].flatMap(TLV.value).map { UInt16($0) } ?? 0
            return ok()
        case PanasonicOp.getProperty:
            switch params[0] {
            case PanasonicParam.imageModeGroup: return ok(TLV.encode(code: PanasonicParam.imageQuality, value: UInt32(quality), size: 2))
            case PanasonicParam.cameraModeGroup: return ok(TLV.encode(code: PanasonicParam.driveMode, value: 0, size: 2))
            case PanasonicParam.afGroup: return ok(TLV.encode(code: PanasonicParam.afMode, value: 5, size: 2))
            default: return err(PTPResponseCode.generalError)
            }
        case PanasonicOp.setProperty:
            if params[0] == PanasonicParam.imageQuality { quality = UInt16(TLV.parse(outData!)[PanasonicParam.imageQuality].flatMap(TLV.value) ?? 0) }
            return ok()
        case PanasonicOp.getStatus:
            if params[0] == PanasonicParam.batteryGroup {
                var d = Data(); d.appendLE(PanasonicParam.batteryPercent); d.appendLE(UInt32(8)); d.appendLE(UInt32(80)); d.appendLE(UInt16(80)); d.appendLE(UInt16(0xFFFF))
                return ok(d)
            }
            if params[0] == PanasonicParam.liveviewOptions {
                var d = Data(); d.appendLE(PanasonicParam.liveviewOptions); d.appendLE(UInt32(28)); d.appendLE(UInt16(2)); d.appendLE(UInt16(8))
                d.append(LiveviewSetting(height: 480, width: 640, frameKB: 32, fps: 30).pack().suffix(8))
                d.append(LiveviewSetting(height: 720, width: 960, frameKB: 250, fps: 30).pack().suffix(8))
                return ok(d)
            }
            if params[0] == PanasonicParam.liveviewCurrent { return ok(LiveviewSetting(height: 720, width: 960, frameKB: 250, fps: 30).pack()) }
            return err(PTPResponseCode.generalError)
        case PanasonicOp.setLiveviewSetting:
            return ok()
        case PanasonicOp.afControl:
            if params[0] == PanasonicParam.afOneShot {
                afState = focusFails ? AFState.failed.rawValue : AFState.inFocus.rawValue
                emit(PanasonicEvent.ackRequired, 0x0100_0010, after: 30)
            } else {
                afState = AFState.ended.rawValue
            }
            return ok()
        case PanasonicOp.ackEvent:
            var d = Data(); d.appendLE(PanasonicParam.statusAF); d.appendLE(UInt32(4)); d.appendLE(afState); d.appendLE(UInt16(0))
            return ok(d)
        case PanasonicOp.release:
            if releaseGeneralErrors > 0 { releaseGeneralErrors -= 1; return err(PTPResponseCode.generalError) }
            if focusFails { return ok() }   // accepted, then nothing happens (verified S5II behaviour)
            let wasEmpty = queue.isEmpty
            queue.append((PTPObjectFormat.jpeg, Self.jpeg, "CARDLESS.JPG"))
            if rawPlusJPEG { queue.append((PTPObjectFormat.undefinedImage, Data(repeating: 1, count: 128), "CARDLESS.RW2")) }
            if wasEmpty { emit(PanasonicEvent.objectAddedPC, PanasonicParam.sdramHandle, after: 40) }
            return ok()
        case PTPOp.getObjectInfo:
            guard params[0] == PanasonicParam.sdramHandle, let head = queue.first else { return err(PTPResponseCode.invalidParameter) }
            var d = Data()
            d.appendLE(UInt32(0)); d.appendLE(head.format); d.appendLE(UInt16(0)); d.appendLE(UInt32(head.data.count))
            d.appendLE(UInt16(0)); for _ in 0..<3 { d.appendLE(UInt32(0)) }
            d.appendLE(UInt32(6000)); d.appendLE(UInt32(4000)); d.appendLE(UInt32(0)); d.appendLE(UInt32(0)); d.appendLE(UInt16(0)); d.appendLE(UInt32(0)); d.appendLE(UInt32(0))
            let units = Array((head.name + "\0").utf16)
            d.append(UInt8(units.count)); for u in units { d.appendLE(u) }
            for _ in 0..<3 { d.append(0) }
            return ok(d)
        case PTPOp.getObject:
            guard !queue.isEmpty else { return err(PTPResponseCode.invalidParameter) }
            return ok(queue.removeFirst().data)
        default:
            return err(PTPResponseCode.operationNotSupported)
        }
    }

    func close() async { cont.finish() }
}

final class LumixCameraTests: XCTestCase {
    func testConnectConfiguresBoothSettings() async throws {
        let t = FakeS5Transport()
        let cam = LumixCamera(transport: t)
        let info = try await cam.connect(options: CameraOptions())
        XCTAssertEqual(info.model, "DC-S5M2")
        XCTAssertEqual(info.captureTarget, .pc)
        XCTAssertEqual(info.imageQuality, 0)
        XCTAssertEqual(info.focusMode, .afc)
        XCTAssertEqual(info.driveModeSingle, true)
        XCTAssertEqual(info.batteryPercent, 80)
        XCTAssertEqual(info.liveviewOptions.count, 2)

        await cam.disconnect()   // restores the camera's original target and quality
        XCTAssertEqual(t.log.suffix(4).contains(PanasonicOp.closeSession), true)
    }

    func testCaptureWithAutofocusReturnsJPEG() async throws {
        let t = FakeS5Transport()
        let cam = LumixCamera(transport: t)
        _ = try await cam.connect(options: CameraOptions())
        let jpeg = try await cam.captureWithAutofocus(true)
        XCTAssertEqual(jpeg, FakeS5Transport.jpeg)
        XCTAssertTrue(t.log.contains(PanasonicOp.afControl))
    }

    func testFocusFailureIsReportedInsteadOfWaiting() async throws {
        let t = FakeS5Transport()
        t.focusFails = true
        let cam = LumixCamera(transport: t)
        _ = try await cam.connect(options: CameraOptions())
        do {
            _ = try await cam.captureWithAutofocus(true)
            XCTFail("expected focus failure")
        } catch CaptureError.focusFailed {}
        XCTAssertFalse(t.log.contains(PanasonicOp.release), "must not release after a failed AF")
    }

    func testSilentRefusalTimesOut() async throws {
        let t = FakeS5Transport()
        t.focusFails = true
        let cam = LumixCamera(transport: t)
        _ = try await cam.connect(options: CameraOptions())
        do {
            _ = try await cam.capture(objectTimeout: 0.5)
            XCTFail("expected timeout")
        } catch CaptureError.noImage {}
    }

    func testGeneralErrorOnReleaseIsRetriedOnce() async throws {
        let t = FakeS5Transport()
        t.releaseGeneralErrors = 1
        let cam = LumixCamera(transport: t)
        _ = try await cam.connect(options: CameraOptions())
        let jpeg = try await cam.capture()
        XCTAssertEqual(jpeg, FakeS5Transport.jpeg)
        XCTAssertEqual(t.log.filter { $0 == PanasonicOp.release }.count, 2)
    }

    func testRawObjectsAreDrainedSoTheNextShotIsAnnounced() async throws {
        let t = FakeS5Transport()
        t.rawPlusJPEG = true
        let cam = LumixCamera(transport: t)
        _ = try await cam.connect(options: CameraOptions(forceJPEGFine: false))
        for _ in 0..<2 {
            let jpeg = try await cam.capture(objectTimeout: 2)
            XCTAssertEqual(jpeg, FakeS5Transport.jpeg)
        }
    }

    func testTransportFailureSurfacesAsTransportError() async throws {
        let t = FakeS5Transport()
        let cam = LumixCamera(transport: t)
        _ = try await cam.connect(options: CameraOptions())
        t.disconnected = true
        do {
            _ = try await cam.capture()
            XCTFail("expected an error")
        } catch let e as CameraTransportError {
            XCTAssertEqual(e, .disconnected)
        }
    }

    func testTimeoutFiresEvenIfOperationNeverReturns() async {
        let start = Date()
        do {
            _ = try await withTimeout(0.2, onTimeout: { CameraTransportError.timeout(opcode: 1) }) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }   // never resumes
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? CameraTransportError, .timeout(opcode: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
