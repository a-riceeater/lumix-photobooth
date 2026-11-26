# File transfer

## Getting a newly captured image (VERIFIED)
```
event C108/C109 (p1 = handle)
sleep 50 ms
0x1008 GetObjectInfo(handle)   -> ObjectInfo dataset (146 B for a JPEG)
0x1009 GetObject(handle)       -> whole file in the data phase
```
ObjectInfo example (SD JPEG `P1542437.JPG`): StorageID `0x00020001`,
ObjectFormat `0x3801` (EXIF/JPEG), CompressedSize 9 922 048, ThumbFormat 0x3808,
ImagePixWidth/Height 6000×4000, filename `P1542437.JPG`.
RAW objects use ObjectFormat `0x3800` ("undefined image") with `.RW2` names.

| Object | Size | Time | Rate |
|---|---|---|---|
| JPEG, target SD | 9.92 MB | 0.52 s | 19 MB/s |
| JPEG, target PC | 9.92 MB | 0.28–0.33 s | 31–35 MB/s |
| RW2, target PC | 35.7 MB | 1.06 s | 33.6 MB/s |

All over a **USB 2.0 High-Speed** link; WPD READ_DATA chunks of 8 MiB.
`GetPartialObject` (0x101B) is implemented (`Camera.download_partial`) for
chunked transfer but not yet exercised.

## The JPEG file
Standard EXIF JPEG (Make "Panasonic", Model "DC-S5M2", DateTime set). Pillow
reports format "MPO": Panasonic appends MPF secondary images (previews). Any
JPEG decoder reads the primary image; the extra images can be ignored.

## Browsing the card (NOT available in PC(Tether))
* GetStorageIDs → `[0x00010000, 0x00020000]` (slot 1, slot 2; low word 0 means
  "no logical storage exposed").
* GetStorageInfo(each) → `InvalidStorageID`; GetObjectHandles → `ParameterNotSupported`.
* Handles announced via C108 are nevertheless readable (storage `0x00020001`).
* Consequence: the host can only fetch objects it is told about by events during
  the session. For older images, switch the camera USB mode to PC(Storage) / MTP
  (out of scope for the booth).

Note: tethr's S9 report shows the same `getStorages: 0x2008` failure.

## Deletion
Never performed (DeleteObject 0x100B is advertised but deliberately unused).
