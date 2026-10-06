# Analisis ulang mapping SCCU1

Dokumen ini merangkum pemeriksaan terhadap mapping contoh SCCU1 yang dibundel di APK dan struktur
TLV pada capture BLE. Nilai identitas kendaraan serta pembacaan telemetri dari capture pemilik tidak
disertakan.

## Ringkasan

Mapping contoh berguna untuk memahami nama field dan format data, tetapi tidak selalu lengkap atau
tepat untuk setiap kendaraan. Struktur frame dan offset telah dibandingkan dengan capture; faktor
skala tetap perlu divalidasi terhadap sumber lain atau data lapangan yang sudah disamarkan.

## Skema mapping

Parser aplikasi resmi membaca field berikut untuk setiap entri:

```text
ServiceID, ItemName, StartByte, ID, Length, ByteNo, StartBit,
Format, FactorTop, FactorBottom, Offset, Unit
```

`Length` dinyatakan dalam bit. Nilai setelah skala dihitung sebagai:

```text
nilai = raw × FactorTop / FactorBottom + Offset
```

Nama `SampleFactorTop` dan `OverrideFactorTop` yang dipakai dalam catatan override proyek adalah
label lokal, bukan nama field pada format mapping resmi.

## `ByteNo` adalah offset dari awal frame

Perbandingan urutan record TLV dengan mapping mendukung bahwa `ByteNo` dihitung dari byte pertama
frame lengkap, termasuk type dan jumlah record.

- Pada frame `0x55`, record `{00 01}` dimulai setelah dua byte awal frame dan header TLV tiga byte;
  data record dimulai di offset 5.
- Record `{00 48}` mengikuti data record pertama dan header TLV berikutnya; pada bentuk frame yang
  diamati, odometer dimulai di offset 41.
- Pada frame `0x56`, nilai `ByteNo` yang dipetakan menunjuk byte pada frame penuh, termasuk kasus
  ketika field berada pada byte kedua dari data record.

Karena offset bergantung pada susunan dan panjang record, parser perlu berjalan mengikuti panjang
TLV. Offset absolut dari satu bentuk frame tidak boleh diterapkan ke bentuk lain tanpa validasi.

## Field yang telah diperiksa

| Frame | Temuan | Status |
|---|---|---|
| `0x55` | Record mesin/diagnostik dan odometer; struktur TLV serta beberapa offset cocok dengan decoder | Struktur terkonfirmasi pada capture yang diperiksa |
| `0x56` | Lima record terlihat; dua memiliki definisi pada mapping contoh, tiga belum ditemukan | Definisi contoh tidak lengkap |
| `0x5B` | Terdapat field waktu operasi ECU dan hitungan IGN ON; kenaikan pada beberapa sampel terpisah sesuai interpretasi counter | Makna dan skala didukung silang, nilai sampel disamarkan |
| Tegangan baterai pada `0x55` | Faktor mapping contoh menghasilkan nilai di luar rentang yang masuk akal; faktor empiris yang diperiksa konsisten dengan sistem 12 V | Perlu override dan validasi ulang pada kendaraan lain |

Untuk data CAN yang belum memiliki definisi, nilai konstan pada satu capture tidak cukup untuk
mengidentifikasi fungsi. Perubahan perlu dibandingkan dengan kondisi yang diketahui pada sesi uji
yang aman.

## Implikasi untuk decoder

1. Perlakukan mapping contoh sebagai referensi awal, bukan sumber kebenaran per kendaraan.
2. Validasi checksum dan panjang frame sebelum membaca field.
3. Walk record TLV sesuai length byte; hindari asumsi satu offset tetap untuk semua frame.
4. Pertahankan `ByteNo` terhadap frame penuh dan periksa `StartBit`/`Length` sesuai format.
5. Validasi faktor dan offset menggunakan beberapa sampel independen serta satuan fisik yang masuk
   akal.
6. Tandai field tanpa definisi sebagai belum diketahui, alih-alih menebak dari satu nilai.

Mapping resmi per kendaraan dilaporkan diunduh aplikasi resmi dari layanan Yamaha. Akses dan respons
layanan tersebut tidak diverifikasi oleh catatan ini.
