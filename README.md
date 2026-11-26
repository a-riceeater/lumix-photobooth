# Lumix Photo Booth

A self-hosted digital photo booth: a native SwiftUI app for iPhone/iPad that drives a **Panasonic LUMIX S5II**
over USB, and a small Node.js server that stores the photos, renders photo strips and serves a mobile-friendly
gallery reachable by QR code or email.

```text
lumix-photobooth/
  ios/                   SwiftUI app (XcodeGen project), camera protocol, offline upload queue
  server/                Node.js + TypeScript server: API, gallery website, strip renderer, email, CLI
  designs/               Photo strip templates (folder per design: design.json + PNGs)
  docs/                  API, designs, deployment, hardware testing
  scripts/               bootstrap-ios.sh
  lumix-usb-research/    S5II USB protocol research (source of truth for camera communication)
```

**Status:** the server is complete and covered by an automated test suite (46 tests, all passing). The iOS app
and its unit tests compile; they have not been run on a simulator or device during development, and the
ImageCaptureCore camera path **has not been tested with the physical camera yet** — see
[docs/hardware-testing.md](docs/hardware-testing.md) before using it at an event.

## How it works

1. The guest taps **Start** on the welcome screen (fullscreen live preview, framing guides).
2. A large countdown runs before each photo (default 3 photos, 5 s countdown); the camera fires and the
   full-resolution JPEG is transferred over USB.
3. Every photo is written to the device's storage **before** any upload. The guest reviews the shots (optional retake).
4. The session joins a persistent upload queue. The next guest can start immediately.
5. The share screen shows a QR code for `https://<server>/s/<sessionId>` — the ID is generated on the device
   (128 random bits), so the link works before the upload finishes ("your photos are on their way" until then).
6. Optionally the guest enters an email address; the server emails the link once the photos are online.
7. On the gallery page guests view and download each photo, download all as a ZIP, pick any photo strip design
   (rendered on demand at full resolution) and share via the phone's share sheet.

## Quick start (no camera needed)

Requirements: Node.js 20+ (24 recommended); for the app, macOS with Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
# 1. Server
cd server
npm ci
npm run init-env            # .env with random DEVICE_API_KEY and ADMIN_PASSWORD
npm run seed -- --public    # sample event with sessions made of synthetic photos
npm run dev                 # http://localhost:8080
```

Open a seeded `http://localhost:8080/s/…` link (printed by the seed), the event gallery
`http://localhost:8080/gallery/sample-event`, and the admin page `http://localhost:8080/admin/`
(password: `grep ADMIN_PASSWORD server/.env`).

```bash
# 2. iOS app
./scripts/bootstrap-ios.sh --open
```

Run on an iPhone or iPad (choose your signing team in Xcode). On first launch tap the **gear in the top-left
corner** (or hold that corner 1.5 s / tap it 5 times), enter PIN **0000**, then set *Server URL* (your Mac's LAN address, e.g. `http://192.168.1.20:8080`),
paste `DEVICE_API_KEY`, choose *Mock camera*, tap *Test connection* and change the PIN. The full workflow now
works without the camera. Physical testing steps: [docs/hardware-testing.md](docs/hardware-testing.md).

## Server

Express 5, SQLite (better-sqlite3), Sharp, Nodemailer, archiver — one process, one port, no other infrastructure.

| Command | Purpose |
|---|---|
| `npm run dev` | Development server with reload |
| `npm run build && npm start` | Production build / run (`node dist/index.js`) |
| `npm test` | Test suite (vitest + supertest) |
| `npm run seed -- [--event id] [--name "…"] [--sessions 5] [--photos 3] [--public]` | Sample data without a camera |
| `npm run cli -- <command>` | Admin CLI: `events`, `create-event`, `rename-event`, `gallery`, `delete-event`, `sessions`, `delete-session`, `retry-emails`, `designs` |
| `npm run designs -- <command>` | Design tool: `validate`, `preview`, `write-previews`, `new` |
| `npm run backup -- <dir>` | Online backup of database + photos |
| `npm run init-env` | Create `.env` with random secrets |

Deployment (systemd, Docker/Compose, Cloudflare Tunnel, reverse proxies, backup/restore):
[docs/deployment.md](docs/deployment.md). REST API: [docs/api.md](docs/api.md).

### Configuration (`server/.env`)

| Variable | Default | Description |
|---|---|---|
| `PORT` / `HOST` | `8080` / `0.0.0.0` | Listen address (API and website share it). |
| `PUBLIC_BASE_URL` | `http://localhost:PORT` | Public URL used in QR codes, emails and gallery links. |
| `TRUST_PROXY` | `0` | Number of reverse proxies in front (set `1` behind Cloudflare Tunnel/nginx/Caddy). |
| `DATA_DIR` | `./data` | SQLite database location. |
| `PHOTOS_DIR` | `DATA_DIR/events` | Photo storage (originals, thumbnails, generated strips); may be on another disk. |
| `DESIGNS_DIR` | `../designs` | Design templates. |
| `DEVICE_API_KEY` | **required** (≥16 chars) | Shared secret for booth uploads (`Authorization: Bearer …`). |
| `ADMIN_PASSWORD` | **required** (≥8 chars) | Admin page / admin API password. |
| `SMTP_HOST` | empty = email off | SMTP server. Without it email is disabled; QR downloads keep working. |
| `SMTP_PORT` / `SMTP_SECURE` | `587` / `false` | `true` for implicit TLS (465). |
| `SMTP_USER` / `SMTP_PASSWORD` | | SMTP credentials (server-side only; never in the app). |
| `SMTP_FROM_NAME` / `SMTP_FROM_EMAIL` | `Photo Booth` / required with SMTP | Sender. |
| `EMAIL_MAX_PER_SESSION` / `EMAIL_MAX_PER_HOUR` | `3` / `200` | Anti-abuse limits. |
| `MAX_UPLOAD_MB` | `50` | Max size of one photo upload. |
| `MAX_IMAGE_DIMENSION` | `12000` | Max width/height of an uploaded photo. |
| `PUBLIC_EVENT_GALLERY` | `false` | Default visibility of event-wide galleries for new events. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`. |

Configuration is validated at startup; all problems are listed at once.

### Storage layout

```text
data/photobooth.sqlite                    events, sessions, photo order + checksums, email queue
PHOTOS_DIR/<eventId>/sessions/<sessionId>/
  originals/01.jpg 02.jpg 03.jpg          byte-identical uploads, written once, never overwritten
  thumbnails/01-thumb.jpg 01-medium.jpg   cached, EXIF-rotated copies
  generated/<design>-<fingerprint>-full.jpg  cached strips
```

Originals are staged in `PHOTOS_DIR/.tmp`, fsynced and published with `link()` (atomic, fails instead of
replacing). Database writes are transactional (WAL). Restarting at any moment is safe.

### Galleries and privacy

* Session links `/s/<id>` always work and need no account; IDs are 128-bit random.
* Event galleries `/gallery/<eventId>` are **off by default**; per event they can be *public* or
  *password-protected* (admin page or `npm run cli -- gallery <event> password <pw>`).
* Guest email addresses are never shown publicly or logged, are deleted from the server after delivery
  (only a masked form like `j***@example.com` remains for the admin), and deleted from the device once the
  server has accepted the request.

## iOS app

SwiftUI, iOS/iPadOS 17+, no third-party dependencies. `./scripts/bootstrap-ios.sh` checks Xcode/XcodeGen
(with install instructions), generates `ios/PhotoBooth.xcodeproj` and leaves it ready to open. The project is
not committed; regenerate after pulling. Signing is not configured: set your team in Xcode or copy
`ios/PhotoBooth/Config/Local.xcconfig.example` to `Local.xcconfig` (`PHOTOBOOTH_BUNDLE_ID`, `DEVELOPMENT_TEAM`).

```text
ios/PhotoBooth/
  App/         PhotoBoothApp, AppModel (composition root, camera hub)
  Camera/      PTP codec, Panasonic protocol, PTPTransport (+ ImageCaptureCore USB transport),
               LumixCamera (S5II logic), CameraService protocol, LUMIX USB service, mock camera
  Storage/     SessionStore (on-disk queue), Keychain
  Networking/  APIClient, UploadQueue
  Services/    BoothController (guest flow state machine), QR codes
  Models/      AppSettings, LocalSession
  Views/       stage (welcome/countdown), review, share/email, settings, diagnostics, upload queue
ios/PhotoBoothTests/   protocol parsers (real S5II samples), capture algorithm (fake camera),
                       storage, uploads (fake server), booth flow (mock camera)
```

Tests: `xcodebuild test -project ios/PhotoBooth.xcodeproj -scheme PhotoBooth -destination 'platform=iOS Simulator,name=iPhone 17'`
(or ⌘U in Xcode).

**Camera.** The app uses the documented S5II PTP-over-USB protocol through ImageCaptureCore
(`requestSendPTPCommand`, `ptpEventHandler`): session setup (0x9102, capture target "PC", JPEG FINE, drive-dial
and focus-mode checks), liveview polling (0x9412/0x9706), one-shot AF with the result from C101 status dumps
(0x9405/0x9401), release (0x9404) with the documented GeneralError retry, object retrieval on C109/C108
(GetObjectInfo/GetObject), SDRAM queue draining, and automatic reconnection after cable pulls or power cycles.
No undocumented commands are used. Settings the app changes are restored when the camera is disconnected
from the app. The mock camera produces a moving liveview and 3000 × 2000 JPEGs (with optional simulated
failures, and optionally Wi-Fi-style delivery after the session).

**Camera over Wi-Fi** (*LUMIX S5II over Wi-Fi*): the camera joins the same network in *Remote Shooting & View →
Via Network*; the app finds it with a subnet scan (no IP entry), pairs (silently once the camera remembers the
app; refusals are never retried), switches it to shooting mode and shows its 30 fps UDP live view. Each photo is
taken with `camcmd capture` (~2 s until it is on the card); after the session's last shot the booth shows
"Bringing your photos over…", switches the camera to playback, finds the newest photos through the camera's DLNA
ContentDirectory and downloads the full-resolution originals (~3.5 s per 9 MB photo), then returns it to
shooting mode. With *Show quick previews first* (on by default) the booth first fetches the camera's own
1620×1080 previews (~1 s for three), so guests see their real photos about 4 s after the last shot, and the
originals finish in the background (~7 s) while they look at the review and QR screens; the next guest can start
once those are saved. Any `err_busy` or unexpected timeout stops all camera traffic until the operator checks the
camera and taps *Reconnect* — two research probes locked the camera before these rules existed. The recipe and
every measurement are in [docs/lan-research-log.md](docs/lan-research-log.md); it was verified end to end on the
S5II with the app's own Swift code (compiled into a macOS harness), not yet inside the iOS app on a device.

**Guest experience.** Fullscreen kiosk UI with large touch targets, optional mirrored preview (saved photos are
never mirrored), framing guides, animated countdown, flash, per-shot thumbnails, review with retake,
QR code + upload status, optional email, automatic return to the welcome screen. The camera stays in its
native 3:2 landscape orientation while the device can be in any orientation; layouts adapt to iPhone and iPad.
Friendly guest messages; technical details only in *Camera diagnostics* and *Upload queue*.

**Reliability.** Photos are saved (atomic write, never overwrite) before upload; sessions survive restarts
(interrupted captures are kept and uploaded with the photos they have); uploads run in the background, oldest
first, with exponential backoff and immediate retry when the network returns; a session is only marked
synchronized after the server's checksums match the device's copies. Local photos are deleted only per the
retention setting and only after verified sync, and are always accessible in the Files app.

**Operator settings** (gear on the welcome screen, or hold the top-left corner 1.5 s / tap it 5 times; then the PIN, default `0000` — change it). The gear can be hidden in settings once the booth is set up:

| Section | Settings |
|---|---|
| Server endpoint | server URL (cleaned up and validated, e.g. `192.168.1.20:8080` → `http://192.168.1.20:8080`), API key (Keychain), save & test connection, shows the public URL used in QR codes |
| Event | event name and identifier, default strip design |
| Photos & timing | photos per session (1–8), countdown before the first photo, countdown between photos, how long each photo is shown after capture (0 = off), estimated session length |
| Review & sharing | allow retake, retakes per session (0 = unlimited), review auto-continue, offer email, return-to-start timeout |
| Look & sound | welcome message, mirrored preview, framing guides, fill screen, countdown beeps/shutter sound, flash effect |
| Camera | mock / LUMIX USB, capture target, JPEG FINE, autofocus, liveview size, simulated failures (mock), diagnostics with test capture |
| Uploads & storage | upload queue, retry, local retention |
| Security & kiosk | operator PIN, Guided Access status |

## Photo strip designs

Folder-based templates (`design.json` + PNG background/foreground/preview); dropping a folder in `designs/`
registers it — no code changes. Supports 2×6 strips, 9:16 stories, squares, printable 4×6 and any canvas size,
with cover/contain fitting, rounded corners, rotation, transparent foreground overlays and text with
`{eventName}`/`{date}`/`{time}`. Six examples are included. Full reference and a Photoshop/Affinity/Canva
workflow: [docs/designs.md](docs/designs.md).

```bash
cd server
npm run designs -- validate
npm run designs -- preview story-polaroid --photos a.jpg b.jpg c.jpg --full
```

## Tests

| Suite | Covers |
|---|---|
| `server/test/sessions.test.ts` | session lifecycle, auth, validation, public visibility |
| `server/test/uploads.test.ts` | duplicates, conflicts (no overwrite), corrupted transfers, size/type limits, interrupted uploads across restarts, crash orphans, concurrency, path traversal |
| `server/test/designs.test.ts` | design validation messages, registry reload, layered rendering, previews |
| `server/test/downloads.test.ts` | byte-identical originals, thumbnails, strips per design, ZIP contents |
| `server/test/email.test.ts` | queue before completion, retries/backoff, permanent failures, limits, restart, SMTP disabled |
| `server/test/gallery.test.ts` | event gallery modes and passwords, admin auth, deletion, privacy, headers |
| `server/test/config.test.ts` | configuration defaults and validation |
| `ios/PhotoBoothTests/*` | PTP/Panasonic parsing, capture algorithm, session store persistence, upload queue recovery, booth flow with the mock camera (compiled, not yet run) |

## License

See [LICENSE](LICENSE).
