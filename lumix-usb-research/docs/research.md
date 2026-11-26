# Research log

## Phase 1 — existing implementations (2026-11-25)

| Source | Revision | What it gave us |
|---|---|---|
| libgphoto2 `camlibs/ptp2` (ptp.h, ptp.c, library.c, config.c) | `6d5c61e` (2026-11-22) | Panasonic opcode table 0x9101–0x9707, property codes, capture flow (`camera_panasonic_capture`), C101→0x9401 ack "following LUMIXTether", C108/C109, capture target 0x940A/B, liveview 0x9412/0x9706, 0x9414/0x9415 liveview parameter structs, shutter/ISO/WB encodings. Treats 04DA:2382 specially and *adds* vendor ops to the advertised list. Also sets MTP SessionInitiatorInfo for Panasonic when VendorExtensionID is Microsoft (older models). |
| tethr (baku89) `core/src/TethrPTPUSB/TethrPanasonic.ts` | `b49536d` (2026-11-06) | WebUSB implementation tested on DC-S9 fw 1.9 (same generation, same PID): OpenSession 0x9102 p=0x00010001, AF = `0x9405(0x03000024)`, liveview TLV tags 0x17000001–05, quality/aspect/photo-style/mode tables, "InvalidParameter → retry", "GeneralError on release → retry after 1 s", S9 storage enumeration fails 0x2008, and a "response held back until the next command" quirk (~1/30 transactions, worked around with a nudge command). |
| liblumix (njfdev) | `c5a9a50` (2024-06-08) | **Wi-Fi only** (HTTP `cam.cgi` API from Lumix Sync), S5IIX. Author abandoned USB because of image download problems. Not used for the USB protocol. |
| Panasonic LUMIX SDK (`LumixRemoteControlLibraryBeta1.00`, 2020-10-14) | not downloaded | Official Windows-only USB SDK; lists DC-S5M2. Download gated behind a license agreement and the camera serial number. Could confirm property codes, but its licence terms are unknown — not used. |
| Wireshark 4.6.8 `usb-ptp` dissector | installed | Knows Panasonic VID, generic PTP decoding; vendor opcodes shown as raw codes. Useful for Phase 2 capture. |

### Leads from the task brief vs. findings
| Opcode | Brief | Result on S5II |
|---|---|---|
| 0x9404 | shutter release | **VERIFIED** with p1=0x03000011 |
| 0x9405 | focus control | Accepted with p1=0x03000024 (MF: no-op); AF-S PENDING |
| 0x9412 | live view control | **VERIFIED** p1=0x0D000010/11 |
| 0x9706 | live view frame | **VERIFIED**, TLV+JPEG, 30 fps |
| 0x940A | get capture target | **VERIFIED** p1=0x08000090 |
| 0x940B | set capture target | **VERIFIED** 0=SD, 1=PC |

### Conclusion of Phase 1
Panasonic uses standard PTP-over-USB with vendor operations/events; no separate
USB interface. That was then confirmed on the device (usb-transport.md).

## Phase 2 — USB traffic of LUMIX Tether (DONE, 2026-11-25)

USBPcap 1.5.4.0 (winget, user-approved; reboot required before its filter
attached) + LUMIX Tether 2.12 (2.12.0.5). Five isolated recordings of the camera
device only (keyboard/mouse/audio on the same hub excluded), plus one validation
recording of our own implementation that decoded 1:1 against our JSONL log.
Full results: **[tether-traffic.md](tether-traffic.md)**.

Summary: Tether uses only PTP transactions through the stock MTP driver; no
keepalive; liveview = `0x9706` polling at ~30 fps; shutter `0x9404(0x03000011)`;
objects via `C109`/`C108` → `0x9110` → `0x1009`/`0x101B`; settings via `0x9403` —
all matching our implementation. New: `0x9404(0x03000018)` AF, `0x9110`
ObjectInfo (u64 size), `0x9107`, `0x9416` touch AF, `0x9417`, capture target 2.

Failed experiment: USBPcap with `-s 16777216 -b 67108864` captured only interrupt
packets (no bulk); default options work.

## Phase 3 — independent implementation (DONE for core path)

See README for the CLI. Experiments in chronological order are in
`experiments.md`; raw per-transaction logs in `captures/direct/*.jsonl`.
