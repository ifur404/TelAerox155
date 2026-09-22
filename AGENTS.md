# Panduan Agent untuk repo ini

## Ruang lingkup

Aplikasi iOS (Swift/SwiftUI) yang membaca telemetri motor Yamaha lewat BLE.
`YConnectKit/` adalah modul protokol BLE murni (tanpa SwiftUI); `TelemetryStore`
dan `ContentView` adalah lapisan UI di atasnya.

## Kontrak keamanan — jangan dilanggar

Client ini **read-only**. Satu-satunya byte yang boleh ditulis ke motor:

- frame auth `0xAA` (dan respons `0x5A`), dan
- frame keep-alive periodik `0xA6` (058A/058B), sesuai `KeepAlivePolicy`,
  identik dengan yang dikirim aplikasi resmi Yamaha Motor On.

Jangan menambahkan write lain (request FFD, kontrol kendaraan, dll) tanpa
persetujuan eksplisit dari pemilik repo — ini bukan sekadar konvensi kode,
tapi batasan keamanan yang disengaja.

## Kredensial

`TelAerox155/secrets.local.json` berisi kredensial motor dan sudah masuk
`.gitignore`. Jangan pernah commit, print, atau kirim isi file ini ke layanan
eksternal.

## Konvensi kode

- Banyak komentar & dokumentasi inline dalam Bahasa Indonesia — pertahankan
  bahasa yang sama saat menambah/mengubah komentar di area tersebut.
- Beberapa tipe di `YConnectKit` sengaja ditandai `nonisolated` karena
  dibandingkan/dipakai dari closure `Timer` `@Sendable` di bawah
  `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` — jangan hapus anotasi ini tanpa
  memahami alasannya (lihat komentar di `YConnectClient.swift` dan
  `ClientState`/`KeepAlivePolicy`).
- `YConnectClientDelegate` tidak `MainActor`-isolated secara eksplisit, tapi
  aman selama `YConnectClient` dibuat dengan `queue: nil` (delegate dipanggil
  di main queue). Kalau menambahkan queue custom, method delegate harus
  di-`nonisolated` + hop manual ke `MainActor`.

## Sebelum commit/push

- Pastikan project build tanpa error/warning baru di Xcode.
- Jangan commit `secrets.local.json`, `build/`, `DerivedData/`, atau file
  `xcuserdata`/`.DS_Store` — sudah dicakup `.gitignore`, tapi cek ulang
  `git status` sebelum `git add`.
- Tulis pesan commit dalam Bahasa Indonesia atau Inggris, jelas dan spesifik
  soal *kenapa* perubahan dilakukan (bukan cuma daftar file yang diubah).
