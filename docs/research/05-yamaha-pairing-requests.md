# Analisis request Yamaha untuk pairing empat digit

Status catatan: 2026-10-05.

## Hasil dan batas pembuktian

Jalur request telah dipetakan dari hasil decompile APK 1.0.14. Client Swift `YamahaPairingAPI`
membentuk request GET dan memvalidasi responsnya. Tes request/response dengan server serta ACK BLE
simulasi menghasilkan file `secrets.local.json` yang kompatibel dengan `Credentials`.

**Belum diuji live:** belum ada sesi akun Yamaha yang diperoleh melalui login pengguna. Login UI,
refresh sesi native, dan percobaan layanan Yamaha/motor nyata belum selesai. Tombol empat digit di
aplikasi tetap belum diaktifkan. Tes simulasi tidak membuktikan endpoint masih menerima request di
produksi.

Sumber Java berada di direktori `sources` hasil decompile lokal yang dicatat beserta batas
provenance pada [dokumen 04](04-apk-qr-pairing.md). Path singkat `core/...` dan
`feature_pairing/...` di bawah memakai prefix `com/jp/yamaha/yconnect/`. Tidak membaca atau mengirim
`secrets.local.json` pengguna dalam analisis atau tes ini.

## 1. Login dan asal jwtKey

| Tahap | Bukti kode |
|---|---|
| Konfigurasi identitas | `core/data/source/network/sap/GigyaManager.java` dan `core/di/NetworkModule_ProvideGigyaAccountFactory.java`: public site API key APK, datacenter `eu1.gigya.com` |
| Layar login | `core/domain/AuthenticateUseCaseImpl.java:129`: screen set `Standard-3.0-RegistrationLogin` |
| Parameter UI | `core/data/repository/AuthRepositoryImpl.java:236-241`: `deviceType=auto`, bahasa dari resource `gigya_lang_code` |
| Mendapat JWT | `core/data/source/network/sap/GigyaDataSourceImpl.java:364-382`: `accounts.getJWT`, parameter `expiration`, baca respons `id_token` |
| Masa berlaku yang diminta | `core/data/source/network/aws/TokenSessionHelperImpl.java:984-1005`: `expiration=1800` detik |
| Refresh | Kelas yang sama, `jwtTokenExpired`: refresh window 600 detik sebelum expiry lokal |
| REST Yamaha | `core/data/source/network/aws/glocal/GLocalRestApiInterceptor.java:25-28,70-71`: `jwtKey=<id_token>`, `header_appli_id=0000` |

Token ini bukan passKey motor dan bukan AWS access key. Alur Cognito/GraphQL juga ada, tetapi
interceptor REST yang diperiksa memasang JWT Gigya langsung. Public site API key saja bukan sesi
login pengguna.

### Bentuk request getJWT dari SDK Android

`com/gigya/android/sdk/api/GigyaApiRequestFactory.java` menetapkan POST (default),
`sdk=Android_7.4.0`, `targetEnv=mobile`, `httpStatusCodes=false`, `format=json`, API key aplikasi,
nonce, serta gmid/ucid jika tersedia. Header `apikey` juga diisi. Ketika sesi valid, SDK menambahkan
`oauth_token` dan tanda tangan memakai session secret pengguna; ini bukan secret statis APK.

`com/gigya/android/sdk/utils/UrlUtils.java:getBaseUrl` menggabungkan namespace API dan datacenter
sehingga endpoint menjadi:

```text
POST https://accounts.eu1.gigya.com/accounts.getJWT
Content-Type: application/x-www-form-urlencoded

expiration=1800&...parameter SDK...&oauth_token=<sessionToken>&timestamp=<seconds>&sig=<signature>
```

`AuthUtils.java` menambahkan timestamp dengan offset waktu server. `SigUtils.java` pada hasil
decompile memperlihatkan HMAC-SHA1, tetapi body `getSignature` tidak terbaca. Metode itu kemudian
diperiksa melalui [sumber resmi SAP
SigUtils](https://github.com/SAP/gigya-android-sdk/blob/main/sdk-core/src/main/java/com/gigya/android/sdk/utils/SigUtils.java).
Sumber `main` ini bukti SDK upstream, bukan verifikasi byte-for-byte metode APK.

Canonical string:

```text
POST & percentEncode(normalizedURL) & percentEncode(sortedEncodedParameters)
```

URL dinormalisasi menjadi scheme/host lowercase, port non-default jika ada, dan path (tanpa query).
Parameter diurutkan menurut nama; value di-encode sebagai UTF-8 percent encoding (`%20` untuk
spasi). Signature menggunakan `HMAC-SHA1(base64Decode(sessionSecret), canonicalString)`, lalu base64
URL-safe (dengan padding, tanpa newline). Signature dimasukkan sebagai field `sig`.

`GigyaJWTRequest` kini membentuk request sesuai mekanisme tersebut. Vektor sintetis dibandingkan
dengan perhitungan independen Python HMAC, termasuk karakter spasi, plus, dan slash. Parser menolak
`errorCode` nonzero meskipun HTTP 200. **Tidak ada sesi/token pengguna yang dicetak atau
digunakan.** Builder ini membutuhkan `sessionToken` dan `sessionSecret` dari login sah; belum ada UI
login yang memperoleh keduanya, dan belum ada uji getJWT live.

Dokumentasi primer SAP juga menyatakan `accounts.getJWT` menghasilkan `id_token` dari sesi aktif:
[accounts.getJWT](https://help.sap.com/docs/SAP_CUSTOMER_DATA_CLOUD/8b8d6fffe113457094a17701f63e3d6a/413523ec70b21014bbc5a10ce4041860.html).
Ini mendukung kebutuhan sesi, bukan bukti login Yamaha kita sudah bekerja.

## 2. CCUID dari BLE menjadi VIN lengkap

`feature_pairing/data/source/GlocalPairingDataSource.java` mendefinisikan:

```text
GET https://glocal-eu.yamaha-motorcycle-connect.com/model_info/<selectedCCUID>
jwtKey: <id_token sesi pengguna>
header_appli_id: 0000
```

Field yang dipakai untuk VIN:

```json
{"vehicleInfo":{"vinCd":"<VIN lengkap>"}}
```

Ini subset skema, bukan capture respons nyata. `VehicleInfoResponse.java` → `VehicleInfo.java`
mendefinisikan field tersebut. `DeviceSearchUseCase$checkPairingVehicle$1$modelInfo$1.java`
memanggil repository `d(ccuId)` yang meneruskan ke endpoint model info. Handler `$modelInfo$3.java`
memindahkan `vehicleInfo.getVinCd()` ke `ExploredVehicleUIModel`.

App resmi juga memakai `GET /sccu_check_availability/{ccuId}` dan `GET connect_id_vin/{ccuId}` dalam
pencarian kendaraan. Yang terakhir digunakan untuk connectId dalam handler yang diperiksa. Client
bukti kita hanya menguji subset pembacaan VIN/passKey, bukan semua pemeriksaan registrasi akun
resmi. Tidak menjalankan mutation GraphQL atau `PUT gen2_use_start`.

## 3. Empat digit adalah verifikasi lokal

`A0301PairingVINInputViewModel$handleAuthenticateVinCode$1.java:325-348`:

```text
trim setiap karakter input
expected = VIN.dropLast(2).takeLast(4)
jika tidak cocok: tampilkan kesalahan, jangan fetch passKey
jika cocok dan ada internet: fetchAndSavePassKey(VIN lengkap)
```

Empat digit itu tidak dikirim sebagai password BLE atau sebagai pengganti VIN pada endpoint.
`phoneUUID` dibuat sendiri dan dipertahankan saat koneksi ulang; passKey tetap harus berasal dari QR
atau respons Yamaha.

## 4. Request passKey dan pengecekan kecocokan

```text
GET https://glocal-eu.yamaha-motorcycle-connect.com/pairing_info/<fullVIN>
jwtKey: <id_token sesi pengguna>
header_appli_id: 0000
```

Skema respons `VehiclePairingInformationResponse.java`:

```json
{"ccuId":"<14 karakter>","passKey":"<6 karakter>"}
```

`UserVehicleRepositoryImpl.java:135-169` mengambil respons, menulis cache
`pairing/info/tmp/{ccuId}/passKey.txt`, lalu mengembalikan passKey. Tidak ada bukti dari kode ini
bahwa empat digit dapat diolah lokal menjadi passKey.

Client Swift yang dibuat memeriksa `ccuId` respons sama dengan CCU terpilih, memvalidasi kredensial,
dan hanya mengembalikan kandidat di memori. Token hanya dipasang di header, request tidak di-cache,
redirect ditolak, dan pesan error tidak memuat body/token/VIN. Penanganan HTTP 401/403/404/429/5xx
merupakan perilaku defensif client kita, bukan hasil capture server nyata.

## 5. Tes membuat secrets.local.json

Jalankan dari root repo:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/run-yamaha-pairing.sh
```

Script mencetak hasil tiap pemeriksaan dan path direktori output baru di tmp. File sintetis tetap
tersedia di `manual-success/secrets.local.json` dan `qr-success/secrets.local.json` untuk diperiksa;
tidak ada kredensial pengguna. `Tests/run.sh` juga menjalankan suite ini dengan output sementara
yang dibersihkan.

Suite memakai request builder, decoder, pembangun frame auth, `PairingConfirmation`, dan penulis
file **yang sama dengan kode aplikasi**. `PairingConfirmation` kini menerima balasan auth asli
melalui delegate BLE; state `.streaming` sendiri tidak lagi menjadi pemicu penulisan file.

34 pemeriksaan mencakup urutan GET dan header, hasil file untuk QR dan empat digit, kompatibilitas
format, tidak ada file sebelum ACK, ECU berbeda, ACK rusak/ditolak/duplikat, cancel/timeout, file
lama tetap utuh, kegagalan simpan, HTTP gagal, kode salah, belum login, respons salah ECU, JSON
rusak, jaringan putus, serta sesi habis pada request kedua. Empat pemeriksaan tambahan memverifikasi
signing getJWT, ekstraksi id_token, sesi kosong, dan errorCode Gigya.

Hasil: suite lolos dan build simulator berhasil. Satu warning tooling AppIntents muncul karena tidak
ada dependency AppIntents; tidak ada error build. Radio BLE, login akun nyata, kebijakan server
Yamaha, dan kecocokan QR asli belum diuji oleh suite ini.
