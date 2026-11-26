# Physical device and camera testing

## What has and has not been verified

| Area | Status |
|---|---|
| S5II USB protocol (liveview, AF, release, JPEG retrieval, reconnect) | **Verified on Windows** via WPD in `lumix-usb-research/` (see its README). |
| Swift port of the PTP/Panasonic parsers | Unit tests against real S5II payloads from `lumix-usb-research/samples/`. |
| Swift capture algorithm (AF result, GeneralError retry, RAW drain, timeouts) | Unit tests against a simulated camera (`FakeS5Transport`), modelled on the documented behaviour. |
| iOS app and tests | Compiled (`xcodebuild build-for-testing`). The XCTest suite and the UI were **not run** during development (no simulator/device was used). |
| **ImageCaptureCore transport on iPhone/iPad with the real S5II** | **Not tested.** Nothing in this repository has been run against the camera on iOS/iPadOS yet. |

The iOS camera path follows `lumix-usb-research/docs/ipados-compatibility.md`. Its open risks apply unchanged and
must be checked on hardware before an event:

1. **Unadvertised vendor opcodes.** The S5II only lists 0x9102–0x9104 in DeviceInfo. If iOS filters
   `requestSendPTPCommand` against that list, 0x9402/0x9404/0x9405/0x9412/0x9706 would fail. *Symptom:* diagnostics
   log shows `OperationNotSupported` or an ImageCaptureCore error right after "opening …".
2. **Vendor events (C101/C108/C109)** must arrive through `ptpEventHandler`. *Symptom:* AF works only by timeout
   and every capture ends with "did not deliver an image in time". A polling fallback (`GetObjectInfo(0x12345678)`)
   is documented in the research but **not implemented** in the app.
3. **Liveview throughput** through ImageCaptureCore (30 fps needs ≤33 ms per transaction). Check the fps shown in
   *Camera diagnostics*; choose a smaller liveview size if it is low.
4. **ImageCaptureCore's own catalog requests** fail in PC(Tether) mode. The app waits at most 3 s for
   "catalog complete" and then proceeds; it is unknown whether ICC keeps the session open.
5. **Large data-in** (~10–13 MB JPEG in one `GetObject`). If it fails, chunked `GetPartialObject` (0x101B) would be
   needed — not implemented in the app.
6. **Transaction IDs**: the app puts an incrementing ID in each command container and assumes ICC manages it.
7. **Authorization prompt**: iOS asks for permission to control the camera (`requestControlAuthorization`).
8. **Power and link**: USB-C iPads/iPhones power the USB link only; use the camera battery/AC adapter. Lightning
   iPhones need Apple's Lightning-to-USB 3 camera adapter (with power).

### Wi-Fi camera

The Wi-Fi path (camera type *LUMIX S5II over Wi-Fi*) was verified end to end against the S5II with the app's own
Swift camera code compiled into a macOS harness: pairing, live view (30 fps), 3 captures, transfer of three
6000×4000 originals in 13.7 s, and the return to shooting mode (`docs/lan-research-log.md`, session 3). It has
**not yet run inside the iOS app on an iPhone/iPad**. To test it:

1. On the camera: *MENU → Setup → IN/OUT → LAN/Wi-Fi → Wi-Fi Function → New Connection → Remote Shooting & View →
   Via Network*, choose the same Wi-Fi network as the iPhone/iPad. Image quality must include JPEG.
2. In the app: *Settings ▸ Camera ▸ LUMIX S5II over Wi-Fi*. Allow *Local Network* access when iOS asks.
   The first time, the camera asks to allow the device name (default "Photo Booth") — accept it.
3. *Camera diagnostics* lists every camera command with its result. Run a session; expect ~2 s per photo and
   ~4 s per photo during "Bringing your photos over…".
4. If the state shows *Camera needs a check*: look at the camera (dismiss any message such as "connection
   lost"/"not connected to app", re-arm remote shooting if needed) **before** tapping *Reconnect*.
5. Do not open LUMIX Sync (or another app) on the same camera at the same time.
6. While the booth is connected the camera's own buttons are locked. *Settings ▸ Camera ▸ Disconnect camera*
   (also in diagnostics) stops the stream and lets go; it stays disconnected — even after relaunching the app —
   until *Connect camera*. Sending the app to the background or swiping it away releases the camera the same way
   (any transfer in progress finishes first); coming back reconnects automatically. Test: background the app,
   check the camera's buttons work, return, and confirm the booth reconnects within a few seconds.

## Step 1 — iPhone with the mock camera

1. `./scripts/bootstrap-ios.sh --open`, choose your team under *Signing & Capabilities* (or set
   `ios/PhotoBooth/Config/Local.xcconfig`), select the iPhone, Run.
2. Start the server on your Mac (`cd server && npm run dev`) and find the Mac's LAN IP.
3. In the app: tap the gear in the top-left corner (or hold that corner 1.5 s / tap it 5 times), PIN `0000`. Set *Server URL* `http://<mac-ip>:8080`, paste
   `DEVICE_API_KEY`, *Test connection* → "API key accepted". Camera: *Mock camera*. Change the PIN.
   (Allow "Local Network" access when iOS asks.)
4. Back to the booth: Start → countdown → 3 captures → review → share. Scan the QR code with another phone
   (same Wi-Fi, or use a tunnel with `PUBLIC_BASE_URL`).
5. Pick other designs on the gallery page, download a strip, a photo and the ZIP.
6. Enter an email (with SMTP configured on the server) and check delivery.
7. **Network loss:** turn on Airplane Mode, run two sessions, confirm the share screen says photos will upload
   later and the badge counts pending uploads; turn Airplane Mode off and watch *Upload queue* drain.
8. **Restart safety:** force-quit the app during a countdown and during an upload; relaunch; check *Upload queue*.
9. Set *Simulated capture failures* to 30 % and confirm guests see friendly retry messages.

## Step 2 — the real camera

Camera setup: USB mode **PC(Tether)** (Setup ▸ USB ▸ USB Mode), drive dial **single**, focus lever AF-C or AF-S
(MF skips AF), card inserted. Close LUMIX Tether or any other app using the camera.

1. Operator settings ▸ Camera ▸ *LUMIX S5II over USB*. Connect the camera (USB-C cable; a USB 3 cable may be
   faster) and allow the camera-control prompt.
2. *Camera diagnostics* should show: State *Connected*, model DC-S5M2, capture target "Direct to app",
   image quality JPEG FINE, drive dial single = yes, preview fps. Note any warnings.
3. *Take a test photo* → expect ~10–13 MB in roughly 1–3 s.
4. Run a full guest session and confirm the uploaded originals are 6000 × 4000 (gallery ▸ download photo).
5. **Shutter timing:** during a session the app starts autofocus before the countdown ends (0.6 s ahead in
   AF-C, 0.9 s in AF-S, from the AF times measured in the research) and fires the shutter *Shutter lead*
   (default 150 ms) before "Smile!" appears. The research measured AF time and release→JPEG time, but not the
   exact delay between the release command and the exposure, so tune *Settings ▸ Photos & timing ▸ Shutter
   fires … before "Smile!"* on site: if guests are caught mid-reaction, increase it; if photos are taken
   before the count finishes, lower it. *Camera diagnostics* logs each pre-focus time.
6. Cover the lens and take a test photo → expect "The camera could not focus" within ~1–3 s, no hang.
6. **Disconnect recovery:** during liveview pull the cable for ~10 s and reconnect; then power-cycle the camera.
   The state should go *Reconnecting* → *Connected* with liveview resuming. Check *Reconnects* and the log.
7. Pull the cable *during* a countdown: the guest sees "camera is taking a short break", photos already taken
   are kept and uploaded.
8. Leave it idle for 30+ minutes, then start a session (no keep-alive is used; the research found none needed).
9. After the event: *Operator settings ▸ Camera ▸ Mock*, or stop the app normally, so the app restores the
   camera's original capture target and quality. If the app was killed, set the target back with
   `python -m lumix_usb capture --target sd` (research CLI) or change USB mode on the camera.

If any of the risks above show up, collect the *Camera diagnostics* log (screenshots) — it records every
connect step, warnings and errors — and compare with `lumix-usb-research/docs/troubleshooting.md`.

## Step 3 — iPad

Repeat Step 1 quickly (layouts adapt to the larger screen and any orientation), then Step 2 with the camera on
the iPad's USB-C port. Enable **Guided Access** (Settings ▸ Accessibility ▸ Guided Access, set a passcode),
open the booth, triple-click the top/side button, and start. Auto-Lock is disabled by the app while it runs.
