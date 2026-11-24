# Perekaman dan analisis perjalanan

Pilih **Perjalanan** untuk merekam telemetri motor dan GPS. Toggle **Gerakan & barometer** hanya
mengatur akselerometer, giroskop, orientasi, dan barometer; GPS tetap direkam ketika toggle mati,
sesuai izin lokasi. Jika toggle aktif, tentukan **Posisi iPhone**. iOS meminta izin ketika
lokasi atau gerakan mulai digunakan. Sensor yang tidak tersedia atau izinnya ditolak tidak
menghentikan perekaman sumber lain.

## Isi CSV

CSV versi 2 menyimpan sekitar satu baris per detik.

| Sumber | Data yang direkam |
|---|---|
| ECU | Kolom telemetri yang kompatibel dengan CSV lama dan usia penerimaan tiap field melalui `ecu_<key>_age_s` |
| Lokasi iPhone | Koordinat, kecepatan, elevasi, akurasi horizontal/vertikal/kecepatan, course, usia fix, status izin, dan status lokasi presisi |
| Gerakan iPhone | Percepatan tanpa gravitasi, rata-rata XYZ, puncak dan RMS magnitude, puncak dan RMS vertikal, waktu, usia, jumlah sampel, dan rentang sampel |
| Orientasi iPhone | Gravitasi, rotasi, roll/pitch/yaw, dan quaternion; referensi orientasi `.xArbitraryZVertical` |
| Barometer | Tekanan, elevasi relatif, waktu, usia, dan status |
| Status iPhone | Baterai, status pengisian, mode hemat daya, kondisi termal, posisi ponsel, dan status foreground/background |
| Rekaman | Versi skema, waktu ISO, waktu berlalu, dan status BLE |

Nama dan urutan lengkap kolom ditentukan oleh `SessionRecorder.csvColumns`. Angka memakai titik
desimal. Kolom kosong berarti nilai tidak tersedia, tidak valid, atau sudah basi; kolom kosong bukan
nol.

Usia ECU dihitung dari penerimaan setiap field, termasuk saat nilainya tidak berubah. Field ECU
dinamis dikosongkan setelah 5 detik tanpa pembaruan; counter informasi kendaraan tetap tercatat
bersama usia penerimaannya. GPS dianggap basi setelah 5 detik, gerakan setelah 2 detik, dan
barometer setelah 5 detik. `motion_uptime_s` dan `barometer_uptime_s` menyimpan waktu monotonic
sensor sejak boot. Timestamp gerakan/barometer dikonversi ke jam kalender; timestamp GPS berasal
dari Core Location.

GPS dan sensor tambahan yang diaktifkan tetap direkam ketika BLE terputus, sementara kolom motor menjadi kosong. CSV lama
tetap dapat dibuka. Data yang tidak ada pada rekaman lama tidak ditampilkan sebagai pembacaan baru.

## Rekaman saat layar terkunci

Mulai rekaman ketika aplikasi masih terbuka, atau aktifkan **Hubungkan otomatis** dan **Rekam perjalanan otomatis** (keduanya nonaktif secara default).

- **Hubungkan otomatis** memakai `retrievePeripherals(withIdentifiers:)` dan permintaan pending `central.connect` CoreBluetooth tanpa memindai BLE terus-menerus, serta inisialisasi `CBCentralManager` sejak peluncuran aplikasi agar *State Restoration* dapat membangunkan app saat motor menyala. Menekan **Putuskan** / **Jeda** secara manual akan menjeda mode otomatis sementara hingga pengguna menekan **Hubungkan** lagi.
- **Rekam perjalanan otomatis** memulai rekaman **Perjalanan (CSV)** saat motor mencapai status `streaming` (mengikuti preferensi *Gerakan & barometer* dan *Posisi iPhone* terakhir), dan berhenti otomatis setelah motor terputus melewati jeda tunggu (*grace period* 1 / 2 / 5 menit, default 2 menit) sehingga GPS, akselerometer, barometer, dan timer langsung dimatikan. Menekan **Stop Rekam** manual tidak akan memicu mulai otomatis lagi pada sesi koneksi motor yang sama, dan rekaman yang dimulai manual tidak dihentikan oleh jeda putus BLE.
- **Potong otomatis saat tanpa aktivitas** menghentikan rekaman **Perjalanan (CSV)** secara otomatis apabila tidak ada aktivitas berkendara (kecepatan ECU `< 2 km/jam`, kecepatan GPS `< 3 km/jam`, perpindahan GPS di bawah ambang, bukaan gas `< 2°`, dan putaran mesin tidak di atas idle) melewati batas waktu yang dipilih (Mati / 3 / 5 / 10 menit, default 5 menit). Saat **Idling Stop (SSS)** terdeteksi di tengah perjalanan (motor sudah sempat jalan dan mesin hidup, lalu berhenti dengan RPM `0` sementara kunci kontak tetap ON dan BLE tersambung), pemotongan jangka pendek otomatis ditahan hingga batas pengaman **15 menit** dan langsung reset saat mesin menyala lagi atau gas dibuka, sehingga berhenti di lampu merah, macet, atau perlintasan kereta tidak memotong rekaman. Pada mode rekam otomatis saat motor masih terhubung, aplikasi masuk mode siaga dan otomatis memulai segmen rekaman baru begitu motor kembali bergerak. Frame BLE mentah tidak terpengaruh mekanisme ini.
- **Pembuangan rekaman terlalu singkat** menghapus file dan entri riwayat secara otomatis bila rekaman CSV berhenti dengan durasi efektif di bawah batas minimal yang dipilih (Mati / 30 detik / 1 / 2 menit, default 1 menit). Waktu tunggu pasif (jeda putus BLE atau jeda diam sebelum pemotongan otomatis) tidak dihitung ke durasi efektif, sehingga menyalakan kontak sebentar di garasi tidak memenuhi Riwayat. Saat menekan Stop manual pada rekaman yang masih di bawah batas minimal, dialog menawarkan **Stop & Buang** atau **Tetap Simpan**.
- **Batasan iOS:** Biarkan aplikasi di latar belakang (jangan di-*swipe kill* dari App Switcher agar restorasi BLE tetap aktif). Untuk merekam GPS secara otomatis ketika rekaman dimulai dari layar terkunci, iOS memerlukan izin lokasi **Selalu**; dengan izin **Saat Digunakan**, telemetri ECU motor tetap terekam penuh dari latar belakang sementara GPS mulai aktif saat aplikasi dibuka.

Untuk setiap rekaman CSV, GPS dimulai secara sinkron setelah file dan header siap; tidak menunggu tick timer atau antrean UI berikutnya.
Jika **Gerakan & barometer** dimatikan, sensor tersebut tidak dinyalakan dan kolomnya tidak disimpan.
Kolom GPS dan status perangkat tetap ada. BLE mentah tetap hanya merekam frame Bluetooth.

Keep-alive memakai satu jadwal monotonic yang dilayani oleh timer, callback BLE masuk, dan callback
kesiapan buffer tulis. Kebijakan yang dipilih tetap berlaku: `off` tidak menulis, `notifyOnly` hanya
058B, dan `full` mengirim 058A lalu 058B dengan jeda minimal 100 ms. Callback yang berdekatan tidak
menggandakan frame. Setelah suspend, jadwal melanjutkan frame berikutnya tanpa mengejar backlog.
Tidak ada jenis perintah kendaraan baru.

Watchdog streaming tidak memutus koneksi berdasarkan timer selama background; putus/sambung tetap
ditangani CoreBluetooth. Ketika aplikasi kembali ke foreground, watchdog mendapat tenggat baru.
Buffer file dan indeks di-flush saat aplikasi masuk background tanpa menghentikan sesi.

## Beban kerja saat merekam

- Timer sampling hanya hidup selama rekaman aktif. Timer, GPS, dan BLE berbagi gerbang monotonic
  sehingga callback yang bersamaan tidak menulis baris CSV ganda. Timer mengikuti tenggat berikutnya
  agar jitter tidak menyebabkan satu interval sampling terlewat.
- Dashboard menerima maksimal 4 pembaruan per detik ketika foreground. Paket terbaru tetap
  disimpan terpisah untuk CSV; pembatas UI tidak mengurangi data yang tersedia untuk rekaman.
  Pembaruan snapshot dashboard berhenti ketika background, dan clock usia sensor hanya aktif
  ketika dashboard live terlihat.
- Format hex dan redaksi frame hanya dikerjakan saat rekaman BLE mentah aktif. Seluruh frame RAW
  tetap ditulis, tetapi angka progres UI diperbarui maksimal sekali per detik (serta saat checkpoint
  dan stop). Batas ukuran dan indeks tetap memakai hitungan file sebenarnya.
- Watchdog streaming memperbarui tenggat aktivitas tanpa membuat timer baru untuk setiap paket.
  Keep-alive tetap memakai jadwal tunggal; kebijakan penuh memang mengirim dua frame berbeda,
  058A dan 058B, bukan pengiriman ganda frame yang sama.
- GPS tetap mengikuti rekaman perjalanan. Sensor gerakan/barometer hanya aktif ketika dipilih;
  frekuensi sensor dan akurasi GPS tidak diturunkan oleh optimasi ini.

Pemeriksaan otomatis memakai callback dan data buatan untuk memverifikasi batas pembaruan,
deduplikasi, serta keutuhan file. Penghematan CPU/baterai belum diukur pada iPhone fisik.

## Validasi perangkat

Validasi perangkat fisik tetap diperlukan: rekam minimal 5 menit dengan layar terkunci untuk CSV
dengan/tanpa gerakan dan barometer serta BLE mentah, lalu periksa timestamp serta jeda data. Ulangi dengan
izin lokasi ditolak dan motor terputus/tersambung ulang. Simulator tidak menguji koneksi CCU atau
kebijakan suspend iPhone. Force-quit atau terminasi proses tidak didukung sebagai rekaman kontinu.

## Halaman detail dan kejadian

Halaman detail menampilkan kualitas data motor/GPS/gerakan, bagian data yang hilang, grafik sensor,
status selama pemutaran ulang, baterai awal/akhir, profil elevasi terhadap jarak, estimasi
kemiringan pada ruas minimal 100 m, serta kejadian di daftar dan peta. Grafik dan rute dipisahkan
ketika ada jeda data.

Percepatan dan perlambatan dihitung dari perubahan kecepatan ECU atau GPS berkualitas baik, dengan
ambang awal ±2,5 m/s². Perlambatan adalah indikasi kemungkinan pengereman, bukan bukti tuas rem
ditekan.

Kejadian guncangan memerlukan puncak percepatan vertikal minimal 8 m/s² saat kecepatan minimal 10
km/jam, sedikitnya 10 sampel dalam jendela minimal 0,2 detik, dan usia data maksimal 0,2 detik.
Deteksi ini hanya aktif untuk posisi ponsel di holder. Kejadian serupa diberi jeda 10 detik. Peta
menampilkan hingga 30 kejadian terkuat dengan koordinat valid; daftar menampilkan hingga 50 kejadian
pertama per jenis.

## Batas interpretasi

Roll, pitch, dan yaw menggambarkan orientasi ponsel. Yaw relatif terhadap referensi arbitrer, bukan
arah kompas atau sudut rebah motor. Course GPS menggambarkan arah perjalanan. Guncangan juga dapat
dipengaruhi holder dan getaran mesin.

Barometer memberi elevasi relatif dan dipengaruhi tekanan udara. Estimasi naik/turun memakai ambang
simetris untuk mengurangi noise. Jika iPhone sedang diisi, perubahan baterai bukan ukuran konsumsi
murni. Semua metrik turunan memerlukan validasi lapangan.

iOS dapat menghentikan callback gerakan atau menunda penulisan saat aplikasi disuspend. GPS/BLE
dapat membantu aplikasi tetap mendapat waktu berjalan di latar belakang, tetapi tidak menjamin semua
sensor terus aktif. Jeda ditunjukkan melalui timestamp, usia sumber, jumlah sampel, dan bagian
kosong pada halaman detail.

Sebelum mengandalkan analisis gerakan, uji pada iPhone fisik saat layar terkunci, izin ditolak, BLE
terputus/tersambung ulang, serta ponsel berada di holder dan di saku.
