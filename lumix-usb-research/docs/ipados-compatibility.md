# iPadOS / ImageCaptureCore compatibility analysis

**Nothing here has been run on an iPad.** Windows results show what the *camera*
needs; whether iPadOS delivers it is a separate question. Status per item is
"camera-side VERIFIED" vs "iPadOS UNKNOWN" unless stated.

## What the camera requires from a transport (VERIFIED on Windows)

| Requirement | Needed? | Evidence |
|---|---|---|
| Standard PTP command/data/response on bulk EPs | **Yes** | All operations |
| PTP events from interrupt EP 0x82 | **Yes** (capture completion = C108/C109) | capture.md |
| Vendor opcodes not listed in DeviceInfo (0x9402…0x9706) | **Yes** | DeviceInfo lists only 0x9102–4 |
| Raw USB endpoint access | No | WPD gives none; everything worked |
| Vendor/class control transfers issued by the app | No | WPD exposes none |
| Additional USB interfaces | No | single interface |
| Custom driver | No | stock MTP class driver |
| Proprietary authentication / challenge | No | none observed (Tether traffic PENDING) |
| Specific transaction-ID or session behaviour | No | driver-assigned IDs and session worked |
| Sustained ~30 transactions/s | Yes, for 30 fps liveview | live-view.md |
| Data-in up to ~36 MB (RW2) / ~10 MB (JPEG) in one transaction | Yes (or use GetPartialObject 0x101B) | file-transfer.md |

LUMIX Tether 2.12 itself (Phase 2) also runs entirely on PTP transactions
through the stock Windows MTP driver — no control transfers, no extra interfaces,
no authentication (`tether-traffic.md`). So nothing Panasonic's own software does
needs more than ImageCaptureCore's command interface offers.

Because the Windows path is *already* "opcode + params + data through the OS
PTP stack" — the same abstraction ImageCaptureCore exposes — every verified
operation is **theoretically** expressible through ICC.

## ImageCaptureCore mapping

| Our transport call | ImageCaptureCore |
|---|---|
| enumerate, match VID 0x04DA | `ICDeviceBrowser` (`browsedDeviceTypeMask` camera+local), `ICCameraDevice.usbVendorID` |
| open (driver OpenSession) | `requestOpenSession(options:completion:)` |
| `execute(opcode, params, phase, out)` | `requestSendPTPCommand(_ command: Data, outData: Data?, completion: (Data, Data, Error?) -> Void)` |
| response code/params, data-in | completion `(data: inData, response: responseContainer)` — parse the 12-byte header + params |
| events | `ICCameraDeviceDelegate.cameraDevice(_:didReceivePTPEvent:)` gives the event container (`u32 len, u16 type=4, u16 code, u32 tid, params`) |
| close | `requestCloseSession` |

`command` is a full **PTP command container** the app must build:
```
u32 length = 12 + 4*nparams
u16 type   = 1 (command)
u16 code   = opcode
u32 transactionID   (ICC is documented to manage this; set 0 and verify on device)
u32 params[0..5]
```
Example — liveview start: `10 00 00 00 01 00 12 94 00 00 00 00 10 00 00 0d`.
Response container (`type=3`): code at offset 6 (e.g. `01 20` = OK), params from offset 12.

## Risks to validate on iPad (ordered by impact)

1. **Unadvertised vendor opcodes.** If iPadOS checks `command` opcodes against
   DeviceInfo.OperationsSupported, 0x9402/0x9404/0x9405/0x9412/0x9706 would be
   rejected. Windows does not filter. *Test first:* `0x9706` and `0x9404`.
2. **Vendor events.** Must arrive through `didReceivePTPEvent`. If ICC swallows
   unknown event codes, fallback: poll for new objects — e.g. call
   `GetObjectInfo(0x12345678)` in PC target (returns InvalidParameter while the
   queue is empty, ObjectInfo when an image is ready — VERIFIED behaviour), or
   poll `0x9414(0x12000010)` remaining-shots changes.
3. **Liveview throughput.** 30 fps requires per-transaction latency ≤33 ms through
   ICC's XPC path. Unknown; 640×432 frames are only ~22 KiB.
4. **ICC's own catalog traffic.** On session open ICC enumerates storage; in
   PC(Tether) these calls fail (InvalidStorageID / ParameterNotSupported). ICC
   might report an empty or errored catalog — acceptable as long as the session
   stays open. Unknown whether ICC aborts.
5. **Large data-in.** A 10 MB JPEG in one `requestSendPTPCommand` should be fine;
   if not, use 0x101B GetPartialObject in 1–4 MB chunks (implemented, untested).
6. **Authorization.** iPadOS may require user consent for camera-device control/
   contents (API names and requirement to be confirmed against current SDK).
7. **Power.** Configuration 1 is bus-powered (500 mA); the iPad will power the USB
   link. The camera battery powers the body; plan external power for long events.
8. **Link speed.** iPad USB-C ports with a USB 3 cable may enumerate SuperSpeed —
   untested here (Windows link was USB 2.0).

## Not needed by the booth (avoid on iPad)
Card browsing (unsupported in tether mode anyway), firmware/format/power ops.

## Porting checklist for the Swift phase
* Port `ptp.py` (containers + datasets), `panasonic.py` (opcodes, TLV, liveview
  parser, capture algorithm) verbatim; replace `transport/wpd.py` with an ICC
  transport implementing `execute(opcode, params, phase, outData)`.
* Serialize all commands (one in flight).
* Keep the retry rules: InvalidParameter after LV stop; GeneralError on release.
* Ack C101 with 0x9401 from outside the event callback.
* In PC target, drain every queued object.
