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

## Phase 2 — USB traffic of LUMIX Tether (PENDING)

Status: **USBPcap 1.5.4.0 installed** (2026-11-25, `winget install desowin.USBPcap`,
approved by the user). Its filter driver is not active until a reboot
(`USBPcapCMD --extcap-interfaces` lists nothing, service stopped). It is a
capture filter on the USB root hubs and does not replace the camera's MTP driver.
LUMIX Tether **2.12 (2.12.0.5)** installed by the user (2026-11-25, `C:Program FilesPanasonicumix tether`); this is the reference implementation for all tether-tagged items. planned
isolated captures, one file each, in `captures/tether/`:

1. connect (Tether start → camera recognized)
2. idle 30 s (background polling)
3. liveview on, 5 s, off
4. AF (half-press / AF button in Tether)
5. single capture with "save to PC"
6. change ISO once
7. disconnect (Tether exit)

Each will be dissected with `scripts/` tooling into opcode/param/data tables
and compared to our implementation. Until then, nothing in the docs is tagged
TETHER.

## Phase 3 — independent implementation (DONE for core path)

See README for the CLI. Experiments in chronological order are in
`experiments.md`; raw per-transaction logs in `captures/direct/*.jsonl`.
