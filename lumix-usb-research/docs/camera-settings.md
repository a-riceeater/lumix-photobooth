# Camera settings

Panasonic does not use standard PTP DeviceProps (DeviceInfo advertises only
`0x5001` BatteryLevel). Settings are 32-bit property codes read with **0x9402**
(group → TLV of members), enumerated with **0x9108**, written with **0x9403**
(`u32 code, u32 size, value`) on the `*_Param` member. Status/readouts that are
not settings use **0x9414**. Change notifications: event **C102** (p1 = group).

## Values read from the connected S5II (`lumix_usb get-settings`, VERIFIED)

| Name | Group | Members (code=value) | Interpretation |
|---|---|---|---|
| ISO | 0x02000020 | 21=0xFFFFFFFF, 22=51200, 25=0xFFFF | ISO auto, auto upper limit 51200 |
| Shutter | 0x02000030 | 31=160000, 32=(8 B range), 34=18000 | 1/160 s |
| Aperture | 0x02000040 | 41=37, 42=(range 0x00DC0023) | f/3.7 (value/10); range INFERRED f/3.5–f/22 |
| White balance | 0x02000050 | 51=2, 52=5500, 53=0, 54=0, 55=0 | Auto; K-set 5500 K; A-B/G-M 0 |
| Exposure comp | 0x02000060 | 61=0, 62=(range) | 0 EV |
| AF | 0x02000070 | 71=3, 72=17, 73..78 | AF mode 3 = **MF** (lever); 72 = AF area mode (17, UNKNOWN mapping) |
| Camera mode | 0x02000080 | 81=3→0, 82=3, 83=22, 84=0, 85=2, 86=1, 87=0 | ModePos 3 = **M**; drive mode 81: 3 = 2 s self-timer, 0 = single (VERIFIED with the user turning the dial) |
| Image mode | 0x020000A0 | A1=8198, A2=4, A3=2 | quality 4 = RAW+FINE, aspect 2 = 3:2; A1 = size (UNKNOWN) |
| Metering | 0x020000B0 | B1=1, B2=0, B3=3, B8=0 | UNKNOWN mapping |
| Photo style | 0x02000010 | 11..1F | 11 = 0 (Standard) |

## Writable vs read-only (from 0x9108 allowed-value count)

| Property | Allowed values on S5II | Writable |
|---|---|---|
| ISO (0x02000020, 4 B) | 0xFFFFFFFF(auto), 100,125,160,…,51200 (29 values) | yes — VERIFIED set 400 and back |
| Image quality (0x020000A2, 2 B) | 0,1,4,5,3 | yes — VERIFIED set 0 and back to 4 |
| AF mode (0x02000071, 2 B) | none | **no** (physical focus lever) |
| Mode dial (0x02000082, 2 B) | none | **no** (physical dial) |
| Drive mode (0x02000081, 2 B) | none | **no** (physical drive dial) |

Quality table: on S5II the allowed set {0,1,3,4,5} matches tethr's DC-S9 table:
`0 FINE, 1 STANDARD, 3 RAW, 4 RAW+FINE, 5 RAW+STANDARD` (S5II mapping of 0 and 4
VERIFIED by capture results: 4 → JPG+RW2, 0 → JPG only).

## Encodings (SOURCE: libgphoto2 config.c, tethr; INFERRED for S5II unless noted)

| Property | Size | Encoding |
|---|---|---|
| ISO_Param 0x02000021 | 4 | ISO number; 0xFFFFFFFF auto; 0xFFFFFFFE i-ISO (S9) — VERIFIED (auto, 400) |
| ShutterSpeed_Param 0x02000031 | 4 | `1/x` s → x·1000 (1/160 → 160000, VERIFIED read); ≥1 s → (s·1000) \| 0x80000000; 0xFFFFFFFF bulb; 0x0FFFFFFF auto |
| Aperture_Param 0x02000041 | 2 | f-number ×10 (37 = f/3.7) — VERIFIED read |
| Exposure_Param 0x02000061 | 2 | thirds of a stop; bit 15 = negative |
| WhiteBalance_Param 0x02000051 | 2 | 2 auto, 4 daylight, 0x8008 cloudy, 6 tungsten, 5 fluorescent, 7 flash, 0x800F shade, 0x800B–E presets, 0x8010–13 K-set 1–4, 0x8014/15 auto cool/warm — VERIFIED read (2) |
| WhiteBalance_KSet 0x02000052 | 2 | Kelvin (5500 VERIFIED read) |
| PhotoStyle_Param 0x02000011 | 2 | 0 Standard, 1 Vivid, 2 Natural, 3 Mono, 4 Landscape, 5 Portrait, … (tethr table) |
| AFArea_AFModeParam 0x02000071 | 2 | 3 MF, 4 AF-S, 5 AF-C, 6 AF-F (tethr) — 3 (MF) and 4 (AFS) VERIFIED via the lever |
| CameraMode_ModePos 0x02000082 | 2 | 0 P, 1 A, 2 S, 3 M, 5 video, 7 iA, 8–10 C1–C3 (tethr) — 3 VERIFIED read |
| ImageMode_ImageAspect 0x020000A3 | 2 | 1 4:3, 2 3:2, 3 16:9, 4 1:1, 10 65:24, 11 2:1 — 2 VERIFIED (liveview 3:2) |

## Status readouts (0x9414, VERIFIED)
| Code | Meaning |
|---|---|
| 0x12000011 | remaining shots (2278) |
| 0x12000021 / 22 / 23 | live aperture (37), shutter (160000), meter (s32, −3) |
| 0x16000011 | battery: u32 %, u16 %, u16 0xFFFF (80 %) |

## Caveats
* SetProperty returned OK for an ISO not in the allowed list (12345). Validate
  against 0x9108 before writing and read back after.
* Transient InvalidParameter right after liveview stop; the setter helper retries
  up to 4× at 300 ms.
* Settings changed by the host are real camera settings and persist. Test scripts
  restore them.
