# LUMIX S5II USB protocol research

Independent, documented USB control of a **Panasonic LUMIX DC-S5M2 (S5II)** — live
view, autofocus, shutter release and automatic full-resolution JPEG retrieval —
as groundwork for a future native iPadOS photo booth (ImageCaptureCore). No app,
UI or Swift code lives here.

## Status (2026-11-25, camera fw 3.6, Windows 11)

| Function | Status |
|---|---|
| USB discovery / identification | VERIFIED (04DA:2382, PTP class, 3 endpoints) |
| Session open/close (driver + 0x9102/0x9103) | VERIFIED |
| Live view start/stop/frames | VERIFIED — 30 fps at 640×432, 960×640, 1280×856 |
| Autofocus 0x9405 | VERIFIED (AF-S, AF-C); result via C101 status dump: in focus 0.23–0.6 s, failure (0x0004) ~1 s |
| Shutter 0x9404 | VERIFIED |
| Capture-complete detection | VERIFIED (events C108 SD / C109 PC) |
| Full-res JPEG retrieval | VERIFIED — ~10.6 MB in ~0.3 s; AF-C: AF command → JPEG on host ≈1.1–1.2 s (PC target, JPEG FINE) |
| Read/modify settings | VERIFIED (ISO, quality, capture target, liveview size) |
| Recovery / reconnect | Implemented; physical unplug test PENDING |
| LUMIX Tether USB traffic comparison | PENDING (USBPcap + Tether not installed) |

Key result: everything runs through the **stock Windows MTP driver** using the
WPD MTP vendor-extension API — no driver replacement, no extra USB interfaces,
no authentication. This is the same "opcode + params + data" abstraction as
ImageCaptureCore `requestSendPTPCommand`.

## Quick start
```
cd lumix-usb-research
py -3.12 -m venv .venv && .venv\Scripts\pip install -e . pytest pyusb libusb-package
.venv\Scripts\python -m lumix_usb detect
.venv\Scripts\python -m lumix_usb device-info
.venv\Scripts\python -m lumix_usb connect
.venv\Scripts\python -m lumix_usb status
.venv\Scripts\python -m lumix_usb liveview-frame --count 90 --save 3
.venv\Scripts\python -m lumix_usb liveview-view          # window: f=AF, space=capture, q=quit
.venv\Scripts\python -m lumix_usb autofocus --liveview
.venv\Scripts\python -m lumix_usb capture --download             # target unchanged (SD)
.venv\Scripts\python -m lumix_usb capture --target pc --restore-target 0 --download
.venv\Scripts\python -m lumix_usb get-settings [iso shutter ...] [--raw]
.venv\Scripts\python -m lumix_usb get-desc iso --size 4
.venv\Scripts\python -m lumix_usb set-setting iso_param 400 --size 4
.venv\Scripts\python -m lumix_usb events --seconds 30
.venv\Scripts\python -m pytest tests
```
Camera: USB mode **PC(Tether)**. Every run writes a per-transaction JSONL log to
`captures/direct/`. Photos go to `samples/photos/` (git-ignored).

## Layout
```
src/lumix_usb/ptp.py            PTP codes + dataset parsers (portable)
src/lumix_usb/panasonic.py      Panasonic protocol: opcodes, TLV, liveview, capture (portable)
src/lumix_usb/transport/base.py transport contract (mirrors ICC requestSendPTPCommand)
src/lumix_usb/transport/wpd.py  Windows WPD implementation
src/lumix_usb/recovery.py       reconnect policy
src/lumix_usb/cli.py, viewer.py test harness
scripts/                        probes and experiments (each documented in docs/experiments.md)
captures/                       raw logs and USB descriptor dumps
samples/                        DeviceInfo, liveview payloads/frames, status blobs
docs/                           protocol documentation (start with command-reference.md)
```

## Docs
[research](docs/research.md) · [usb-transport](docs/usb-transport.md) ·
[ptp-protocol](docs/ptp-protocol.md) · [initialization](docs/initialization.md) ·
[live-view](docs/live-view.md) · [capture](docs/capture.md) ·
[file-transfer](docs/file-transfer.md) · [camera-settings](docs/camera-settings.md) ·
[command-reference](docs/command-reference.md) · [troubleshooting](docs/troubleshooting.md) ·
[ipados-compatibility](docs/ipados-compatibility.md) · [experiments](docs/experiments.md)

## Safety rules followed
No firmware, format, power, delete or USB-mode commands; no driver changes;
every setting changed by a test is restored.
