# LUMIX Tether 2.12 USB traffic (Phase 2)

Reference: LUMIX Tether **2.12 (2.12.0.5)**, Windows 11, DC-S5M2 fw 3.6, USB 2.0 HS.
Capture: USBPcap 1.5.4.0, camera device only (`scripts/capture_usb.ps1`), decoded
with `scripts/analyze_pcap.py` (tshark, usb-ptp dissector disabled, own container
reassembly). Each recording isolates one user action.

| File | Action | Transactions / events |
|---|---|---|
| `00_validate_own` | **our** implementation (pipeline validation) | 49 / 16 |
| `01_failed_bigsnaplen_no_bulk` | failed: `-s 16 MiB -b 64 MiB` recorded no bulk data | – |
| `01_tether_connect_idle` | start Tether, connect, idle ~55 s | 100 / 4 |
| `02_tether_liveview_af` | AF/AE button, LV on, touch-AF clicks ×5, LV off/on/off | 438 / 4 |
| `03_tether_capture` | **shutter pressed on the camera body**, Tether downloads | 97 / 32 |
| `04_tether_app_shutter_iso` | shutter from the app, ISO Auto→400→Auto | 108 / 31 |
| `05_tether_exit` | close Tether | 1 / 1 |

Every recording has `.pcap` (raw), `.txt` (one line per transaction) and `.jsonl`.
Default USBPcap snaplen (65 535) truncates large bulk URBs; the analyzer zero-pads
them, so framing, opcodes, parameters, sizes and response codes are exact while
bulk payloads beyond 64 KiB per URB are not preserved.

## Headline results

1. **Tether uses only ordinary PTP transactions through the stock Microsoft MTP
   driver** (the camera stayed bound to `WUDFWpdMtp` with Tether running). No
   vendor control transfers, no extra interfaces, no authentication, no custom
   driver. Same transport model as ours and as ImageCaptureCore.
2. **No keepalive / polling.** Between actions Tether is silent; it only reacts to
   events (`0x4006`, `C101`, `C102`, `C104`, `C107`, `C108`, `C109`).
3. **Live view = back-to-back `0x9706` polling**, 29.2–29.8 fps, same frame
   container as ours (TLV tags 0x17000000–05, JPEG at offset 244). Tether selects
   **960×720** with `0x9415`.
4. **Shutter = `0x9404(0x03000011)`** exactly like ours; no explicit AF before it.
5. **Object retrieval**: on `C109(0x12345678)` → `0x9110` (ObjectInfo with u64 size)
   → `0x1009` GetObject for the JPEG; RAW via `0x101B` GetPartialObject in 30 MiB
   chunks. Tether drains every queued object (FIFO confirmed).
6. **Settings writes** (`0x9403`) byte-identical to ours.

## Connect handshake (01, condensed; tid = transaction id)

```
 5.19  EVENT C104 [0x08000010]
 5.72  0x9102 [0x00010001]              OK rparam 0x00010001
 5.73  0x940A [0x08000070]   in 41 B    0x08000073 = "S5M2-E86421" (camera name)
 5.73  0x9103 []                        OK      <- closed again, no parameter
 9.66  0x1001 GetDeviceInfo  in 233 B
 9.67  0x9104 [0x00000001]   in 40 B    01000100 0100 e607 1c00 ... (ext device id / versions)
 9.67  0x9107/0x9108 [0x020000B0]       metering descriptor
 9.67  0x940A [0x08000050]   in 10 B    0x08000052 = 1
 9.68  0x9414 [0x12000010]              recording status
 9.69  0x9107/0x9108 [0x08000050]
 9.69  0x9417 [0x0E000021]   in 10 B    0x0E000021 = 0        <- opcode not in libgphoto2
 9.69  0x940B [0]  out 91000008 02000000 0200   capture target = 2 (SD + PC)
 9.71  0x9102 [0x00010001]              vendor session for real
 9.73… 0x9402 / 0x9107 / 0x9108 for groups 0x02000010–0x020001F0, 0x06000010/30,
       0x08000010/90; 0x9408 [0x06000010/19/30] (movie config);
       0x940A [0x08000010] (82 B, clock 2026-11-25 21:52:18 at bytes 8..)
 9.93  0x9414 [0x12000010], [0x120100A0], [0x16000010], [0x12000070]
 9.94  0x9401 [0x01000010]  (status dump, without a preceding C101)
 9.95  0x940B [0]  out ... 0200         capture target = 2 again
       --- idle: only event-driven reads ---
46.38  EVENT 0x4006 [0x5001] (standard DevicePropChanged: battery) ; C107 [0x16000010]
46.42  0x9414 [0x16000010]  -> battery 40 %
65.24  EVENT C104 [0x08000010] -> 0x940A [0x08000010], 0x9107/0x9108 [0x08000010]
```
`0x9107` (same 3 params as `0x9108`) returns only the descriptor header with the
value list truncated — Tether calls it first to size the `0x9108` read.

## Live view and AF (02)

```
 7.71  0x9404 [0x03000018]          Tether "AF/AE" button  -> C101s, AF state FFFE->0000
12.22  0x9414 [0x12000010]
12.22  0x9412 [0x0D000010]          liveview start
12.23  0x9414 [0x0D800012] / [0x0D800011]
12.47  0x9415 [0x0D800011] out 1100800d 08000000 d002 c003 fa00 1e00   (720x960, 250, 30)
       0x9706 x278 in 9.5 s (29.2 fps), frames 160-187 KB, all OK
13.74  0x9416 [0x030000A1] out a1000003 04000000 1501 d000  (x=277, y=208) -> InvalidParameter
13.75  0x9416 [0x030000A2] out a2000003 04000000 1501 d000                  -> InvalidParameter
13.78  0x9416 [0x030000A4] out a4000003 00000000                            -> OK
       (5 clicks; coordinates 232..767 x 208..791 → 0..1000 normalised, INFERRED)
21.96  0x9412 [0x0D000011]          liveview stop
```
Touch-AF was rejected because the AF area mode was face/eye detection (shown in
Tether). Retest with 1-area AF to confirm A1/A2 semantics (PENDING).

## Capture from the camera body (03) — target 2 (SD + PC), RAW+FINE

```
 8.26–14.5  C107 [0x12000020] -> Tether re-reads 0x9402 aperture/shutter + 0x9414 [0x12000020]
            C101 -> 0x9401 (AF state FFFE -> 0000 -> FFFF)
14.63  EVENT C109 [0x12345678]                         JPEG in camera RAM
14.65  0x9110 [0x12345678] x3 in 154 B                 ObjectInfo (u64 size 13 059 072, P1542443.JPG)
14.66  0x9414 [0x12000015]  in 14 B ; 0x940A [0x08000090] (target = 2)
14.73  0x1009 [0x12345678]  in 13 059 072 B  465 ms     JPEG
15.20  EVENT C109 [0x12345678]                         RAW queued behind it
15.22  0x9110 x3 ... size 38 635 520
15.32  0x101B [0x12345678, 0, 0x01E00000]   in 31 457 280 B  793 ms
16.15  0x101B [0x12345678, 0x01E00000, 0x006D8800] in 7 178 240 B 186 ms
16.95  EVENT C108 [0x51268000] (folder), C108 [0x5226898B] (JPG), C108 [0x5926898B] (RW2)
       -> 0x9110 on each, no download (already received from RAM)
```

## Capture from the app + ISO (04)

```
21.37  0x9404 [0x03000011]            release (no AF command first; AF-S focuses itself)
21.39… C101/C107 ...
22.31  EVENT C109 [0x12345678]        +0.94 s after release
22.54  0x1009 -> 11 601 920 B in 382 ms   => shot→JPEG on host ≈ 1.55 s
22.93  EVENT C109 (RAW) -> 0x101B 30 MiB + 5.79 MB
24.32  C108 JPG / RW2 on the card
36.65  0x9403 [0x02000021] out 21000002 04000000 90010000   ISO 400 -> OK
       C102 [0x02000010], [0x02000021], [0x02000060]; C107 [0x12000020]
41.60  0x9403 [0x02000021] out 21000002 04000000 ffffffff   ISO Auto -> OK
55.17  EVENT C104 [0x08000010], C104 [0x15C00010] -> 0x9414 [0x15C00010] in 154 B (UNKNOWN)
```

## Exit (05)

```
6.78  0x9103 []   OK          (no parameter; nothing else — target not written back)
```
Afterwards our session read capture target **0** again, i.e. the camera reset it
when Tether's session ended (INFERRED: parameterless 0x9103 or PTP session end).

## Differences between Tether and our implementation

| Topic | Tether 2.12 | Ours | Action |
|---|---|---|---|
| AF | `0x9404(0x03000018)` | `0x9405(0x03000024)` | both verified; added `autofocus_halfpress()` |
| ObjectInfo | `0x9110` (u64 size) | `0x1008` | both verified; added `object_info_ext()` + parser |
| RAW download | `0x101B` 30 MiB chunks | `0x1009` whole | both work |
| Capture target | 2 (SD + PC) | 1 (PC) for booth | both verified |
| Liveview size | 960×720 | 640×480 default | all three sizes 30 fps |
| Session | `0x9102` twice, `0x9103` without param | `0x9102`/`0x9103` with 0x00010001 | both OK |
| C101 ack | `0x9401` per C101, plus once at connect | same | — |

## Opcodes seen only in Tether traffic (TETHER, not yet exercised by us)
`0x9104(1)` ext device info, `0x9107` descriptor size, `0x9408(0x060000xx)` movie
config read, `0x9416(0x030000A1/A2/A4)` touch AF/AE, `0x9417(0x0E000021)`,
`0x940A(0x08000010/50/70)`, `0x9414(0x12000015/0x12000070/0x120100A0/0x15C00010)`.
