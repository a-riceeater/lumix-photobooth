# Still capture

**VERIFIED** on DC-S5M2 fw 3.6 (M mode, 1/160 s, quality RAW+FINE unless noted).

> **Correction:** the first measurements (experiments 9–14, 21) were taken with the
> drive dial on the **2 s self-timer** (`0x02000081` = 3). They are kept below for
> reference; the single-shot numbers (dial on single, `0x02000081` = 0) supersede
> them. The drive dial is physical and read-only over USB — the host should read
> it and warn if it is not single.

## Answers

| Question | Answer |
|---|---|
| Sequence to release | `0x9404(0x03000011)` alone. Returns OK in ~15 ms; capture is asynchronous. |
| How to detect success | Wait for event **0xC108** (target SD) or **0xC109** (target PC) carrying the object handle. |
| Identify the new image | Event param1 = handle → `GetObjectInfo` → filename/format/size. SD handles: `0x52xxxxxx` JPG, `0x59xxxxxx` RW2 (same low bits per shot). PC handle: always `0x12345678`. |
| Direct transfer to host? | **Yes**: capture target PC (`0x940B` value 1). File named `CARDLESS.JPG`/`CARDLESS.RW2`. |
| SD card required? | Not tested with the card removed. In target PC the camera did not create a card file (name `CARDLESS.*`); INFERRED: no card needed. **PENDING**: test without card. |
| Configurable destination? | Yes: SD (0), PC (1), both (2, SOURCE only). |
| Full-res JPEG transfer speed | 9.9 MB in 0.28–0.33 s = **31–35 MB/s** (PC target); 19 MB/s for first SD read. Link is USB 2.0 High-Speed — see usb-transport.md. |
| Liveview restart after capture? | **No.** Liveview keeps running through capture (≈300 ms blackout). |
| Needs 0x9102? | No (verified one SD shot without it). |
| Needs C101 ack? | No (first capture completed unacknowledged); we ack anyway like LUMIX Tether. |

## Timing, drive mode SINGLE (release → object event)

| Target | Focus | Quality | Release→object | Download | Log |
|---|---|---|---|---|---|
| SD | AF-S, no prior AF | RAW+FINE | 3.16 s | – | capture_1795665206 |
| SD | AF-S after AF lock | RAW+FINE | 2.77 s | – | capture_1795665210 |
| PC | AF-S, no prior AF, LV on | FINE | 1.12, 1.24, 1.25 s | 0.32–0.36 s (10.7–11.3 MB) | test_booth_sequence_1795665215 |
| PC | AF-S after `autofocus_wait` (1.38–1.67 s), LV on | FINE | 0.85, 1.11, 1.11 s | 0.30–0.35 s | test_af_capture_1795665275 |
| PC | **AF-C after corrected `autofocus_wait` (in focus 0.23–0.34 s)**, LV on | FINE | 0.55, 0.58, 0.59 s | 0.29–0.32 s | test_af_modes (2nd AFC run) |
| PC | AF-C, release only, LV on | FINE | 0.78–0.81 s (two runs) | 0.29–0.35 s | test_af_modes (both AFC runs) |
| (superseded) | AF-C, old wait for 0xFFFF (1.25–1.36 s) | FINE | 0.55–0.98 s | 0.31–0.35 s | test_af_modes (1st AFC run) |
| PC | **AF-S after corrected `autofocus_wait` (in focus 0.45–0.53 s)**, LV on | FINE | 0.72, 0.76, 0.76 s | 0.26–0.27 s | test_af_modes (AFS run) |
| PC | AF-S, release only, LV on | FINE | 1.01–1.03 s | 0.27–0.29 s | test_af_modes (AFS run) |

AF-S totals: AF + release + download **1.44–1.56 s**; release-only 1.28–1.32 s.
AF-C is ≈0.3–0.4 s faster end to end on the same scene.

**Booth figure (AF-C): AF command → JPEG bytes on host ≈ 1.1–1.2 s**
(AF 0.23–0.34 s + release→object ≈0.57 s + download ≈0.3 s), USB 2.0, LV running.

AF-C release-only is equally fast (≈1.1 s total) because the release performs its
own AF: its object arrives ≈0.25 s later than after an explicit AF, matching the
AF time. Static-scene sharpness of release-only shots was not worse (edge-energy
metric on a 1000 px centre crop: AF+release 23.3–24.8, release-only 28.4–30.9;
scene-dependent, not a precise focus measure). With the lens covered the release
was refused in AF-C, so the S5II does **not** release without focus here. An
explicit AF step is still preferable: it reports failure (0x0004) in ~1 s
instead of a silent missing image.

Booth figure: **AF ≈1.5 s + release→JPEG ≈1.0 s + download ≈0.33 s ≈ 2.8–3.1 s**
from "start" to JPEG bytes on the host, USB 2.0 link, liveview running.
Without a separate AF step, the release performs its own AF (AF-S) and the
JPEG arrives ≈1.2 s after release.

### Superseded (2 s self-timer was active)
| Target | Quality | Release→object | Download |
|---|---|---|---|
| SD | RAW+FINE | 4.55 s, 4.59 s | 0.52 s (JPEG) |
| PC | RAW+FINE | 2.54 s (JPEG first) | JPEG 0.30 s, RW2 (35.7 MB) 1.06 s |
| PC | FINE only | 2.61 s, 2.63 s | 0.30 s, 0.33 s |

Download rates and SDRAM queue semantics from those runs are unaffected.

## Event sequence (SD, from `captures/direct/capture_1795664195.jsonl`)

```
+0.000  0x9404(0x03000011) -> OK
+0.006  C101 [0x01000010]          -> host 0x9401(0x01000010), 4936 B status
+0.10   C107 [0x12000010], C107 [0x12000020]
+0.12   C101 [0x01000010]          -> ack
 ...    C107 [0x12000010] repeats
+4.55   C108 [0x52268985]          JPG  -> GetObjectInfo / GetObject
        C108 [0x59268985]          RW2
        C107 [0x12000010]          remaining-shots updated
```
The very first shot of the session also produced `C108 [0x51268000]` (before the
JPG/RW2) and `C104 [0x08000010]` — probably the new folder (`154_PANA`) and a
storage config notification (INFERRED; format code not read).

## PC/"SDRAM" queue semantics (`scripts/test_sdram_queue.py`)

* All objects share handle `0x12345678`; it is a **FIFO**.
* After the JPEG of shot A is downloaded, the same handle now presents A's RW2.
* Shot B released while A's RW2 was still pending → **no C109 for B** until A's
  RW2 was downloaded. Drain order observed: A.RW2, B.JPG, B.RW2, then
  `GetObjectInfo` → `InvalidParameter` (queue empty).
* Rule: **download (or skip) every queued object**. For a booth set quality to a
  JPEG-only mode so each shot yields exactly one object. `0x9113` "skip object
  transfer" (SOURCE) might discard instead of downloading — untested.

## Recommended booth capture algorithm

```
once:  0x940B target=PC ; 0x9403 quality=FINE (0x020000A2 = 0)  [read back]
       0x9412 liveview start
check: 0x9402(0x02000080): drive 0x02000081 == 0 (single); AF mode 0x02000071 (lever)
shot:  drain old events
       (optional) 0x9405(0x03000024) AF; wait for a fresh C101 status dump with
                  0x01000011 = 0x0000 in focus / 0x0004 failed (Camera.autofocus_wait)
                  failed -> 0x9405(0x03000025) clear, tell the guest, do NOT release
       0x9404(0x03000011)
         GeneralError -> wait 1 s, retry once
       wait <=15 s (+ shutter time) for C109/C108
       sleep 50 ms (libgphoto2: object not readable immediately)
       0x1008 GetObjectInfo(handle); skip format 0x3001 (folder)
       0x1009 GetObject(handle)  -> JPEG
       if target PC and other objects announced: drain them too
end:   restore target / quality, 0x9412 stop, 0x9103
```
Implemented as `Camera.capture()` + `Camera.download()` in `src/lumix_usb/panasonic.py`.

## Open items

* AF failure (VERIFIED, AF-C, lens covered): 0x01000011 = 0x0004 after ~1 s;
  0x9404 then returns OK but **no object and no event** arrives (2 shots after
  failed AF, 2 release-only). The same happens release-only, so a booth must
  time out (we use 10–15 s) or check the AF result first.
* The AF timings in the tables above that used `autofocus_wait` waited for
  0xFFFF (result *ended*), ~1 s later than focus was actually achieved (0x0000).
  Re-measured for AF-C and AF-S (above). The older AF-S rows that used the
  0xFFFF wait are superseded.
* Behaviour with no SD card inserted (both targets).
* Burst/drive modes; `0x9113` skip; target BOTH (2).
