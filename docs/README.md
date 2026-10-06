# Dokumentasi

Dokumentasi proyek dibagi menjadi panduan penggunaan dan catatan riset protokol.

## Panduan aplikasi

- [Perekaman dan analisis perjalanan](recording-and-analysis.md): sumber data, kolom CSV, indikator
  kualitas, batas interpretasi, dan perilaku saat aplikasi berada di latar belakang.

## Riset protokol

Mulai dari [indeks riset](research/README.md) untuk ringkasan dan panduan membaca bukti. Catatan
berikut menjelaskan analisis statis APK dan capture BLE. Identitas kendaraan serta nilai kredensial
dari capture nyata telah dihapus. Jangan menambahkan QR, VIN, kredensial, log pribadi, atau capture
mentah ke dokumentasi publik.

- [Ringkasan protokol](research/findings.md): transport BLE, struktur frame, autentikasi, dan
  interpretasi mapping.
- [Analisis capture](research/capture-findings.md): reassembly L2CAP, checksum, dan temuan frame
  dari capture yang disamarkan.
- [Analisis mapping](research/02-mapping-reanalysis.md): struktur TLV, offset, dan keterbatasan
  mapping contoh.
- [Status pairing](research/03-auth-pairing-input.md): perilaku yang telah diimplementasikan dan
  yang belum diuji.
- [Analisis QR dan VIN](research/04-apk-qr-pairing.md): hasil pemeriksaan statis serta batas
  pembuktiannya.
- [Analisis request pairing](research/05-yamaha-pairing-requests.md): alur layanan yang ditemukan
  dan status pengujian.

Temuan reverse engineering hanya berlaku pada versi APK/capture yang diperiksa. Detail layanan dapat
berubah. Hasil riset tidak boleh ditafsirkan sebagai jaminan kompatibilitas atau dukungan resmi
Yamaha.
