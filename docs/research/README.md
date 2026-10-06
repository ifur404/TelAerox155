# Catatan riset protokol

Dokumen dalam direktori ini merangkum pemeriksaan statis APK Yamaha Motor On dan analisis capture
BLE yang diberikan pemilik kendaraan. Istilah protokol dan nama identifier dipertahankan agar mudah
dibandingkan dengan kode.

## Dokumen

| Dokumen | Cakupan |
|---|---|
| [Ringkasan protokol](findings.md) | Transport BLE, alur koneksi, struktur frame, autentikasi, dan mapping telemetri |
| [Analisis capture](capture-findings.md) | Reassembly L2CAP, arah paket, checksum, dan hasil pengamatan frame |
| [Analisis mapping](02-mapping-reanalysis.md) | Offset `ByteNo`, data CAN, skala field, dan batas mapping contoh |
| [Status pairing](03-auth-pairing-input.md) | Fitur pairing yang ada dan validasi yang masih diperlukan |
| [Analisis QR dan VIN](04-apk-qr-pairing.md) | Temuan dari kode aplikasi resmi dan batas verifikasinya |
| [Analisis request pairing](05-yamaha-pairing-requests.md) | Alur login/request yang ditemukan dan hasil simulasi client |

## Cara membaca temuan

- **Terverifikasi** berarti struktur atau perilaku didukung kode yang diperiksa atau capture yang
  dianalisis.
- **Inferensi** berarti penjelasan paling sesuai dengan bukti yang tersedia, tetapi belum
  dikonfirmasi secara langsung.
- **Belum diketahui** berarti data yang ada belum cukup untuk memberi kesimpulan.

Analisis capture dibuat offline. Dokumen publik tidak menyertakan APK, capture mentah, QR, VIN,
CCUID, passKey, UUID ponsel, atau nilai telemetri yang dapat mengidentifikasi kendaraan. Jangan
menambahkan data tersebut ke commit atau issue publik.

Catatan ini bukan dokumentasi resmi Yamaha. Perilaku aplikasi, layanan, mapping, atau perangkat
dapat berbeda menurut versi dan model.
