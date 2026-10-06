# Panduan kontribusi dan agent

## Ruang lingkup proyek

Aplikasi iOS SwiftUI ini membaca telemetri motor Yamaha melalui Bluetooth LE. `YConnectKit/`
menangani protokol BLE tanpa dependensi SwiftUI; `TelemetryStore` dan `ContentView` menjadi lapisan
aplikasi.

## Batas komunikasi kendaraan

Client bersifat **read-only**. Byte yang boleh ditulis ke motor dibatasi pada:

- Frame autentikasi `0xAA`; respons `0x5A` hanya diterima dari motor.
- Frame keep-alive periodik `0xA6` (`058A`/`058B`) sesuai `KeepAlivePolicy`, dengan format yang sama
  seperti aplikasi resmi Yamaha Motor On.

Jangan menambahkan write lain, termasuk request FFD atau perintah kontrol kendaraan, tanpa
persetujuan eksplisit pemilik repository. Batas ini adalah persyaratan keamanan proyek.

## Kredensial dan data pribadi

File lokal `TelAerox155/secrets.local.json`, jika ada, berisi kredensial kendaraan dan diabaikan
oleh Git. Jangan commit, mencetak, atau mengirim isinya ke layanan eksternal. Perlakukan QR pairing,
VIN, CCUID, UUID ponsel, dan capture BLE mentah sebagai data sensitif.

## Konvensi kode

- Pertahankan Bahasa Indonesia pada komentar dan dokumentasi inline di area yang menggunakannya.
- Beberapa tipe `YConnectKit` sengaja memakai anotasi `nonisolated` karena digunakan atau
  dibandingkan dari closure `Timer` `@Sendable` di bawah `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`.
  Jangan menghapus anotasi tanpa meninjau komentar di `YConnectClient.swift`, `ClientState`, dan
  `KeepAlivePolicy`.
- `YConnectClientDelegate` tidak diisolasi secara eksplisit ke `MainActor`, tetapi aman selama
  `YConnectClient` dibuat dengan `queue: nil` karena delegate dipanggil di main queue. Jika memakai
  queue kustom, method delegate perlu `nonisolated` dan perpindahan eksplisit ke `MainActor`.

## Sebelum commit atau push

- Build project di Xcode dan pastikan tidak ada error atau warning baru.
- Tinjau `git status` sebelum staging. Jangan commit `secrets.local.json`, `build/`, `DerivedData/`,
  `xcuserdata`, atau `.DS_Store`.
- Tulis pesan commit dalam Bahasa Indonesia atau Inggris. Jelaskan alasan perubahan secara spesifik.
