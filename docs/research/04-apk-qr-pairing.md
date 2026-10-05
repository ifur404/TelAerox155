# Pairing QR dan potongan VIN — pemeriksaan lanjutan 2026-10-05

Dokumen ini menyimpan bukti teknis analisis statis. Status implementasi dan
urutan validasi berikutnya ada di [rencana pairing](03-auth-pairing-input.md).
Scanner Bluetooth/QR dan penyimpanan file setelah auth kini diimplementasikan,
tetapi belum diuji dengan QR/motor asli. Login Yamaha belum diimplementasikan.

## Kesimpulan

**Koreksi riset sebelumnya:** pada jalur `pairingCcuCodeScan`, QR bukan sekadar
pengisi VIN. Payload 24 karakter dipermutasi lokal, dicocokkan dengan CCU,
lalu enam karakter diambil sebagai `passKey`. Jalur input VIN yang diperiksa
memakai REST `pairing_info/{vinCode}`, bukan langsung mutation GraphQL.

Ini membuktikan adanya jalur ekstraksi kredensial QR di kode yang diperiksa.
Belum membuktikan bahwa stiker motor pengguna memakai format tersebut atau
bahwa seluruh onboarding aplikasi resmi dapat berjalan offline.

## Sumber dan batas verifikasi

- APK lokal: `/Users/rupi/Downloads/YamahaMotorOn_1.0.14.apk`.
- SHA-256: `28f1bc0c20164e917bdbcf81e3ca97d6cc5c6a169fc596ae5c2f93a693f04676`.
- Pembacaan Java memakai hasil decompile yang sudah tersedia di
  `/Users/rupi/Downloads/YamahaMotorOn_1.0.14.apk_Decompiler.com/sources/`.
  Semua referensi sumber di bawah relatif terhadap direktori tersebut.
- Pemeriksaan langsung arsip APK mengonfirmasi nama kelas QR, konstanta
  `REVERSED_MAP_POSITIONS`/`PASS_KEY_LENGTH`, dan `pairing_info/{vinCode}`
  di `classes3.dex`, serta `jwtKey` di `classes2.dex`.
- Ini bukan decompile ulang: kesamaan byte seluruh hasil decompile dengan APK
  belum diverifikasi. Bukti algoritma di bawah berasal dari Java tersebut;
  keberadaan identifier dalam DEX hanya bukti pendukung.
- Tidak membaca `secrets.local.json`, mengirim data ke server, login akun,
  atau melakukan koneksi/write BLE.

## 1. QR CCU: ekstraksi lokal

Sumber utama:

- `com/jp/yamaha/yconnect/feature_pairing/domain/PairingDLUseCase.java:16`.
- `com/jp/yamaha/yconnect/feature_pairing/ui/screen/pairingCcuCodeScan/A0302ScanCCUIdViewModel$handleOnQrCodeScanned$1.java:65-96`.
- `com/jp/yamaha/yconnect/feature_pairing/data/model/ExploredVehicleUIModel.java:59-83`.

Aturan yang terbaca:

1. Panjang payload harus tepat 24 karakter.
2. Susun ulang karakter menggunakan urutan posisi sumber berikut (indeks 1):

   ```text
   8,15,21,1,13,18,7,23,3,14,11,2,17,20,9,22,24,6,16,4,10,19,5,12
   ```

3. Hasil decoding harus diawali `ccuId.take(14)` dari kendaraan yang dipilih.
4. `decoded.drop(14).take(6)` menjadi `passKey`.
5. Hasil disalin ke field `passKey` pada `ExploredVehicleUIModel`, kemudian
   navigasi ke tahap download info kendaraan.

Representasi hasil (indeks nol):

| Posisi | Pemakaian pada handler ini |
|---|---|
| `[0:14]` | Pembanding identitas CCU |
| `[14:20]` | `passKey`, enam karakter |
| `[20:24]` | Tidak dipakai oleh handler; maknanya belum diketahui |

Semantik helper obfuscated diverifikasi di `kotlin/text/StringsKt.java`:
`Q` = startsWith (baris 262), `Z` = take (355), `q` = drop (671).
Handler tidak memvalidasi bahwa keenam karakter passKey numerik; jangan
menyimpulkan aturan digit hanya dari panjangnya.

Pemeriksaan sintetis: mapping mempunyai tepat 24 posisi unik di kedua sisi,
round-trip permutasi berhasil, dan batas field 14/6/4 sesuai. Ini hanya
pemeriksaan konsistensi, bukan validasi dengan QR asli atau keberhasilan auth.

## 2. Input manual: empat karakter sebagai pemeriksaan lokal

Sumber:
`com/jp/yamaha/yconnect/feature_pairing/ui/screen/pairingVinInput/A0301PairingVINInputViewModel$handleAuthenticateVinCode$1.java:315-356`.

Input pengguna (daftar karakter, masing-masing di-trim) dibandingkan dengan:

```text
VIN.dropLast(2).takeLast(4)
```

Jadi bukan empat karakter paling akhir: dua karakter paling belakang
dilewati dahulu. VIN lengkap sudah ada di state dari `ExploredVehicleUIModel`
(`A0301PairingVINInputViewModel.java`, konstruktor). Asal VIN sebelum layar
ini telah ditelusuri pada [request Yamaha](05-yamaha-pairing-requests.md):
berasal dari `model_info/{ccuId}` → `vehicleInfo.vinCd`. Empat karakter input
tidak menentukan VIN lengkap secara mandiri.

Jika cocok dan ada internet, app memanggil `UserVehicleRepository.b(VIN)`
dengan **VIN lengkap**, bukan empat karakter input.

## 3. Jalur REST untuk mengambil passKey

- `feature_pairing/data/repository/UserVehicleRepositoryImpl.java:100-200`
  (di bawah prefix `com/jp/yamaha/yconnect/`) menampilkan instruction dump
  `fetchAndSavePassKey`: panggil `GlocalPairingDataSource.e`, baca `ccuId` dan
  `passKey`, simpan lokal, lalu kembalikan `passKey`.
- `feature_pairing/data/source/GlocalPairingDataSource.java:32-33`:
  `GET pairing_info/{vinCode}`.
- `core/di/NetworkModule_ProvideGlocalRetrofitFactory.java:17`:
  base URL yang tertanam adalah `https://glocal-eu.yamaha-motorcycle-connect.com/`.
- `core/data/source/network/aws/glocal/GLocalRestApiInterceptor.java:25-28,70-71`:
  header `jwtKey` dari sesi, serta `header_appli_id: 0000`.
- `GLocalRestApiInterceptor$intercept$jwtToken$1.java` mengambil
  `getValidSessionToken(...).getJwtToken()`; token kosong menimbulkan error.

Endpoint dan header adalah temuan statis versi APK ini, bukan konfirmasi
layanan saat ini atau izin akses tanpa akun. Alur login/refresh lintas iOS
belum dipetakan tuntas dan belum dicoba. GraphQL juga ada dalam aplikasi,
tetapi keberadaannya tidak membuktikan semua jalur pairing melewatinya.
Respons server berisi passKey tidak membuktikan cara server menghitungnya.

## 4. Implikasi untuk TelAerox155

Alur yang diimplementasikan: scan BLE → pilih motor → decode QR dan cocokkan
CCU → coba auth → setelah 0x5A accepted, buat file privat secrets.local.json.
Pilihan perangkat saja atau QR valid belum menandai motor paired. File lama
tetap tersimpan jika percobaan baru gagal. Belum ada uji perilaku motor nyata.

Sebelum menyatakan pairing teruji, validasi satu QR milik pengguna secara lokal,
tanpa mencetak payload/passKey ke log. Pastikan bagian CCU cocok dengan
normalisasi nama BLE yang dipakai client. Makna empat karakter sisa,
kompatibilitas stiker, dan penerimaan kredensial oleh CCU masih terbuka.

Untuk jalur manual diperlukan penelusuran asal VIN lengkap dan login sesi
Yamaha. Empat karakter input bukan pengganti passKey secara langsung.
Penambahan onboarding tidak membutuhkan write kendaraan baru: kontrak auth
dan keep-alive di `AGENTS.md` tetap berlaku.
