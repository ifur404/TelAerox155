# Perekaman dan analisis perjalanan

Pilih **Data Sensor**, tentukan **Posisi iPhone**, lalu mulai rekaman. iOS meminta izin ketika
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

Sensor iPhone tetap direkam ketika BLE terputus, sementara kolom motor menjadi kosong. CSV lama
tetap dapat dibuka. Data yang tidak ada pada rekaman lama tidak ditampilkan sebagai pembacaan baru.

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
