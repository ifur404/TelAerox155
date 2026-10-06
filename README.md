# TelAerox155

Aplikasi iOS berbasis SwiftUI untuk membaca telemetri Yamaha Aerox melalui Bluetooth LE. Proyek ini
tidak berafiliasi dengan Yamaha.

Aplikasi ini bersifat **read-only untuk fungsi kendaraan**. Komunikasi tulis dibatasi pada
autentikasi BLE dan keep-alive periodik yang ditetapkan oleh `KeepAlivePolicy`. Tidak ada permintaan
diagnostik atau perintah kontrol kendaraan.

## Fitur

- Menemukan dan menghubungkan CCU melalui Bluetooth LE.
- Menampilkan telemetri yang dikirim CCU, termasuk RPM, kecepatan, suhu, tegangan, odometer, dan
  status diagnostik yang tersedia.
- Memasangkan CCU melalui QR dan menyimpan kredensial di penyimpanan privat aplikasi setelah
  autentikasi diterima.
- Merekam telemetri motor dan sensor iPhone ke CSV, lalu meninjau grafik, kualitas data, dan
  kejadian perjalanan.
- Mengekspor log BLE untuk diagnosis dengan penyensoran informasi sensitif.

Dukungan input empat digit rangka tersedia di antarmuka, tetapi belum dapat menyelesaikan pairing
karena integrasi login Yamaha belum tersedia.

## Memulai

1. Buka `TelAerox155.xcodeproj` di Xcode.
2. Pilih target `TelAerox155` dan jalankan di perangkat iOS.
3. Berikan izin Bluetooth, kamera saat memindai QR, serta lokasi dan gerakan bila merekam sensor
   iPhone.

Project menargetkan iOS 27 atau lebih baru. Bluetooth memerlukan iPhone dan CCU fisik untuk uji
koneksi. Simulator hanya dapat digunakan untuk bagian aplikasi yang tidak bergantung pada radio atau
sensor perangkat.

## Struktur aplikasi

`YConnectKit/` menangani protokol BLE secara terpisah dari SwiftUI. `TelemetryStore` menghubungkan
client BLE ke antarmuka, sedangkan pencatatan dan analisis perjalanan berada di lapisan aplikasi.

## Privasi dan keamanan

Kredensial pairing disimpan di direktori privat aplikasi dan tidak dimasukkan ke rekaman CSV. Jangan
menambahkan kredensial, QR pairing, VIN, atau capture BLE mentah ke commit publik. File
`secrets.local.json` lokal diabaikan Git.

Baca [kontrak keamanan untuk kontributor](AGENTS.md) sebelum mengubah komunikasi BLE. Ringkasan
protokol menjelaskan batas frame yang diizinkan dan temuan riset yang telah disamarkan.

## Dokumentasi

- [Pusat dokumentasi](docs/README.md)
- [Perekaman dan analisis perjalanan](docs/recording-and-analysis.md)
- [Ringkasan protokol BLE](docs/research/findings.md)
- [Analisis capture protokol](docs/research/capture-findings.md)
- [Analisis mapping telemetri](docs/research/02-mapping-reanalysis.md)
- [Status pairing QR dan input rangka](docs/research/03-auth-pairing-input.md)
- [Analisis statis pairing aplikasi resmi](docs/research/04-apk-qr-pairing.md)
- [Analisis request pairing Yamaha](docs/research/05-yamaha-pairing-requests.md)

Dokumen riset bersifat informatif. Temuan dari analisis APK atau capture tidak menjamin layanan
Yamaha masih sama, kecocokan untuk semua model, atau keberhasilan pairing pada kendaraan lain.

## Pemeriksaan lokal

Pemeriksaan regresi memakai data sintetis dan tidak menulis ke Documents pengguna:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/run.sh
```

Untuk pemeriksaan alur pairing dengan respons simulasi:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/run-yamaha-pairing.sh
```

Kedua pemeriksaan tidak menggantikan build Xcode pada perangkat atau pengujian dengan CCU nyata.
