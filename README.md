# TelAerox155

Aplikasi iOS (SwiftUI) untuk membaca telemetri motor Yamaha (CCU SCCU1 / Y-Connect)
lewat Bluetooth LE — read-only, tanpa mengirim perintah kontrol kendaraan.

## Struktur

- `TelAerox155/` — target aplikasi utama.
  - `ContentView.swift` — UI utama (status koneksi, daftar perangkat, telemetri).
  - `TelemetryStore.swift` — `ObservableObject` (`@MainActor`) yang menjembatani
    `YConnectClient` ke SwiftUI: state koneksi, snapshot telemetri, daftar
    perangkat yang terlihat saat scanning, dan trace tahap auth.
  - `YConnectKit/` — modul BLE murni, tanpa dependensi SwiftUI:
    - `YConnectClient.swift` — client CoreBluetooth: scan, connect, auth, keep-alive.
    - `Frame.swift`, `PeriodicFrame.swift` — encoding/decoding frame protokol CCU.
    - `AuthFrame.swift` — frame autentikasi (0xAA/0x5A).
    - `BinaryReader.swift` — helper baca byte stream.
    - `Checksum.swift` — checksum frame.
    - `Mapping.swift` — mapping field frame → nilai telemetri.
    - `TelemetryDecoder.swift` — decode payload frame jadi `TelemetrySnapshot`.
    - `DiagnosticLog.swift` — log mentah TX/RX untuk debugging (kredensial disensor).

## Kontrak keamanan

Byte yang ditulis ke motor **hanya** frame auth (`0xAA`) dan, tergantung
`KeepAlivePolicy`, frame periodik `0xA6` (058A/058B) — identik dengan yang
dikirim aplikasi resmi Yamaha Motor On. Tidak ada write lain (tidak ada
request FFD, tidak ada kontrol kendaraan).

## Build

Buka `TelAerox155.xcodeproj` di Xcode dan jalankan target `TelAerox155` di
simulator atau perangkat iOS (Bluetooth memerlukan perangkat fisik untuk
pengujian penuh).

## Kredensial

`TelAerox155/secrets.local.json` (kalau ada) berisi kredensial motor lokal dan
sudah di-`.gitignore` — jangan pernah di-commit atau dibagikan.
