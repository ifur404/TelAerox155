# Yamaha Y-Connect 1.0.14 — BLUETOOTH PROTOCOL REVERSE ENGINEERING

> Static analysis only. Nothing was written to the motorcycle. All frame layouts below are read-only understanding of the RX/TX protocol of the Aerox 155 ABS CCU (SCCU1).
>
> Markers used throughout:
> - **[VERIFIED]** — confirmed by direct code reading (class + line given).
> - **[INFERRED]** — strong inference from code, not directly observed (e.g. server-side logic).

---

## 1. Application metadata

| Item | Value | Verification |
|---|---|---|
| Package | `jp.co.yamaha_motor.yamahamotoron` | `manifest-tree.txt` |
| Version | `1.0.14` (versionCode `686`) | manifest |
| APK | `./YamahaMotorOn_1.0.14.apk` | — |
| compileSdk / targetSdk | 36 | manifest |
| minSdk | 29 (Android 10) | manifest |
| Native ABIs | `arm64-v8a` only [VERIFIED: lib/ in APK] | |
| BLUETOOTH | `android.permission.BLUETOOTH`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `BLUETOOTH_ADMIN` | manifest |

Decompiled with jadx 1.5.6 CLI to `./jadx-out/` (34,868 Java files). Kotlin metadata survives but R8 removed many enum classes (left as `final class`).

### Obfuscation & protection [VERIFIED]
- Heavy R8 obfuscation: app packages renamed to short names (`p002a`..`p028z`, `a`..`z` single letters). Framework-independent app code survives under `com.jp.yamaha.yconnect.*`, `jp.co.yamaha_motor.*`, `com.ja.yamaha.*`.
- `com.pairip.application.Application` (PairIP — Google Play anti-tamper wrapper) wraps parts of `motoconsdkv4` and `SCCUBLEConnection` internals. Some PairIP-wrapped methods are **unreadable** (see §9).
- Native libs (`arm64-v8a`): `libbarhopper.so` (MLKit QR/PROTO — used for VIN / QR scanning), `libsqlite3x.so` (sqlcipher), `libsentry.so`, `libdatastore.so`, `libimage_processing.so`.
- **No root/Play Integrity/SafetyNet detection found** [VERIFIED: grep for `isDeviceRooted|RootBeer|PlayIntegrity|SafetyNet|rootBeer|checkRoot|su -c` = no hits]. Protection = PairIP + plain Google Play release checks only.

---

## 2. BLE transport

**Nordic UART Service (NUS)** [VERIFIED `p014i/d.java:64-77`]:

| Constant | UUID | Role |
|---|---|---|
| SERVICE (`f59476b`) | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | NUS service |
| RX char (`f59477c`) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | **Notifications from CCU** (subscribe CCCD) |
| TX char (`f59478d`) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | **Write to CCU** |
| CCCD (`f59479e`) | `00002902-0000-1000-8000-00805F9B34FB` | enable notifications |

- TX writes use property `WRITE` (write type no response) [VERIFIED `p014i/c.java:853`].
- MTU is requested to **512** (`Const.BLE_REQUEST_MTU`); negotiated value stored; max packet size = **MTU − 3** [VERIFIED `p014i/c.java` onMtuChanged]. Auth frame (60 bytes) is a single write.
- No scan filters in `ScanFilter` builder [VERIFIED: scanner has no name/UUID filters]. Device selection happens in `onScanResult` (see §4).

---

## 3. Device naming, CCUID, VIN

- Device advertised name = one of:
  - `YSCCU_<ccuid>` [VERIFIED `p013h/a.java:114`, `p014i/c.java:1292`]
  - `YCCU_<ccuid>` (= `Const.NAME_PREFIX`, `Const.java:32`) [VERIFIED]
- **CCUID = last 14 chars of advertised name** [VERIFIED `p013h/a.java:115` `name.substring(name.length()-14)`]. A new CCUID always begins with `12` (`Const.CCUID_PREFIX = "12"`, `Const.java`).
- `Const.NAME_LIMIT = 19`, `Const.CCUID_LIMIT = 14`.
- Vehicle model detected from CCUID → `SCCU1` device model → parser set `SCCU_BLE_01_48OP` (ASCII of "48OP") [VERIFIED `p028z/a.java` model resolution, `p018m/g.java`].

---

## 4. Connect flow (state machine)

From `p014i/c.java` (SCCUBLEConnection, core of Motocon SDK v4):

```
SCANNING → BONDING (only on first; android device createBond) →
CONNECTING → CONNECTED → DISCOVER_SERVICE → ENABLE_NOTIFICATION →
REQUEST_MTU → INITIALIZED → (send auth 0xAA) → AUTHENTICATION_REQUEST →
START_PROCESSING (case0: only if bonded/mfr) → CONNECTED
```

- Retry with back-off on: bond failure, GATT fail, service discovery fail, authentication ERROR, timeout → up to 5 retries then `RETRY_OVER_ERROR` [VERIFIED].
- Errors enum (`motoconsdkv4`): `NO_ERROR, BOND_ERROR, SCAN_FAILED_ERROR, GATT_ERROR, SERVICE_DISCOVER_ERROR, ENABLE_NOTIFICATION_ERROR, AUTHENTICATION_ERROR, TIME_OUT_ERROR, RETRY_OVER_ERROR, FAIL_TO_GET_SERVICE_ERROR`.
- `isConnectSuccess` = `connected && receivedCommon` (+ `isFirst` path) [VERIFIED].
- `judgeConnected` (normal): requires `receiveCommon && receiveCAN && receiveMarketData` before notifying UI "connected". FFD callback `TransactionResultListener` similarly.

Handshake timing [VERIFIED]: after INITIALIZED + bonding flag known, the auth frame (0xAA, 60 bytes) is written; app waits for StartProcessing RX (0x5A). If `startProcessingFlag != 1` → `AUTHENTICATION_ERROR` → retry.

---

## 5. Frame layer

### 5.1 Checksum [VERIFIED `p023t/a.java`]
```
checksum = (byte)(256 - (sum(all bytes[0 .. n-1]) & 0xFF))
```
Always the **last byte**. All frames (TX and RX) end with `counter` then `checksum`:

```
[ ...payload... | counter(1B) | checksum(1B) ]
```

### 5.2 RX frame identification `identifyMessage` [VERIFIED `p014i/c.java` + `s/d/e/f.java`]
Frame `[0]` = message type byte:

| Type byte | Frame kind | Parser class |
|---|---|---|
| `0x55` 'U' | SCCU_BLE_01_48OP (engine/diag/odometer) | `s/d.java` |
| `0x56` 'V' | SCCU_BLE_CAN | `s/e.java` |
| `0x59` 'Y', byte[3] in `16..<90` | SCCU_BLE_FFD (freeze frame data) | `p018m/f,g.java` |
| `0x59` 'Y', byte[3] in `96..<128` | SCCU_BLE_MARKET_DATA | `s/f.java` |
| `0x5A` 'Z' | SCCU_BLE_START_PROCESSING (auth result RX, 8 bytes) | `v/c.java` |
| `0x5B` '[' | SCCU_BLE_COMMON (module counters) | `s/d.java` common list |
| `0x91` | unknown/connect-notify frame (small) | — |

`byte[1]` = record count.

### 5.3 RX record TLV layout [VERIFIED `p014i/c.java` `verifyDataFormat`]
- Record count at index 1; records begin at index 2.
- Each record: 3-byte header then data. Length byte = header byte at index `recordStart+2`.
  - In the 0x55 frame: `[byte n]=0x00 localID-high, [n+1]=0x01/0x48 localID-low, [n+2]=data length`.
- Walk (from `p018m/g.java:e`): localID at `[i2..i2+1]`, length at `[i2+2]`, data at `[i2+3]`, next record at `i2+3+length`. Bounds checked against `length-3`.
- Frame 0x55 has **exactly 2 records** (the `01&48` frame) [VERIFIED: `bArr[1]==2` gate + localID check in `getTargetBinaryStringBaseCanID`].
  - Record `localID = {0x00, 0x01}` → engine/diagnostic data (contains FI error count, DTC, speeds/temps). Data starts at frame index 5.
  - Record `localID = {0x00, 0x48}` → odometer (UI32).
- `y/a.java` (`DTCRangeData`) desugars to `startByte=85 (0x55), groupByte=2, localID=…, index=bitOffset, dataLength=…`.

---

## 6. AUX: the TX side — only 2 TX frames exist

**Note: the app never requests data. The CCU pushes frames automatically; the app only sends the 2 frames below, then listens.**

### 6.1 Authentication frame TX — 60 bytes [VERIFIED `v/a.java` AuthenticationEntity]
Sent to CCU on NUS TX characteristic after INITIALIZED.

| Byte | Size | Content |
|---|---|---|
| 0 | 1 | `0xAA` |
| 1 | 1 | `0x01` |
| 2-3 | 2 | `0x7F00` (LE) |
| 4 | 1 | `0x35` (53) |
| 5-18 | 14 | **CCUID**, ASCII (from advertisement name, last 14 chars) |
| 19-24 | 6 | **passKey**, ASCII (QR extraction or cloud lookup; see §8) |
| 25-56 | 32 | **phoneUUID**, ASCII (app-generated random UUID persisted in DataStore) |
| 57 | 1 | updateBondingFlag: `1` = first connection, `0` = bonded |
| 58 | 1 | counter (0..255, incremented **after** each send, wraps 255→0) |
| 59 | 1 | checksum (256 − sum&0xFF) |

`[57]=1` triggers Android `createBond` on next flow (bonding used so the phone is "known"). passKey is used **verbatim** (no hashing) [VERIFIED `p013h/a.java` setPassKey wiring].

### 6.2 StartProcessing RX — 8 bytes [VERIFIED `v/c.java` StartProcessingEntity]
Acknowledgement of auth:

| Byte | Size | Content |
|---|---|---|
| 0 | 1 | `0x5A` |
| 1 | 1 | `0x01` |
| 2-3 | 2 | `0x7F01` (LE) |
| 4 | 1 | `0x01` |
| 5 | 1 | startProcessingFlag (`1` = OK; anything else → `AUTHENTICATION_ERROR` retry) |
| 6 | 1 | counter (echo) |
| 7 | 1 | checksum |

---

## 7. Telemetry decoding

### 7.1 Mapping files — SOURCE OF TRUTH [VERIFIED]
- Bundled sample: `./jadx-out/resources/assets/jsons/Sample_SCCU1_MappingFile.json` (full JSON, all SCCU1 items).
- Real per-vehicle files are **downloaded at runtime from the Yamaha cloud (AWS S3)** per CCUID [VERIFIED `com.jp.yamaha.yconnect.feature_vehicle_setting.data.repository.download.VehicleRepositoryDownloadExtKt`]:
  - path template `native/mapping_file/<VehicleType.name()>/MappingFile_<ccuid>.json`
  - e.g. `native/mapping_file/SCCU1/MappingFile_12XXXXXXXXXXXXXXXX.json`
  - `downloadAndSaveAllMappingFile` / `downloadAndSaveMcMappingFileToNative` batch jobs.
  - The app shows a spinner while this download runs on app start. File is parsed by `p006c/d.java` `setMappingFileFromJsonString` into `LinkedHashMap<sectionName, List<McMappingData>>` and wired into the parsers by `p006c/c.java` `setMappingFormatListMap`.

### 7.2 JSON item schema (McMappingData `p009e/a.java`)

Key fields (obfuscated a..l):
- `ServiceID` — hex; equals the RX frame type byte of that item's frame:
  `LocalRecord 0x55`, `CAN 0x56`, `MarketData 0x59`, `CommonRecord 0x5B` [match §5.2].
- `ItemName` — feature name (often Japanese).
- `StartByte` — hex copy of ServiceID.
- `ID` — hex; for CAN it's the CAN dataset id; for LocalRecord = localID record id (0x0001, 0x0048).
- `Length` — **bits** of the value.
- `ByteNo` — **byte index into the full RX frame bytes** (verified against DTC extraction, see §7.4).
- `StartBit` — bit offset inside `ByteNo` (usually 0).
- `Format` — value encoding; see §7.3.
- `FactorTop`, `FactorBottom`, `Offset` — scaling. **value = raw * FactorTop / FactorBottom + Offset** (if bottom 0 → treated as 1) [VERIFIED `s/a.java` RectificationParseUtil].
- `Unit`.

### 7.3 Format strings handled by decoder [VERIFIED `s/a.java`]
`"D"` (unsigned 32-bit as double), `"FG"` (boolean), `"SI8","UI8","SI16","UI16","SI32","UI32"`, `"ASCII"`, `"BCD_DATE"`, and arrays `"UI8Array","UI16Array","SI8Array","SI32Array","UI32Array","FGArray"`.

Conversion pipeline [VERIFIED `s/d.java` SCCUBLEFormatParser]: bit-slice `Length` bits at `ByteNo*8+StartBit` from frame → parse to raw per Format → `adjusted = raw*factorTop/factorBottom + offset` → expose `McValueType` (raw + adjusted).

### 7.4 Verified smoke-test of formula using the sample mapping (frame 0x55)

| Item | Format | ByteNo | L(bits) | factor | offset | decode |
|---|---|---|---|---|---|---|
| 検出異常個数 (FI error count) | UI8 | 28 | 8 | 1 | 0 | frame[28] |
| 検出異常DTC (FI DTC) | UI16 | 29 | 16 | 1 | 0 | frame[29..30] BE |
| 走行距離 odometer | D | 41 | 32 | 1/10 | 0 | frame[41..44] ÷ 10 → **km** |

Cross-check [VERIFIED `p018m/g.java:e` `getTargetBinaryStringBaseCanID`]:
- `DTC_COUNT `: `DTCRangeData(localID={0x00,0x01}, index=24, len=8)` → byte index = 4+24 = **28** ✓ (matches mapping ByteNo 28).
- `DTC_CODE`: `DTCRangeData(localID={0x00,0x01}, index=25, len=16)` → bytes 4+25=29..30 ✓ (matches mapping ByteNo 29).
Both are offsets into the **full RX frame** (index 0 = `0x55`).

Other SCCU1 sample items (engine block, offsets verified in mapping JSON):
- エンジン回転数 engine RPM: `ID 0x0001`, ByteNo 5, UI16, factor 1/2 → RPM = frame[5..6]/2.
- 車速 vehicle speed: ByteNo 7, UI8, km/h.
- バッテリ電圧 battery V: ByteNo 11, ×1/2 → volts.
- スロットル開度 throttle %: ByteNo 13, ×125/256.
- 水温 coolant: ByteNo 19, UI8, offset −30 → °C.
- 吸気温 intake air: ByteNo 20, offset −30.
- 気圧 barometric: ByteNo 23, ×127/256.
- CAN block (0x56): FI warning lamp `ServiceID 0x2C` ByteNo 18 UI8; injectors `0x2D..0x30` ×100 (cc).
- CommonRecord (0x5B): ECU total ON time `ID 0xF1A1` UI32 ByteNo 39 (seconds); IGN ON count `ID 0xF1A2` UI16 ByteNo 46.

### 7.5 DTC / FFD / Market flows [VERIFIED `p018m/{b,f,g}.java`]
- DTC callback supplies list of `DTCInfo(code=Short/Long, desc)`; triggered when SCCU_BLE_01_48OP frame with localID {0,1} arrives and FI error count > 0.
- FFD: RX `0x59` with byte[3] 16..<90 → `getTargetBinaryStringBaseCanID` slices per mapping → FFD records; `TransactionResultListener` gets SUCCESS/FAILED.
- Market: `0x59` byte[3] 96..<128 → market data via `s/f.java` using mapping section `MarketData`.

---

## 8. passKey provenance — QR local extraction and VIN lookup

Updated 2026-10-05. The earlier cloud-only conclusion is withdrawn.
See [the pairing follow-up](04-apk-qr-pairing.md) for source references and
provenance limits: existing decompiled Java was inspected, relevant identifiers
were checked in the supplied APK, but the complete decompile was not verified
byte-for-byte against that APK. No real QR or new BLE pairing was tested.

The inspected handlers have separate paths:

```text
CCU QR (24 characters)
  → local character permutation
  → compare decoded prefix against selected CCU ID
  → extract six-character passKey

Manual VIN confirmation
  → compare entered characters with VIN.dropLast(2).takeLast(4)
  → GET pairing_info/{full VIN}, using a session JWT
  → response contains ccuid and passKey

passKey → ExploredVehicleUIModel / Bluetooth connection settings
  → existing 0xAA authentication frame
```

- The QR handler extracts credentials locally; it does not merely fill a VIN.
  This does not prove that the official app's entire onboarding works offline.
- The manual screen already has the full VIN. Its upstream source still needs
  tracing; the four entered characters cannot independently supply a full VIN.
- GraphQL operations also exist, but are not the direct passKey lookup in the
  inspected manual handler. A server response does not establish how the
  server derives or stores a passKey.
- Earlier research records a per-install phoneUUID persisted in DataStore
  (`AppDataStore.setPhoneUUID`). Acceptance of a newly generated UUID together
  with QR-derived credentials still requires a motorcycle test.

---

## 9. Cloud vs local split (for a read-only iOS app)

**Local (BLE, works without cloud after passKey obtained):**
- Odometer, engine/vehicle diagnostics (RPM, speed, temp, voltage, throttle, errors), DTC, FFD, market data, ECU ON time, IGN count — all pushed by CCU in 0x55/0x56/0x59/0x5B frames after auth.
- Frame parsing fully self-contained (bit slicing + mapping JSON).

**Cloud (needs internet / account):**
- **Manual VIN passKey lookup** (REST with session token); QR extraction itself is local, subject to the validation limits in §8.
- Per-CCUID mapping file (S3) — but with the bundled `Sample_SCCU1_MappingFile.json` the parser can already decode any SCCU1; cloud file is only a refresh/edge-case mechanism. **Caveat**: mapping offsets for a specific Aerox could in principle differ per CCUID, so the sample is an approximation until a live capture confirms exact byteNo.
- Riding log lookback / trip records / vehicle-tracking `/v1/…` REST + GraphQL (`feature_lookback`), analysis service, oil-change advisories, theft alerts — all cloud.

---

## 10. Practical read-only iOS integration summary

1. Scan for names starting `YSCCU_` or `YCCU_`; take last 14 chars as CCUID.
2. Connect GATT to `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`; request MTU 512; enable notifications on `6E400003…`; write on `6E400002…` (no-response).
3. Obtain credentials from a compatible CCU QR or the authenticated VIN lookup (§8). Validate the QR format and CCU identity before treating this as a working onboarding path; the current iOS app still uses local JSON credentials.
4. Write 60-byte auth frame (table §6.1). Expect 8-byte StartProcessing; retry on mismatch. Counter starts anywhere; checksum included.
5. Read notifications; group by type byte; validate checksum; parse per §5/§7 using the sample mapping JSON.
6. Record 0x55 frame: engine + odometer (frame[41..44]/10 km). Frame 0x59 = FFD(byte3 16..<90)/Market(≥96). 0x5B = common counters.
7. Keep motorcycle writes within `AGENTS.md`: authentication and periodic `0xA6` keep-alive according to `KeepAlivePolicy`. Do not add diagnostic requests or vehicle-control writes.

---

## 11. Open questions / risks

- **Exact per-CCUID mapping file** for a given Aerox is not in the APK (S3 download). Sample bundled file is the best static equivalent; verify live a few ByteNo values before trusting all units.
- **Pairing validation:** test a real owner-provided QR locally, confirm CCU matching and auth acceptance; trace the full-VIN source and account session flow for manual pairing. Server-side passKey derivation and credential lifetime remain unknown.
- **PairIP-wrapped methods** (part of `motoconsdkv4/a.java`, `b.java`, some `SCCUBLEConnection` internals) returned opaque `null` in jadx — those specific code paths (bond sequence, some counters) remain **unreadable** and were classified [INFERRED] where relied on (none critical to frame layout, which is fully verified).
- Counter echo: RX counter is consumed monotonically; a custom client that only reads can ignore it.

---

## 12. Key source references (all under `./jadx-out/sources/`)

- GATT/NUS UUIDs: `p014i/d.java`
- SCCUBLEConnection core (identifyMessage, auth send, counter, connect-complete, retry): `p014i/c.java`
- Scanner & name→CCUID filter: `p013h/a.java`
- Auth entity (60 B TX): `v/a.java`; StartProcessing (8 B RX): `v/c.java`; checksum: `p023t/a.java`
- Format decoders: `s/{d,e,f,a}.java`; parser wiring: `p006c/{c,d}.java`; mapping descriptor: `p009e/a.java`
- DTC/FFD/Market builders: `p018m/{b,f,g}.java`; DTC range descriptor: `y/a.java`
- MC message kinds: `p004b/d.java`
- Constants (NAME_PREFIX "YCCU_", CCUID_PREFIX "12", BLE_REQUEST_MTU 512, limits): `jp/co/yamaha_motor/spv/yeplibrary/constants/Const.java`
- Cloud mapping download: `com.jp.yamaha.yconnect.feature_vehicle_setting.data.repository.download/VehicleRepositoryDownloadExtKt*.java`
- PassKey wiring: `com.jp.yamaha.yconnect.core.data.source.bluetooth/MotoconClientImpl.java:450`, pairing repo + GraphQL wrappers under `feature_pairing/data/**`
- Sample mapping (SCCU1): `resources/assets/jsons/Sample_SCCU1_MappingFile.json`
