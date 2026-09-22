# Capture Aerox-155.pklg — HASIL ANALISIS BLE v2 (reassembly L2CAP)

> Validasi wire-protocol Yamaha Y-Connect terhadap capture PacketLogger
> `./Aerox-155.pklg` (20-Sep-2026, iPhone 15, iOS 24.1.6). **Dokumen ini v2** —
> menggantikan capture-findings.md v1 yang punya bug fundamental: arah ditentukan
> dari **PB flag** (salah) dan frame dianggap "terpotong 20 B".
>
> Setiap klaim dijawab dengan label: **TERKONFIRMASI** / **TERBANTAH (+nilai benar)**
> / **BELUM JELAS**. Angka diverifikasi offline oleh `./dissect.py`
> (Python mandiri, reassembly L2CAP + checksum 100%).

File terkait:
- `./dissect.py` — parser + reassembly (sudah diperbaiki, output JSON)
- `./Aerox-155.pklg` — capture asli (69.444 B, 1.785 record)
- `./jadx-out/resources/assets/jsons/Sample_SCCU1_MappingFile.json` — mapping telemetri
- `./mapping-overrides.json` — faktor field yang BEDA dari sample mapping
- `./secrets.local.json` — kredensial motor (GITIGNORE)
- `./findings.md` — layout frame hasil RE statis APK

---

## 1. ARAH & REASSEMBLY L2CAP — v1 TERBANTAH

### Akar bug v1
v1 menentukan arah dari **PB flag** (PB=0 → out, PB=2 → in) dan menganggap semua
notifikasi "hanya 20 byte" → menyimpulkan frame terpotong / checksum gagal.
**Keduanya salah.**

### Arah yang benar = tipe record HCI (bukan PB)
| Tipe pklg | Arti | Jumlah |
|---|---|---|
| `0x02` | ACL Data **Sent** (phone→CCU) | 125 |
| `0x03` | ACL Data **Received** (CCU→phone) | 1.249 |
| `0x00/0x01/0xFC/0xFD` | packet kontrol sistem (bukan ACL data) | 111/267/9/24 |

**TERKONFIRMASI:** semua frame scooter ada di ACL handle `0x005A` (90),
NUS notify di ATT handle `0x000F`, TX di `0x000D`.

### PB = fragmentasi paket, bukan arah
- `PB=00/10` → **awal PDU baru** L2CAP (2 byte pertama = panjang LE; target total = 4 + len, karena header 2B len + 2B CID).
- `PB=01` → **lanjutan** PDU (digabung sampai total tercapai), baru parse ATT dari PDU utuh.
- Statistik arah RX: PB2 ×607, PB1 ×642; arah TX: PB0 ×125. `orphan PB1 = 0` → reassembly bersih.

### Hasil: 732 PDU L2CAP → 731 ATT (CID 0x0004), 1 PDU CID 0x003A (ping/keepalive?)

**TERKONFIRMASI — frame penuh setelah reassembly (bukan 20 B):**

| Frame | N | Panjang penuh | checksum |
|---|---|---|---|
| `0x55` (engine/diag) | 277 | **47 B** (seragam) | **100%** |
| `0x56` (CAN/status) | 279 | **30 B** (seragam) | **100%** |
| `0x57` (relay) | 1 | **59 B** | 100% |
| `0x59` (config pages) | 20 | **77 B** (seragam) | **100%** |
| `0x5A` (StartProcessing) | 1 | 8 B | 100% |
| `0x5B` (info/VIN) | 1 | **67 B** | 100% |

> Client kustom: **jangan** bangun decoder "bentuk pendek 20 B". Selalu
> reassemble L2CAP (PB01 = lanjutan) lalu parse ATT utuh.

---

## 2. CHECKSUM — TERKONFIRMASI 100%

Formula (kini berlaku di SEMUA frame RX setelah reassembly):

```
checksum_byte = (256 - (sum(b[0 .. n-2]) & 0xFF)) & 0xFF   == b[n-1]
```

- **RX: 0x55 277/277, 0x56 279/279, 0x57 1/1, 0x59 20/20, 0x5B 1/1, 0x5A 1/1 → 100%**
- TX: auth `0xAA` (60B) VALID, StartProcessing 8B VALID, poll `0xA6` 58/58 VALID.
- v1 klaim "telemetri checksum gagal / footer hilang" → **TERBANTAH** (artefak fragmentasi).

---

## 3. AUTH & StartProcessing — TERKONFIRMASI

Auth `0xAA` (write cmd ATT `0x52` ke ah `0x000D`, 60 B), ±9 ms sebelum `0x5A` ACK:
```
aa 01 7f 00 35 30 30 30 30 30 30 34 34 36 39 30 39 32 37 36 35 32 38 30
  45 46 41 38 33 35 43 36 43 31 37 41 34 43 33 42 38 42 43 46 38 42 32
  36 44 46 44 41 45 39 34 34 00 00 0c
```
- `b2..b3 = 7f 00` → **LE 0x007F = 127** = endianness header auth **LE** (konfirmasi v1). Nilai 127 ≠ panjang frame (60) → kemungkinan protoVersion/sizeof.
- `b4 = 0x35` protocolVersion; `[5..18]` ccuid `00000004469092`; `[19..24]` passKey `765280`;
  `[25..56]` phoneUUID `EFA835C6C17A4C3B8BCF8B26DFDAE944` (32 hex);
  `[57]=0x00` bonded; `[58]=counter 0`; `[59]` checksum VALID.
- Balasan `5a 01 7f 01 01 01 01 22`: `startProcessingFlag [5]=1` → **auth diterima**, checksum VALID.

---

## 4. FRAME `0xA6` (poll waktu) — struktur TERKONFIRMASI, `0xB4` BELUM JELAS

58x dari phone→CCU (write `0x52` ah `0x0D`), checksum 100%, selama stream telemetri.

```
a6 01 05 8a 08 <payload 8 B> <counter> <checksum>      (x29)
a6 01 05 8b 02 00 00 <counter> <checksum>              (x29)
```

- cmdID bytes `[2..3]` = `05 8a` = BE **0x058A** (set datetime, 29x) dan **0x058B** (clock sync/keepalive, 29x).
- Payload `0x058A` (8 B): `07 ea 09 14 0a 0a <detik> b4` → `0x07EA=2026`, bulan `09`, hari `0x14=20`,
  jam `0x0A`, menit `0x0A`, detik 0..0x1C (naik 1/detik).
- **Counter**: tiap detik = 1 pasang `058A` (counter genap 0,2,4,..) + `058B` (counter ganjil 1,3,5,..)
  → satu counter monoton yang dipisah ke dua perintah. (v1 tidak sadari ini.)
- **`0xB4` = KONSTAN (180) di semua 29 frame `058A`** — bukan waktu variabel.
  Bukan offset tz `+7` (0xB4=180; 180/60 = 3 jam, logikanya tidak cocok).
  Kemungkinan flag tetap / magic byte. Daerah waktu UTC (jam `0x0A` = 10:xx UTC).
  **BELUM JELAS** fungsinya.

---

## 5. TLV `0x55` — walk 100% (v1 "gagal" TERBANTAH)

- **Semua 277 frame** walk sukses, bentuk **seragam**: `(('00 01', len 33), ('00 48', len 4))` + counter + checksum = 47 B.
- rec `{00 48}` (odometer) **ADA** — v1 "tidak pernah tercapai" **TERBANTAH**.
- Byte `[45]` = counter (nomor frame 0-based mod 256; bukti linear 0,1,2,... → **TERKONFIRMASI**).
- Byte `[46]` = checksum (valid 100%).
- **Odometer `[41..44]` = `00 06 b9 f3`**: BE32 `440819` ÷10 = **44.081,9 km**
  (stabil semua frame; motor diam). LE32/10 = 408.898.918 km → **TERBANTAH**.
  Jadi numerik payload `0x55` = **BIG-ENDIAN**, fb=10 → **TERKONFIRMASI**.
- Tidak perlu "decode dua jalur" (pendek/panjang) seperti v1 — itu artefak fragmen.

---

## 6. MAPPING FIELD (0x55) vs SAMPLE — hanya SATU mismatch (aki)

Mesin **hidup & idle** selama jendela telemetri (§7: cranking → idle → blip).
Sedikit bukti silang naik/turun vs RPM dipakai untuk memilih faktor.

| Field | ByteNo | Sample ft/fb | raw (0x55) | Sample-scaled | Terbukti | Verdict |
|---|---|---|---|---|---|---|
| EG回転速度 (RPM) | 5 | 1/1 | BE16 21→2903 | ×1 | idle median **1578 rpm**, puncak 2903 | **TERKONFIRMASI fb=1** (fb=1/2 → 775 terlalu rendah utk Aerox) |
| 車速 | 7 | 1/1 | 0 | 0 km/h | motor diam | TERKONFIRMASI |
| バッテリ電圧 | 11 | **1/2** | 147..192 | 73.5..96 V | **11.3..14.8 V (fb=13)** | **TERBANTAH → override fb=13** |
| 相対スロットル開度 | 13 | 125/256 | 1 (idle), 7..8 (blip) | 0.49° / 3.4-3.9° | konsisten | TERKONFIRMASI |
| 冷却水温/機温 | 19 | SI8 off-30 | 63..64 | 33..34 °C | mesin baru start | TERKONFIRMASI |
| 吸入空気温度 | 20 | UI8 off-30 | 58..59 | 28..29 °C | ok | TERKONFIRMASI |
| 大気圧 | 23 | 127/256 | 200 | 99.2 kPa | permukaan laut | TERKONFIRMASI |
| 検出異常個数 (FI) | 28 | 1/1 | 0 | 0 | tanpa error | TERKONFIRMASI |
| DTC (FI) | 29 | 1/1 | 0 | 0 | tanpa DTC | TERKONFIRMASI |
| 走行距離 (odometer) | 41 | 1/10 | BE32 440819 | 44.081,9 km | BE/10 | **TERKONFIRMASI** |

### Bukti voltase aki → fb=13
- Cranking awal (rpm 21→1600): raw `97..9B` (151..155) → **11.6..11.9 V** — drop saat starter, fisik.
- Idle stabil: raw `b0..b9` (176..185) → **13.5..14.2 V** charging — fisik.
- Blip (rpm 2903): raw `bf` (191) → **14.7 V** — fisik.
- fb=2 (sample) → 73.5..96 V **mustahil** untuk aki 12 V. **`mapping-overrides.json` = fb 13.**

---

## 7. URUTAN SESI — telemetri TIDAK dipicu oleh `0xA6`

Deret waktu (dt dari PDU ATT pertama):

```
  0 ms     ATT exchange (MTU 247: req 293 / resp 0x00F7)
  6.6 s    auth 0xAA (WRITE 0x52 ah 0x0D)
  6.9 s    0x5A StartProcessing ACK
 ~7.3 s    info dump: 0x5B (VIN) + 0x59 x20 (config pages ff60..ff73)
 ~10.3 s   stream telemetri MULAI: 0x56 pertama (10.288 ms),
          0xA6 pertama (10.297 ms), 0x55 pertama (10.437 ms)
 10.3..38.8 s  stream 0x55+0x56 @~92 ms + pair A6 @1 s
 36.7 s    0x57 (relay notifikasi, 59 B)
```

- **`0x56` (telemetri paling awal) muncul ~9 ms SEBELUM `0xA6` pertama** →
  stream TIDAK digerakkan oleh `0xA6`. `0xA6` (058A datetime + 058B) adalah
  **sinkronisasi jam periodik** yang ditulis aplikasi tiap detik selama stream —
  bukan pemicu. **BELUM JELAS** apakah CCU berhenti stream tanpa 0xA6; di capture
  ini ia selalu menyertai sesi aktif.
- Ada jeda ~2.9 s antara dump info (7.3 s) dan awal stream (10.3 s).
- Jendela telemetri = ±28.5 s (0x55) / 28.6 s (0x56); sisanya capture idle/ANCS.

---

## 8. FRAME `0x59` & `0x5B` setelah reassembly — TERKONFIRMASI

### `0x5B` (67 B): blok info kendaraan — VIN TERBACA UTUH

| rec | len | data | arti |
|---|---|---|---|
| `{f1 90}` | 17 | ASCII **`MH3SG6420MJ028368`** | **VIN/frame no** (17 char, gaya Yamaha Indonesia MH3...) — v1 terpotong `...0283`, kini UTUH |
| `{f1 94}` | 4 | `12 4a 00 41` | BELUM JELAS |
| `{f1 97}` | 4 | ASCII **`BBP2`** | kode model |
| `{f1 a1}` | 4 | `00 54 07 d4` | BELUM JELAS |
| `{f1 a2}` | 2 | `1c 0c` | BELUM JELAS |
| `{f4 21}`, `{f4 4d}` | 2 | `00 00` | kosong/reserved |
| `{f7 01}` | 4 | `00 00 00 b5` | BELUM JELAS |

checksum final: VALID.

### `0x59` (77 B, x20): tabel config/parameter
Tiap frame = 1 record `{ff 60}` ... `{ff 73}` len 70 (index naik per frame),
data 70 B baris log 8 B (`00 07 8c 64 00 07 99 d0 00 08 9b 8c ...`) + counter +
checksum (VALID). Isi = halaman parameter / event history. **BELUM JELAS**
enumerasi field per halaman (tidak ada mapping di sample file).

---

## 9. RINGKASAN PUTUSAN v1 → v2

| Klaim v1 | Status |
|---|---|
| Arah = PB flag | **TERBANTAH** → arah = tipe record HCI (0x02 sent / 0x03 recv) |
| Notifikasi "20 B", frame terpotong | **TERBANTAH** → fragmen L2CAP; frame penuh 30-77 B, reassembly OK |
| Checksum telemetri 0% / footer hilang | **TERBANTAH** → **100%** semua tipe RX |
| Odometer `{00,48}` tak ada / tidak tersedia | **TERBANTAH** → ada, BE32 = 44.081,9 km |
| "Decode dua jalur" (pendek & panjang) | **TERBANTAH** → satu bentuk seragam per tipe |
| Auth content, checksum, LE header | **TERKONFIRMASI** |
| Mapping battery ft1/fb2 → ±88 V | **TERBANTAH** → fb=13 (11.3-14.8 V) |
| Mapping RPM fb=1 (≈1550 idle) | **TERKONFIRMASI** |
| 0xA6 struktur & checksum, datetime | **TERKONFIRMASI** (2 cmd 058A/058B, counter terbagi genap/ganjil) |
| 0xB4 di 0xA6 = konstanta | **TERKONFIRMASI (konstan)** — makna **BELUM JELAS** |
| 0x5B = serial terpotong `MH3SG6420MJ0283...` | → **UTUH `MH3SG6420MJ028368`** (VIN) |

## 10. IMPLIKASI UNTUK CLIENT KUSTOM
1. **Selalu reassemble L2CAP** (PB 00/10 start, PB 01 lanjut s/d `4+l2len`) sebelum parse ATT.
2. Checksum `(256 - sum[:n-1]) & 0xFF` **wajib diverifikasi** di RX → 100% di capture ini.
3. Numerik payload `0x55` = **BIG-ENDIAN**; header auth = LE; L2CAP len = LE.
4. Pakai `mapping-overrides.json` (aki fb 13). RPM/odo/suhu/baro sample mapping sudah benar.
5. Alur sesi minimum: ATT set-up → auth → StartProcessing → info dump (0x5B+0x59) →
   stream (0x55/0x56 @92 ms) dengan 0xA6 datetime tiap detik sebagai sinkronisasi jam.

## 11. OPEN ITEMS
- [ ] Makna `0xB4` di cmd `0x058A` (konstan 0xB4) — capture kedua / variasi timezone
- [ ] Penjabaran field halaman `0x59` (`ff60..ff73`) — perlu mapping vendor lengkap
- [ ] Definisi `0x56` (status CAN, 5 record kecil semuanya `00`) — verifikasi saat berkendara
- [ ] Apakah tanpa write `0xA6` (058A/058B) CCU tetap stream — uji berpasangan offline/read-only