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

## Not attempted (by policy)
DeleteObject, 0x9406 (format/sensor clean/firmware), 0x940D (power), 0x9606/9607
(firmware upload), 0x9704 (USB mode), any driver replacement.
