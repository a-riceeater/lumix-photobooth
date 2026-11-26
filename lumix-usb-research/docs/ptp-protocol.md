# PTP layer as used by the S5II

## USB PTP containers (ISO 15740 / USB Still Image Class 1.0)
Every bulk transfer carries a container:
```
u32 length   (header + payload)
u16 type     1 command, 2 data, 3 response, 4 event
u16 code     operation / response / event code
u32 transactionID
payload      command/response: 0–5 × u32 params; data: raw bytes
```
A transaction = command container (OUT) → optional data container (OUT or IN) →
response container (IN). Events arrive independently on the interrupt endpoint
(`type 4`, up to 3 params). Under WPD and ImageCaptureCore the OS builds and parses
these; our code only sees opcode/params/data/response.

Standard datasets used: DeviceInfo, ObjectInfo (parsers in `src/lumix_usb/ptp.py`).
PTP strings = u8 count (incl. NUL) + UTF-16LE.

## Panasonic conventions on top of PTP (VERIFIED)
* **32-bit "property codes"** instead of 16-bit DevicePropCodes. High byte = family:
  `0x02` recording settings, `0x03` record control, `0x08` setup/files,
  `0x0D` liveview, `0x12` recording status, `0x16` battery, `0x17` liveview frame
  tags, `0x01` event-info dump.
* **TLV payloads**: `u32 code, u32 size, value` repeated. A group code returns all
  members (`0x02000020` → `0x02000021`, `…22`, `…25`).
* **Command parameters are property codes**, e.g. release = `0x9404(0x03000011)`,
  liveview start = `0x9412(0x0D000010)`.
* **Response codes are standard** PTP: OK 0x2001, GeneralError 0x2002,
  DeviceBusy 0x2019, InvalidParameter 0x201D, InvalidStorageID 0x2008,
  ParameterNotSupported 0x2006.
* **Events** are vendor codes 0xC1xx with one param (a property/status code or an
  object handle).

## Error handling rules (from observations + sources)
| Situation | Response | Action |
|---|---|---|
| 0x9706 when liveview off / not ready | DeviceBusy, no data | sleep 20–40 ms, retry (libgphoto2: 25 tries) |
| Setter just after liveview stop | InvalidParameter | retry after 300 ms (up to 4×) |
| Release just after AF (tethr) | GeneralError | wait 1 s, retry once |
| Property family not served by opcode | GeneralError | use the right opcode (0x9402 vs 0x9414) |
| GetObjectInfo on empty SDRAM queue | InvalidParameter | nothing pending |
