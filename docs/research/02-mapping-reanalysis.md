# Re-analisis mapping SCCU1 — dari kode APK + capture `Aerox-155.pklg`

> Latar belakang: `Sample_SCCU1_MappingFile.json` (dibundle di APK, di
> `resources/assets/jsons/`) **bukan mapping asli motor**. Dari kode app
> (`VehicleRepositoryDownloadExtKt$downloadAndSaveMcMappingFileToNative`),
> mapping asli per-kendaraan di-download dari S3 (`S3Object`) saat
> pairing/setup, lalu disimpan lokal. File yang ada di sini cuma
> sample/fallback yang dibundle di APK — itu kemungkinan besar penyebab
> beberapa faktor "kadang salah" (sudah terbukti untuk voltase aki, lihat
> `mapping-overrides.json` dan §3 di bawah). Tanpa akses ke S3 bucket asli,
> kita tidak bisa ambil mapping resmi motor ini — jadi source of truth kita
> tetap **derivasi empiris dari capture** (checksum + fisika), bukan sample.

## 1. Skema parser asli (dari kode, bukan tebakan)

Parser mapping ada di `p006c/d.java` (`setMappingFileFromJsonString`), field
di-parse ke `p009e/a.java` (`McMappingData`). Field WAJIB per record:

```
ServiceID (String), ItemName (String), StartByte (String, = frame type hex),
ID (String, hex), Length (Int, satuan BIT), ByteNo (Int), StartBit (Int),
Format (String), FactorTop (Number), FactorBottom (Number),
Offset (Number), Unit (String)
```

Catatan: `mapping-overrides.json` kita pakai nama field `SampleFactorTop`/
`OverrideFactorTop` — itu nama internal dokumen kita sendiri, BUKAN nama
field yang dibaca parser asli (`FactorTop`/`FactorBottom`). Jangan sampai
salah kira itu format mapping asli.

## 2. `ByteNo` = offset absolut dalam frame, BUKAN relatif ke record — TERKONFIRMASI

Dicek silang ke raw TLV hasil `dissect.py` untuk frame `0x55` dan `0x56`:

- `0x55`: record1 `{00 01}` (header 3B mulai byte[2]) → data mulai byte[5].
  `ByteNo=5` (RPM) match persis awal data. `ByteNo=41` (odometer, record2
  `{00 48}`) match persis awal data record2 (byte 2+3+33+3 = 41).
- `0x56` (contoh 30 B: `56 05 02 0a 02 00 00 02 16 04 00 00 00 00 02 3a 02
  00 00 02 3e 02 00 00 02 45 01 00 03 b0`): record `{02 3a}` data ada di
  byte[17..18], `ByteNo=18` (sample: `FI_warning_lamp`, Length=8bit=1B) tepat
  nunjuk byte[18] — byte kedua dari data 2-byte itu. Record `{02 3e}` data
  byte[22..23], `ByteNo=22` (`injection`, Length=16bit=2B) tepat match awal
  data. **Kesimpulan: `ByteNo` dihitung dari byte[0] frame utuh (termasuk
  byte type+count), bukan dari awal data record.** Ini penting buat siapa pun
  yang mau nulis decoder — jangan asumsikan ByteNo relatif ke record.

## 3. Field yang sekarang KETERBACA maknanya (sebelumnya "BELUM JELAS")

Dari capture `Aerox-155.pklg`, frame `0x5B` (info kendaraan):

| ID | raw | Sample mapping | Nilai |
|---|---|---|---|
| `{f1 a1}` | `00 54 07 d4` | `ECU総通電時間` (ECU total power-on time), UI32, unit `sec` | `0x005407D4` = 5.507.028 detik ≈ **63,7 hari** total ECU menyala seumur hidup |
| `{f1 a2}` | `1c 0c` | `IGN ON総回数` (total hitungan IGN ON), UI16, unit `回`(kali) | `0x1C0C` = **7.180 kali** kunci kontak ON |

### Validasi silang lapangan (dua log BLE nyata, bukan cuma satu capture)

Selain `Aerox-155.pklg`, dua sesi log diagnostik nyata dari app ini
(`docs/research/device-log-ble/1.txt` dan `2.txt`, di-export berurutan pada
motor yang sama) memberi titik data kedua dan ketiga untuk kedua field ini:

| Sumber | header "Dibuat" | `{f1 a1}` raw | detik | hari | `{f1 a2}` raw | IGN ON |
|---|---|---|---|---|---|---|
| `Aerox-155.pklg` | (capture lama, terpisah) | `00 54 07 D4` | 5.507.028 | 63,74 | `1C 0C` | 7.180 |
| `1.txt` | 2026-09-22T14:33:00Z | `00 54 24 09` | 5.514.249 | 63,82 | `1C 1F` | 7.199 |
| `2.txt` | 2026-09-22T14:38:32Z | `00 54 25 50` | 5.514.576 | 63,83 | `1C 20` | 7.200 |

Metode validasi:

- **`ecuPowerOnTime`** (faktor 1, offset 0, unit detik): selisih nilai raw
  antara `1.txt` dan `2.txt` adalah `5.514.576 − 5.514.249 = 327` detik.
  Selisih wall-clock antar dua header "Dibuat" adalah `14:38:32 − 14:33:00 =
  332` detik. Keduanya cocok dalam ~1,5% — counter di motor naik sesuai laju
  waktu nyata persis seperti prediksi faktor=1/offset=0, dan bedanya
  (5 detik) wajar karena sampel `{f1 a1}` diambil beberapa detik sebelum
  masing-masing log di-export, bukan tepat di momen "Dibuat". Ini adalah
  cross-check independen kedua (setelah struktur `ByteNo`) yang tidak
  bergantung pada `Sample_SCCU1_MappingFile.json`.
- **`ignOnCount`** (faktor 1, offset 0, unit kali): naik tepat **+1** dari
  `1.txt` ke `2.txt` (7.199 → 7.200) — konsisten dengan satu siklus kontak
  motor OFF→ON di antara dua sesi ujicoba tersebut (`1.txt` dan `2.txt` adalah
  dua percobaan connect terpisah pada motor yang sama).

Kredibilitas: **TINGGI** — struktur/lokasi field cocok 100% dengan skema
`ByteNo` absolut (§2), dan kini FactorTop/Offset juga tervalidasi silang ke
sumber independen kedua (dua log lapangan) selain `Aerox-155.pklg`, sejajar
dengan kasus RPM/odometer.

## 4. Frame `0x56` (CAN/status) — 2 dari 5 record kini punya nama, 3 masih kosong

| lid (ID) | ByteNo | Len | Sample mapping | Nilai raw contoh | Status |
|---|---|---|---|---|---|
| `02 0a` (`0x020A`) | 5 | 2B | **tidak ada di sample** | `00 00` | masih misteri |
| `02 16` (`0x0216`) | 10 | 4B | **tidak ada di sample** | `00 00 00 00` | masih misteri |
| `02 3a` (`0x023A`) | 18 | 1B (dari 2B data) | `FI_warning_lamp`, UI8 | `00` | **TERBACA** — 0 = tidak ada warning FI |
| `02 3e` (`0x023E`) | 22 | 2B | `injection`, D, ft=1/100, unit cc | `00 00` | **TERBACA** — 0 cc (idle, wajar) |
| `02 45` (`0x0245`) | 27 | 1B | **tidak ada di sample** | `00` | masih misteri |

Jadi sample mapping APK **tidak lengkap** untuk frame `0x56` — 3 dari 5
record ID (`0x020A`, `0x0216`, `0x0245`) tidak punya definisi sama sekali di
`Sample_SCCU1_MappingFile.json`. Semua bernilai `00` di capture ini karena
motor cuma idle diam — perlu capture saat jalan (rem/sein/gear) buat lihat
kapan nilainya berubah, baru bisa ditebak fungsinya dari korelasi.

## 5. Field yang TERBUKTI SALAH di sample (sudah dikonfirmasi sebelumnya)

- Voltase aki (`ByteNo=11`, `0x0001`): sample `FactorTop/Bottom = 1/2` →
  73,5–96V (mustahil fisik). Override empiris `1/13` → 11,3–14,8V (masuk akal
  untuk sistem 12V). Sudah tercatat di `mapping-overrides.json`.

## 6. Implikasi

1. **Jangan pakai `Sample_SCCU1_MappingFile.json` mentah-mentah** sebagai
   source of truth — itu fallback/dev sample, bukan mapping motor asli, dan
   sudah terbukti minimal 1 faktor salah + beberapa ID CAN tidak lengkap.
2. Struktur (`ByteNo` absolut, `Format`, urutan record TLV) tetap valid
   dipakai sebagai kerangka parsing karena sudah tervalidasi cross-check ke
   capture nyata (§2) — yang perlu dicurigai/diverifikasi ulang HANYA
   `FactorTop/FactorBottom/Offset` per field, bukan strukturnya.
3. Untuk field yang gak ada sama sekali di sample (`0x020A`, `0x0216`,
   `0x0245`, dan sisa field `0x5B` yang belum diidentifikasi:
   `{f1 94}`, `{f7 01}`), satu-satunya jalan adalah korelasi empiris dari
   capture baru (lihat rekomendasi eksperimen di diskusi sebelumnya) — tidak
   ada definisi resmi yang bisa digali dari APK ini untuk field-field
   tersebut.
4. Mapping resmi per-vehicle ada di S3 (lihat
   `VehicleRepositoryDownloadExtKt`), tapi butuh kredensial akun/API call
   yang di luar cakupan reverse-engineering statis — tidak dikejar di sini.
