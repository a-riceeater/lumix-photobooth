# Experiment log (successes and failures)

Times are local 2026-11-25. Log files: `captures/direct/<name>_<unixtime>.jsonl`.

| # | Experiment | Result | Notes / log |
|---|---|---|---|
| 1 | WPD enumeration via comtypes | FAIL then OK | Typelib declares string buffers as `ushort*`; cast fixed it. |
| 2 | WPD Open + SendCommand | FAIL then OK | `PROPERTYKEY`/`IPortableDeviceValues` exist in both typelibs; must use Types-lib versions and QI results. |
| 3 | 0x1001 GetDeviceInfo via MTP-ext | OK | `samples/deviceinfo_wpd.bin` |
| 4 | 0x9402 (battery 0x16000010) before 0x9102 | GeneralError | Wrong opcode for that family (0x9414 is correct, exp. 16). |
| 5 | 0x9102 OpenSession | OK | `probe_vendor_session_1795663925` |
| 6 | 0x9402 ISO, 0x9414 LV settings, 0x940A target | OK | Unadvertised opcodes are forwarded by WPD. |
| 7 | Liveview 5 s | OK, 30.1 fps | `probe_liveview_1795663945`; frames in samples/. |
| 8 | 0x9402 before 0x9102 (ISO) | OK | 0x9102 not needed for property reads. |
| 9 | First capture (SD) | Release OK, **no event seen** | Event decoder bug: code is Data1>>16. Raw log showed C108 ×3 after 5.5 s. `capture_1795664158` |
| 10 | Capture SD with fixed decoder + auto-ack | OK, 4.55 s, 19 MB/s | `capture_1795664195` |
| 11 | list-objects | FAIL | InvalidStorageID / ParameterNotSupported in tether mode. |
| 12 | Capture target PC | OK, 2.54 s, 31.6 MB/s, handle 0x12345678 | `capture_1795664234` |
| 13 | Two shots PC, RAW+FINE, RAW left pending | Shot 2 blocked until queue drained | `test_sdram_queue_1795664255` |
| 14 | Booth sequence (LV thread + 2 shots PC FINE) | OK; LV 28 fps, ≤326 ms gaps | `test_booth_sequence_1795664303`. Restoring target failed (InvalidParameter right after LV stop) → fixed by retry; restored in `restore_1795664325`. |
| 15 | AF one-shot in MF | OK (no-op) | `autofocus_1795664346` |
| 16 | ISO set 400 / invalid 12345 / restore | OK / **OK (!)** / OK | `set_iso_roundtrip_1795664349` |
| 17 | 0x9414 status families | OK for 0x12000010/11/13/20, 0x16000010 | `probe_status_1795664408` |
| 18 | Liveview without 0x9102 | OK | `test_lv_sizes_1795664438` |
| 19 | 0x9415 immediately after LV stop | InvalidParameter | Transient; OK idle / during LV / 1 s after stop (`probe_9415_1795664450`). |
| 20 | LV sizes 640/960/1280 | all 30.1 fps | `test_lv_sizes_1795664460` |
| 21 | Capture without 0x9102 | OK | `capture_no_9102_1795664491` |
| — | **User note:** drive dial was on 2 s self-timer during 9–14 and 21 | timings re-measured | drive mode 0x02000081: 3 → 0 |
| 22 | AF-S one-shot ×3 with LV + lock clear | OK; status 0x01000011 FFFE→0000→FFFF→(clear)FFFE | `test_autofocus_1795665159` |
| 23 | SD capture, single drive | 3.16 s; with AF first 2.77 s | `capture_1795665206`, `_1795665210` |
| 24 | Booth sequence, single drive, 3 shots | release→JPEG 1.12–1.25 s, LV 27.4 fps, gaps ≤367 ms | `test_booth_sequence_1795665215` |
| 25 | `autofocus_wait` + capture PC FINE ×3 | AF 1.38–1.67 s, release→JPEG 0.85–1.11 s, total 2.8–3.1 s | `test_af_capture_1795665275` |
| 26 | Lever AFC: AF ×3 status trace; AF+release ×3; release-only ×3 (PC FINE) | AF ~1.4 s, totals 2.1–2.7 s; release-only 1.09–1.15 s total; lock clear leaves state 0xFFFF | `test_af_modes_*` (AFC run) |
| 27 | Lens covered, AFC: AF status trace, AF+release ×2, release-only ×2 | 0x01000011 = 0x0004 (new); no object/no event for all 4 releases | `test_af_failure_*` |
| 28 | Corrected `autofocus_wait` (stop on 0x0000/0x0004), lens covered ×3 | "failed" in 0.98–1.08 s. Re-interpretation: 0x0000 = in focus, 0xFFFF = result ended (rows 22/25/26 waited ~1 s too long) | `af_fail_detect_*` |
| 29 | Lens uncovered, AFC, corrected wait: AF+release ×3, release-only ×3, images saved | in focus 0.23–0.34 s; totals 1.11–1.21 s (AF) / 1.07–1.13 s (release-only); release-only not blurrier | `test_af_modes_*` (2nd AFC run) |
| 30 | Physical unplug ×3 during 120 s liveview with ResilientCamera | 3/3 auto-recovered; gaps 14.3 / 33.3 / 14.3 s; HRESULT 0x8007001F then 0x800701B1; no DEVICE_REMOVED event | `test_reconnect_1795666463` |
| 31 | Lever AFS, corrected wait: AF ×3 trace, AF+release ×3, release-only ×3 | in focus 0.45–0.63 s; totals 1.44–1.56 s (AF) / 1.28–1.32 s (release-only) | `test_af_modes_*` (AFS run) |
| 32 | `winget install desowin.USBPcap` (user-approved) | installed 1.5.4.0; filter inactive until reboot | – |

## Not attempted (by policy)
DeleteObject, 0x9406 (format/sensor clean/firmware), 0x940D (power), 0x9606/9607
(firmware upload), 0x9704 (USB mode), any driver replacement.
