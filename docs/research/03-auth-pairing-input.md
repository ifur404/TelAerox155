# Auth pairing — rencana QR dan input nomor rangka

Diperbarui 2026-10-05. Konteks: motor dan akun milik sendiri (Aerox 155 ABS,
pasar Indonesia). Client tetap read-only sesuai [AGENTS.md](../../AGENTS.md).

## 1. Status saat ini

Alur aplikasi kini: pilih perangkat Bluetooth → QR / pilihan 4 digit → coba
auth → simpan file privat `secrets.local.json` hanya setelah motor menerima
auth. Jalur QR sudah diimplementasikan; jalur 4 digit **belum berfungsi** karena
integrasi sesi Yamaha belum tersedia. Tidak ada impor JSON atau penyimpanan
kredensial sebelum percobaan koneksi. Decoder dan penyimpanan diuji dengan
data buatan, belum QR/motor asli.

Pembacaan hasil decompile menemukan dua jalur berbeda. Bukti sumber,
aturan decoding, hash APK, dan batas verifikasinya ada di
[analisis APK lanjutan](04-apk-qr-pairing.md). Hasil decompile yang sudah
tersedia belum diverifikasi identik seluruhnya dengan APK; identifier
terkait telah ditemukan langsung dalam DEX. Belum ada pengujian QR asli
atau autentikasi ke motor untuk jalur baru ini.

| Jalur | Perilaku pada kode yang diperiksa | Yang belum terverifikasi |
|---|---|---|
| QR CCU | Decode payload 24 karakter secara lokal, cocokkan ID CCU, ambil enam karakter sebagai passKey | Kesesuaian QR pengguna dan penerimaan oleh CCU |
| Input potongan VIN | Cocokkan empat karakter dengan VIN yang sudah ada di state, lalu ambil passKey lewat REST menggunakan VIN lengkap dan token sesi | Asal VIN lengkap sebelum layar ini, login/refresh iOS, dan respons layanan saat ini |

Klaim lama bahwa QR hanya mengisi VIN dan semua passKey harus berasal dari
cloud digantikan oleh temuan ini. Respons berisi passKey juga tidak
membuktikan bagaimana server menghasilkan atau menyimpannya.

## 2. Jalur QR yang diprioritaskan

Handler QR menerima 24 karakter, menyusun ulang posisinya, lalu memakai
14 karakter pertama hasil decoding untuk memeriksa CCU dan enam karakter
berikutnya sebagai passKey. Empat karakter sisanya tidak dipakai oleh
handler yang diperiksa; maknanya belum diketahui.

Ekstraksi ini lokal. Itu belum berarti seluruh onboarding aplikasi resmi
bisa offline: setelah QR diterima, app menuju tahap download info kendaraan.
App resmi juga sudah mempunyai kendaraan terpilih saat memeriksa QR.

Rancangan untuk aplikasi kita:

```text
Scan Bluetooth → pilih motor → scan QR → cocokkan CCU → coba autentikasi
  → 0x5A accepted → buat secrets.local.json privat → paired / telemetri
```

Kredensial calon pairing hanya berada di memori sampai CCU menerima auth.
Koneksi ditargetkan ke identifier Bluetooth perangkat yang dipilih. Jika
pairing gagal/batal/timeout, file lama dipertahankan. File baru dibuat secara
atomik setelah auth diterima; jika penulisan gagal, UI tidak menyatakan paired.

## 3. Jalur input nomor rangka

Pada layar yang diperiksa, input pengguna dibandingkan dengan:

```text
VIN.dropLast(2).takeLast(4)
```

Artinya, lewati dua karakter paling belakang, lalu ambil empat karakter
sebelumnya. Ini bukan empat karakter terakhir VIN. VIN lengkap sudah ada
di state layar; empat karakter input tidak cukup untuk membentuknya.

Jika cocok dan ada internet, app meminta `GET pairing_info/{vinCode}`
menggunakan VIN lengkap. Interceptor menyertakan token sesi melalui header
`jwtKey`. Detail sumber tercatat di [analisis APK](04-apk-qr-pairing.md#3-jalur-rest-untuk-mengambil-passkey).
Keberadaan GraphQL dalam APK tidak berarti jalur ini memakai GraphQL.

## 4. Langkah berikutnya dan kriteria keberhasilan

1. **Validasi QR asli secara lokal.** Pengguna menyediakan path foto QR
   miliknya di laptop. Baca tanpa mengunggah ke layanan pembaca QR; periksa
   panjang payload dan format hasil decoding. Jangan cetak payload atau
   passKey di chat/log dan jangan simpan foto sebagai fixture repo.
2. **Cocokkan identitas motor.** Cocokkan field CCU dengan hasil scan BLE
   melalui normalisasi yang dipakai client. Sukses decoding saja belum
   membuktikan QR milik perangkat yang dipilih.
3. **Validasi implementasi di iPhone.** Scanner Bluetooth, QR, validasi, dan
   penyimpanan setelah auth sudah dibuat. Uji izin Bluetooth/kamera, perangkat
   salah, timeout, pembatalan, serta memastikan tidak ada file sebelum auth
   diterima. phoneUUID disimpan bersama kredensial untuk koneksi berikutnya.
4. **Build dan uji di motor sendiri.** Pastikan build tanpa error/warning
   baru, CCU menerima auth, telemetri masuk, dan koneksi berikutnya memakai
   kredensial tersimpan tanpa JSON atau scan QR ulang. Hasil nyata dicatat
   terpisah dari hasil analisis statis.

Jika QR tidak tersedia atau formatnya berbeda, lanjutkan penelusuran asal
VIN lengkap dan alur login/refresh Yamaha. Jangan menganggap potongan VIN
sebagai passKey atau mencoba kombinasi kredensial.

## 5. Penyimpanan dan batas keamanan

- Kredensial koneksi dibaca dari file privat Application Support/Pairing.
  Direktori dikecualikan dari backup dan file memakai proteksi iOS. JSON
  repo/bundle tidak dibaca untuk proses pairing baru.
- Jangan commit, mencetak, atau membagikan isi `secrets.local.json`.
  Perlakukan QR yang membawa kredensial dengan perlindungan yang sama.
- Rencana ini tidak menambah write ke motor. Tetap hanya frame auth sesuai
  kontrak dan keep-alive `0xA6` sesuai `KeepAlivePolicy`.
- Masa berlaku passKey dan perilaku setelah reset/pairing ulang belum
  diketahui; jangan menjanjikan kredensial berlaku selamanya.
