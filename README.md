# TelAerox155

Aplikasi iOS (SwiftUI) untuk membaca telemetri motor Yamaha (CCU SCCU1 / Y-Connect)
lewat Bluetooth LE — read-only, tanpa mengirim perintah kontrol kendaraan.

## Struktur

- `TelAerox155/` — target aplikasi utama.
  - `ContentView.swift` — UI utama (status koneksi, daftar perangkat, telemetri).
  - `TelemetryStore.swift` — `ObservableObject` (`@MainActor`) yang menjembatani
    `YConnectClient` ke SwiftUI: state koneksi, snapshot telemetri, daftar
    perangkat yang terlihat saat scanning, dan trace tahap auth.
  - `SessionRecorder.swift` — rekaman data sensor (CSV) atau frame BLE mentah
    (TXT, kredensial/VIN disensor), tersimpan di riwayat untuk dibagikan/dihapus.
  - `PhoneSensorProvider.swift` — sensor gerakan 50 Hz, barometer, dan status
    baterai iPhone; aktif hanya selama rekaman CSV.
  - `PhoneSensorSample.swift` — agregasi gerakan per jendela tanpa buffer
    yang membesar; puncak dan RMS tetap tersimpan di CSV 1 Hz.
  - `TripAnalysis.swift` / `TripPhoneAnalysis.swift` — pembacaan CSV lama/baru,
    kualitas data, kejadian perjalanan, rute, dan estimasi elevasi.
  - `YConnectKit/` — modul BLE murni, tanpa dependensi SwiftUI:
    - `YConnectClient.swift` — client CoreBluetooth: scan, connect, auth, keep-alive.
    - `Frame.swift`, `PeriodicFrame.swift` — encoding/decoding frame protokol CCU.
    - `AuthFrame.swift` — frame autentikasi (0xAA/0x5A).
    - `BinaryReader.swift` — helper baca byte stream.
    - `Checksum.swift` — checksum frame.
    - `Mapping.swift` — mapping field frame → nilai telemetri.
    - `TelemetryDecoder.swift` — decode payload frame jadi `TelemetrySnapshot`.
    - `BLELogFormat.swift` — arah log dan format hex untuk rekaman BLE mentah.

## Kontrak keamanan

Byte yang ditulis ke motor **hanya** frame auth (`0xAA`) dan, tergantung
`KeepAlivePolicy`, frame periodik `0xA6` (058A/058B) — identik dengan yang
dikirim aplikasi resmi Yamaha Motor On. Tidak ada write lain (tidak ada
request FFD, tidak ada kontrol kendaraan).

## Build

Buka `TelAerox155.xcodeproj` di Xcode dan jalankan target `TelAerox155` di
simulator atau perangkat iOS (Bluetooth memerlukan perangkat fisik untuk
pengujian penuh).

## Rekaman motor + iPhone

Pilih **Data Sensor**, tentukan **Posisi iPhone**, lalu mulai rekaman. Izin
lokasi dan gerakan diminta iOS saat sensor mulai digunakan. Sensor yang
tidak tersedia atau ditolak tidak menghalangi rekaman sumber lainnya.

CSV versi 2 menyimpan satu baris sekitar setiap detik:

| Sumber | Kolom / satuan |
| --- | --- |
| ECU | Kolom telemetri lama; `ecu_<key>_age_s` mencatat usia penerimaan setiap field secara terpisah |
| Lokasi iPhone | `gps_lat`, `gps_lon`, `gps_speed_kmh`, `gps_alt_m`, `gps_accuracy_m`; timestamp asli, umur fix, akurasi vertikal (m), akurasi kecepatan (m/s), course dan akurasinya (°), status izin dan lokasi presisi |
| Device motion | Percepatan X/Y/Z tanpa gravitasi (m/s²), rata-rata XYZ, puncak magnitude dan RMS, puncak vertikal dan RMS vertikal; timestamp, usia, jumlah sampel dan rentang waktunya |
| Orientasi HP | Gravitasi XYZ (g), rotasi XYZ (rad/s), roll/pitch/yaw (°), quaternion WXYZ; referensi `.xArbitraryZVertical` |
| Barometer | `phone_pressure_kpa`, `phone_relative_alt_m`, timestamp, usia dan status |
| Status iPhone | Baterai (%), pengisian, mode hemat daya, kondisi termal, posisi HP, foreground/background |
| Rekaman | `schema_version`, `timestamp_iso`, `elapsed_s`, `ble_state` |

Urutan lengkap kolom ada di `SessionRecorder.csvColumns`. Angka memakai titik
desimal; field kosong berarti tidak tersedia/invalid/basi, **bukan nol**.
Usia ECU dihitung dari penerimaan masing-masing field, termasuk jika nilainya
tidak berubah. Field dinamis ECU basi setelah 5 detik dan dikosongkan; counter
info kendaraan tetap disimpan selama streaming dengan usia penerimaannya.
GPS basi setelah 5 detik, motion setelah 2 detik, dan barometer setelah 5 detik.
`motion_uptime_s` dan `barometer_uptime_s` menyimpan timestamp monotonic asli
sensor (detik sejak boot); timestamp ISO sensor gerakan/barometer merupakan
konversi ke jam kalender, sedangkan timestamp GPS berasal dari Core Location.
Data iPhone tetap direkam saat BLE terputus, dengan kolom motor kosong.

Halaman detail menampilkan kualitas motor/GPS/motion, bagian data yang hilang,
grafik sensor, status saat replay, baterai awal/akhir, profil elevasi terhadap
jarak, estimasi kemiringan pada ruas ≥100 m, serta kejadian di daftar dan peta.
CSV lama tetap dapat dibuka; informasi yang belum dicatat tidak ditampilkan
sebagai pembacaan baru. Rute/grafik dipisah pada bagian yang datanya hilang.

Percepatan/perlambatan dihitung dari perubahan kecepatan ECU atau GPS berkualitas
baik, dengan ambang awal ±2,5 m/s². Perlambatan merupakan dugaan pengereman,
bukan bukti tuas rem ditekan. Kejadian guncangan memakai puncak percepatan
vertikal ≥8 m/s² saat melaju ≥10 km/h, minimal 10 sampel dalam jendela ≥0,2 s
dan usia ≤0,2 s, hanya untuk posisi holder. Kejadian sejenis diberi jeda 10 s.
Peta menampilkan maksimal 30 kejadian terkuat yang punya koordinat valid;
daftar menampilkan maksimal 50 kejadian pertama per jenis.

Roll/pitch/yaw adalah orientasi **HP** dan yaw relatif referensi arbitrer,
bukan arah kompas atau sudut rebah motor. Course GPS adalah arah perjalanan.
Guncangan dapat dipengaruhi holder/getaran mesin. Barometer memberikan elevasi
relatif dan dipengaruhi tekanan udara; estimasi naik/turun memakai ambang
simetris untuk mengurangi noise. Jika ada pengisian, perubahan baterai bukan
ukuran konsumsi murni. Semua hasil turunan ini masih perlu validasi lapangan.

iOS dapat menghentikan callback gerakan atau menunda penulisan ketika aplikasi
disuspend. GPS/BLE membantu aplikasi mendapat waktu berjalan di background,
tetapi tidak menjamin semua sensor aktif terus. Jeda dicatat lewat timestamp,
usia sumber, jumlah sampel dan bagian kosong pada detail. Uji di iPhone fisik
dengan layar dikunci, izin ditolak, BLE terputus/tersambung ulang, dan HP di
holder maupun saku sebelum menggunakan analisis gerakan untuk kesimpulan.

Pemeriksaan regresi dengan data buatan (tanpa kredensial):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/run.sh
```

Pemeriksaan ini mencakup ekspor CSV, usia per field, kompatibilitas CSV lama,
agregasi gerakan, GPS berulang, jeda rekaman, deteksi kejadian, elevasi,
serta downsampling rute panjang. Tidak menulis ke Documents pengguna.

## Kredensial

`TelAerox155/secrets.local.json` (kalau ada) berisi kredensial motor lokal dan
sudah di-`.gitignore` — jangan pernah di-commit atau dibagikan.

Alur pairing di aplikasi:

1. Tekan **Pairing**, lalu pilih motor dari daftar Bluetooth sekitar.
2. Pilih **QR** dan scan QR bawaan motor atau tempel payload-nya.
3. Tekan **Coba hubungkan**. QR harus cocok dengan CCUID motor yang dipilih.
4. Setelah motor menerima auth (`0x5A` accepted), aplikasi membuat
   `Application Support/Pairing/secrets.local.json` dan menampilkan berhasil paired.
5. Koneksi berikutnya memakai file tersebut; pengguna tidak perlu menyediakan JSON.

File dibuat di penyimpanan privat aplikasi, bukan folder rekaman yang terlihat
di Files. File menggunakan proteksi iOS sampai perangkat dibuka pertama kali
setelah restart dan direktori dikecualikan dari backup. Format kredensial tetap
kompatibel dengan `Credentials`, ditambah identifier Bluetooth dan waktu pairing.

QR salah motor, penolakan auth, timeout, atau pembatalan tidak membuat pairing
baru dan tidak menimpa pairing lama. **Lupakan motor tersimpan** menghapus file
setelah konfirmasi. Alur impor JSON/penyimpanan sebelum auth telah dihapus.

Pilihan **4 digit rangka** ditampilkan, tetapi **belum dapat menghubungkan**:
APK resmi mengambil VIN dan passKey melalui layanan Yamaha dengan token sesi.
Integrasi login Yamaha belum tersedia; empat digit tidak dikirim sebagai
passKey BLE. Pilihan ini dijelaskan secara eksplisit di layar dan tombol
connect-nya belum diaktifkan.

Build dan pemeriksaan sintetis tidak membuktikan pairing nyata. Scanner,
persistensi setelah auth, dan koneksi ulang masih perlu diuji di iPhone dengan
QR dan motor sendiri. Lihat [rencana pairing](docs/research/03-auth-pairing-input.md)
dan [bukti analisis APK](docs/research/04-apk-qr-pairing.md).
