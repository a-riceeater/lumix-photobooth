# Command reference — Panasonic DC-S5M2 (S5II) over USB PTP

Camera: DC-S5M2, firmware 3.6, USB mode **PC(Tether)**, VID `04DA` PID `2382`.
Host: Windows 11, stock Microsoft MTP driver (`wpdmtp.inf`), transport = WPD
MTP vendor-extension commands (see `usb-transport.md`).

## Verification legend

| Tag | Meaning |
|---|---|
| **VERIFIED** | Executed by our implementation against the connected S5II; result checked. |
| **TETHER** | Observed in LUMIX Tether USB traffic (pending — see `research.md` §Phase 2). |
| **SOURCE** | Present in libgphoto2 (`camlibs/ptp2`) and/or tethr (`TethrPanasonic.ts`). |
| **INFERRED** | Reasoned from data; not yet exercised. |
| **UNKNOWN** | Not understood / not supported. |

## Conventions

* All integers little-endian. "u32 p1" = first PTP operation parameter.
* *Data phase*: `none`, `in` (camera→host), `out` (host→camera).
* Panasonic payloads use a **TLV** layout everywhere:
  `{u32 code, u32 size, size bytes value}` repeated. A *group* code
  (e.g. `0x02000020` ISO) returns all its members (`0x02000021`, `0x02000022`, …).
* Example packets show the **USB PTP bulk container** (12-byte header
  `u32 length, u16 type, u16 code, u32 transaction_id` + params). Containers are
  *constructed* from the PTP spec using our verified opcode/params; the
  transaction ID (`TT TT TT TT`) is assigned by the driver. Under WPD/ICC the
  host never builds containers itself — only opcode/params/data are supplied.

---

## Standard PTP operations (used as-is)

| Op | Name | Params | Phase | Status | Notes |
|---|---|---|---|---|---|
| 0x1001 | GetDeviceInfo | – | in | VERIFIED | VendorExtensionID `0x1C`, VendorExtVersion 100, empty ext desc. Sample: `samples/deviceinfo_wpd.bin`. |
| 0x1002/0x1003 | Open/CloseSession | – | none | VERIFIED (implicitly) | Issued by the Windows MTP driver, never by us. ImageCaptureCore also owns this. |
| 0x1004 | GetStorageIDs | – | in | VERIFIED | Returns `0x00010000`, `0x00020000` (lower 16 bits 0 = no logical storage). In PC(Tether) mode card contents are **not browsable**. |
| 0x1005 | GetStorageInfo | storage | in | VERIFIED → `InvalidStorageID` | For both IDs above. |
| 0x1007 | GetObjectHandles | storage, fmt, parent | in | VERIFIED → `ParameterNotSupported` | Card listing unavailable in tether mode. |
| 0x1008 | GetObjectInfo | handle | in | VERIFIED | Works for handles announced by `C108`/`C109`. Storage ID of SD objects: `0x00020001` (card in slot 2). |
| 0x1009 | GetObject | handle | in | VERIFIED | 9.9 MB JPEG in 0.28–0.52 s. |
| 0x101B | GetPartialObject | handle, offset, size | in | SOURCE | Implemented, not yet exercised. |

---

## Panasonic vendor operations

### 0x9102 — Panasonic OpenSession
```
Operation:        Enter Panasonic remote/tether session
Opcode:           0x9102
Parameters:       p1 = 0x00010001
Outgoing data:    none
Incoming data:    none
Expected response:OK (0x2001), response param1 = 0x00010001
Required state:   PTP session open (driver)
Example packet:   10 00 00 00 01 00 02 91 TT TT TT TT 01 00 01 00
Observed behavior:OK. Live view AND capture both also work WITHOUT it (tested).
                  Its exact purpose is unknown; LUMIX Tether and tethr send it.
Verification:     VERIFIED (S5II); SOURCE (libgphoto2 comment, tethr open())
```

### 0x9103 — Panasonic CloseSession
```
Opcode: 0x9103   Parameters: p1 = 0x00010001   Data: none   Response: OK
Example packet: 10 00 00 00 01 00 03 91 TT TT TT TT 01 00 01 00
Verification: VERIFIED (S5II); SOURCE (tethr close())
```

### 0x9104 — Get ext device ID
Advertised in DeviceInfo. Not exercised. **UNKNOWN** (libgphoto2: "get ext device id (1 arg?)").

### 0x9108 — GetPropertyDesc ("ListProperty")
```
Opcode:          0x9108
Parameters:      p1 = property code (e.g. 0x020000A2)
Incoming data:   u32 code, u32 headerLen (=0x14 → 20 words), ... header ...
                 at offset headerLen*4+8: <value_size> current value,
                 u32 count, count × <value_size> allowed values
Observed:        image_quality (2-byte): current 4, allowed {0,1,4,5,3}
                 iso (4-byte): current 0xFFFFFFFF, 29 values (auto,100..51200)
                 af_mode / mode_pos: count 0 → physical lever/dial, read-only
Verification:    VERIFIED (S5II); SOURCE (libgphoto2, tethr) — layout matches.
```
Header bytes 8..headerLen*4+8 are not decoded (contain the code repeated,
`01 00 01 00`, and size fields — see `samples` hexdumps in camera-settings.md).

### 0x9401 — Acknowledge event (C101)
```
Opcode:          0x9401
Parameters:      p1 = param1 of event 0xC101 (observed: always 0x01000010)
Incoming data:   4936 bytes TLV: 0x01000011..0x0100001D (status dump; mostly undecoded)
Response:        OK
Required state:  after receiving 0xC101
Observed:        libgphoto2/tethr call this "following LUMIX Tether". Capture also
                 completed when C101 was NOT acknowledged (first test), so not
                 strictly required. We ack automatically.
Sample:          samples/ack_9401_01000010.bin
Verification:    VERIFIED (S5II); SOURCE
```

### 0x9402 — GetProperty
```
Opcode:          0x9402
Parameters:      p1 = property or group code
Incoming data:   TLV list of members
Example:         p1=0x02000020 (ISO) →
                 21 00 00 02 04 00 00 00 ff ff ff ff   ISO_Param = auto
                 22 00 00 02 04 00 00 00 00 c8 00 00   ISO upper limit = 51200
                 25 00 00 02 02 00 00 00 ff ff         (unknown, 0xFFFF)
Errors:          GeneralError for codes outside the 0x02xxxxxx families
                 (use 0x9414 for 0x12/0x16 status families)
Verification:    VERIFIED (S5II); also works without 0x9102
```

### 0x9403 — SetProperty
```
Opcode:          0x9403
Parameters:      p1 = property code (the *_Param member, e.g. 0x02000021)
Outgoing data:   u32 code, u32 value_size, value (value_size bytes)
Example:         ISO 400: 21 00 00 02 04 00 00 00 90 01 00 00
Response:        OK. Transient InvalidParameter right after liveview stop →
                 retry after 300 ms. An out-of-list ISO (12345) ALSO returned OK,
                 so always read back to confirm.
Events:          C102 PropChanged (p1 = 0x02000010, 0x02000021, 0x02000060)
Verification:    VERIFIED (ISO round trip auto→400→auto; quality 4→0→4)
```

### 0x9404 — Release (shutter)
```
Opcode:          0x9404
Parameters:      p1 = 0x03000011
Data:            none
Response:        OK within ~15 ms (asynchronous; image arrives later)
Example packet:  10 00 00 00 01 00 04 94 TT TT TT TT 11 00 00 03
Events:          C101(0x01000010) immediately, C107(0x12000010/20),
                 then C108 (SD) or C109 (PC) with the object handle
Errors:          GeneralError reported by tethr when camera not ready (e.g. just
                 after AF) — retry once after 1 s. In AF-S the camera may refuse
                 silently when it cannot focus (tethr).
Verification:    VERIFIED (6 shots, MF + M mode)
```

### 0x9405 — AF/AE control
```
Opcode:          0x9405
Parameters:      p1 = 0x03000024 one-shot AF (tethr), others (libgphoto2 names):
                 0x03000021 AE lock, 0x03000022 AF lock, 0x03000023 AF/AE lock,
                 0x03000025 lock clear
Response:        OK in 14–19 ms (asynchronous)
Completion:      no dedicated event. Each C101 is acked with 0x9401; in the
                 returned dump, 0x01000011 (u16) goes 0xFFFE idle -> 0x0000
                 focusing (0x01000012 byte 4 = 3) -> 0xFFFF finished/locked.
                 0x03000025 (lock clear) returns it to 0xFFFE.
                 AF-S: 1.38–1.67 s on the test scene.
AF-C (lever AFC, af_mode 5): same 0xFFFE -> 0x0000 (~0.3 s) -> 0xFFFF (~1.4 s)
                 sequence, but 0x01000012 byte 4 stays 0, and lock clear does not
                 produce a new status dump (state keeps reading 0xFFFF).
                 No status dumps arrive while idle (no continuous AF reporting).
Verification:    VERIFIED (AF-S 6 cycles, AF-C 6 cycles). Focus-failure value PENDING.
```

### 0x940A / 0x940B — Get/Set capture target
```
0x940A  p1 = 0x08000090  data in:  91 00 00 08 02 00 00 00 TT 00
0x940B  p1 = 0           data out: 91 00 00 08 02 00 00 00 TT 00
        TT: 0 = SD card, 1 = PC (camera RAM, "SDRAM"), 2 = both
Persistence: survives vendor-session close/reopen (verified); restore when done.
Verification: VERIFIED (0 ↔ 1). Value 2 SOURCE only.
```

### 0x9412 — Liveview on/off
```
p1 = 0x0D000010 start / 0x0D000011 stop.  Data: none.  Response: OK.
Example packet (start): 10 00 00 00 01 00 12 94 TT TT TT TT 10 00 00 0d
Verification: VERIFIED (works with and without 0x9102)
```

### 0x9414 — GetStatus
```
p1 / reply (VERIFIED on S5II):
  0x0D800011 current liveview setting: 11 00 80 0d 08 00 00 00 | u16 h, u16 w, u16 kib, u16 fps
  0x0D800012 liveview options: 12 00 80 0d <size> | u16 count, u16 8 | count × {h,w,kib,fps}
             S5II: 480x640/32/30, 720x960/250/30, 960x1280/450/30
  0x12000010 recording status group: 0x12000011 remaining shots (u32), 0x12000012..1B
  0x12000011 / 0x12000013 single members
  0x12000020 exposure readout: 0x12000021 aperture (x10), 0x12000022 shutter, 0x12000023 meter (s32 thirds)
  0x16000010 battery: 0x16000011 = u32 percent, u16 percent, u16 0xFFFF
  0x08000010, 0x01000010: GeneralError
```

### 0x9415 — Set liveview setting
```
p1 = 0x0D800011; data out: 11 00 80 0d 08 00 00 00 | u16 h, u16 w, u16 kib, u16 fps
(copy an entry from 0x9414(0x0D800012)). Works idle and during liveview;
InvalidParameter immediately after liveview stop → retry.  VERIFIED.
```

### 0x9416 — Manual focus drive
SOURCE only: data `u32 0x03010011, u32 2, u16 mode` (1/2 far, 3/4 near). Not tested.

### 0x9706 — Get liveview image
```
Params: none. Data in: TLV header + JPEG (see live-view.md).
Response: OK with data while liveview runs; DeviceBusy with 0 bytes when off.
Poll-based: one frame per transaction; 30.1 fps sustained. VERIFIED.
```

### Other opcodes (SOURCE only, not exercised)
`0x9101`, `0x9107` (prop size), `0x9110`, `0x9112`/`0x9113` (partial / skip object
transfer), `0x9406` (format, sensor clean, firmware — **never send**), `0x9408`/`0x9409`
(movie config), `0x940C` movie rec, `0x940D` power control (**never send**),
`0x940E`/`0x940F` playback, `0x9410`, `0x9411` GPS, `0x9603` ChangeEvent, `0x9605`,
`0x9606`/`0x9607` (firmware upload — **never send**), `0x9703`, `0x9704` (USB mode),
`0x9705`, `0x9707`.

---

## Events (interrupt endpoint 0x82)

| Code | Name | Params | Status |
|---|---|---|---|
| 0xC101 | AckRequired / status changed | 0x01000010 | VERIFIED; answered with 0x9401, whose dump carries AF state (0x01000011) |
| 0xC102 | PropChanged | property group (0x02000010, 0x02000021, 0x02000060, …) | VERIFIED |
| 0xC104 | (config changed?) | 0x08000010 | VERIFIED seen after SD capture; meaning INFERRED |
| 0xC107 | StatusChanged | 0x12000010 (remaining shots), 0x12000020 (exposure) | VERIFIED |
| 0xC108 | ObjectAdded (SD) | handle (0x52…=JPG, 0x59…=RW2, 0x51… seen once) | VERIFIED |
| 0xC109 | ObjectAdded (PC/SDRAM) | always 0x12345678 | VERIFIED |
| 0xC103, 0xC106, 0xC10A, 0xC201–C205, 0xC212 | advertised | – | UNKNOWN |
