# Live view

All results below are **VERIFIED** on DC-S5M2 fw 3.6 via WPD unless marked.

## Summary

| Question | Answer |
|---|---|
| Pushed or polled? | **Polled.** One `0x9706` transaction returns one frame. No stream, no isochronous endpoint. |
| Encoding | Baseline (non-progressive) JPEG, 4:2:2 chroma subsampling, no EXIF, inside a Panasonic TLV container. Decodes with any standard JPEG decoder (Pillow; on iOS `UIImage(data:)`/ImageIO). |
| Dimensions | Setting is a bounding box; the image keeps the photo aspect ratio. At 3:2: 640×432, 960×640, 1280×856. |
| Frame rate | **30.1 fps sustained** at all three sizes, single-threaded polling. |
| Keepalive needed? | No. Polling itself is enough; 5 s+ runs with zero busy responses. |
| Needs 0x9102? | No (verified). Start/stop/frames all work without it. |
| During still capture? | **Yes, stays active.** Frames stop for ~300 ms (exposure blackout) then resume; no restart. |
| After stop | `0x9706` returns `DeviceBusy` (0x2019) with no data. |

## Sequence

```
0x9412  p1=0x0D000010            -> OK          start
(optional) 0x9414 p1=0x0D800012  -> options     list sizes
(optional) 0x9415 p1=0x0D800011  data=setting   choose size (works while running)
loop:
  0x9706                         -> OK + frame   (DeviceBusy => sleep ~20 ms, retry)
0x9412  p1=0x0D000011            -> OK          stop
```
Wait ~200 ms after start before the first fetch (libgphoto2 waits 100 ms; the
first fetch before start returns DeviceBusy). Setters issued <~50 ms after stop
can return InvalidParameter — retry after 300 ms.

## Measured sizes (3 s each, `scripts/test_no_vendor_session_and_lv_sizes.py`)

| 0x9414 entry (h, w, kib, fps) | Decoded JPEG | Avg JPEG | Rate | Payload bandwidth |
|---|---|---|---|---|
| 480, 640, 32, 30 (default) | 640×432 | 22 KiB | 30.1 fps | 0.7 MB/s |
| 720, 960, 250, 30 | 960×640 | 183 KiB | 30.1 fps | 5.6 MB/s |
| 960, 1280, 450, 30 | 1280×856 | 324 KiB | 30.1 fps | 10.0 MB/s |

The third field matches an upper bound on JPEG size in KiB (INFERRED).
Samples: `samples/liveview_640x432.jpg`, `_960x640.jpg`, `_1280x856.jpg`.

## Frame container (`0x9706` data phase)

```
offset  bytes
0x0000  00 00 00 17 04 00 00 00  01 00 01 00                tag 0x17000000 size 4
0x000C  01 00 00 17 08 00 00 00  01 00 01 00 f4 00 00 00    tag 0x17000001: JPEG offset = 0xF4 (244)
0x001C  02 00 00 17 08 00 00 00  01 00 01 00 74 54 00 00    tag 0x17000002: "length" = JPEG len + 12
0x002C  03 00 00 17 50 00 00 00  01 00 01 00 00 00 00 00    tag 0x17000003: histogram (80 B)
        00 00 00 00 40 00 00 00  <64 bytes histogram>        u32 ?, u32 ?, u32 count=64
0x0084  04 00 00 17 06 00 00 00  01 00 01 00 00 00          tag 0x17000004: posture (u16)
0x0092  05 00 00 17 08 00 00 00  01 00 01 00 fd ff 00 00    tag 0x17000005: level gauge s16 roll/10, s16 pitch/10
0x00A2  82 bytes untagged (looks like a second histogram/curve; UNKNOWN)
0x00F4  ff d8 ff db ... ff d9                                JPEG to end of payload
```

Every TLV body starts with `01 00 01 00` (u16 1, u16 1 — probably valid/version).
Values follow at body offset 4. Observed across 3 sample frames: offset always
244; tag 0x17000002 always equals JPEG length + 12; the JPEG always runs exactly to
the end of the data phase. **Robust decoding rule** used in
`panasonic.parse_liveview`: read the offset from 0x17000001, check for `FF D8`, fall
back to searching `FF D8 FF`, and take bytes to the end of the payload.

tethr (S9) assumes a 180-byte header by default — on the S5II it is 244, so always
use the offset tag.

## Booth test (`scripts/test_booth_sequence.py`)

Liveview polled continuously in one thread while the main thread captured two
JPEG-only shots to PC and downloaded them (transactions are serialized by a
lock; WPD/ICC also serialize):

* 307 frames over the run, 0 busy, 28.3 fps average including captures.
* Max frame gap per shot: 303 ms / 326 ms (sensor blackout while exposing).
* 78–79 frames delivered *during* the ~2.9 s capture+download window — live
  view continues while waiting for the object and even while the 9.9 MB JPEG
  downloads (frames interleave between transactions).
* Live view did not need restarting after capture.

## Open questions

* Meaning of the 82-byte untagged block and tag 0x17000000.
* Whether 60 fps settings exist on other firmware (all S5II entries say 30).
* AF frame overlay data (tethr does not decode one; none seen in tags here).
