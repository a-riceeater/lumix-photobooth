# Still capture

**VERIFIED** on DC-S5M2 fw 3.6 (M mode, focus lever MF, quality RAW+FINE unless noted).

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

## Timing (release → object event)

| Target | Quality | Release→object | Download |
|---|---|---|---|
| SD | RAW+FINE | 4.55 s, 4.59 s | 0.52 s (JPEG) |
| PC | RAW+FINE | 2.54 s (JPEG first) | JPEG 0.30 s, RW2 (35.7 MB) 1.06 s |
| PC | FINE only | 2.61 s, 2.63 s | 0.30 s, 0.33 s |

With PC + FINE, a shot → JPEG on the host takes ≈ **2.9 s** at USB 2.0 speed.
Most of that is in-camera processing (shutter 1/160 s); faster with smaller JPEG
size or quality "standard" is untested.

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
shot:  drain old events
       (optional) 0x9405(0x03000024) AF, wait for focus (PENDING: AF-S test)
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

* AF-S behaviour: does `0x9404` refuse when focus fails? (tethr: silently no image)
* Behaviour with no SD card inserted (both targets).
* Burst/drive modes; `0x9113` skip; target BOTH (2).
