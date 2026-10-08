# Capture komponen analisis asli

`prepare.py` menyalin hanya Swift, project Xcode, Info.plist, dan Assets.xcassets ke
`/private/tmp/telaerox-video-showcase`. Tidak menyalin file kredensial. `MyApp.swift`
dalam salinan diganti harness `ShowcaseApp.swift`. Bundle demo terpisah:
`com.rupi.TelAerox155.VideoDemo`. Sumber aplikasi utama tidak diubah.

Harness menghasilkan CSV sintetis tiga menit tanpa identitas kendaraan,
memprosesnya melalui `TripAnalysis.parse`, lalu merender komponen aplikasi:

- `TripStatsGrid(.vehicle)` dan `TripTimelineCharts(.vehicle)` untuk suhu dan aki.
- `TripTimelineCharts(.riding)` untuk kecepatan, RPM, dan bukaan gas.
- `TripCVTChart`: RPM vs kecepatan, warna berdasarkan bukaan gas.
- `TripModeBreakdown` dan `TripHistogramCard` untuk pola dan distribusi waktu.
- `TripLineChart` dan `TripPlaybackBar` pada 45 posisi kursor replay.
- Mode `--maps-only` mengambil `TripMapCard` dan `TripPlaybackBar` pada 45 posisi,
  memakai GPS sintetis berbentuk lingkaran di area Monas. Rute ini hanya ilustrasi,
  bukan rekaman perjalanan atau lokasi pengguna. Peta dasar dirender oleh MapKit.
  View dipertahankan sepanjang capture agar tile tidak dimuat ulang pada setiap frame.
  Tunggu `video-demo/MAPS-DONE`, lalu salin `motor-map-*.png` ke `motor-assets/`.

Hasil PNG di Documents/video-demo dalam sandbox aplikasi demo. Salin ke `motor-assets/`.
UIHostingController digunakan karena ImageRenderer tidak merender beberapa kontrol UIKit
(slider dan segmented picker). Safe-area hosting dinonaktifkan untuk capture komponen.

```sh
python3 capture/prepare.py
cd /private/tmp/telaerox-video-showcase
xcodebuild -project TelAerox155.xcodeproj -scheme TelAerox155 -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/telaerox-video-showcase-build PRODUCT_BUNDLE_IDENTIFIER=com.rupi.TelAerox155.VideoDemo CODE_SIGNING_ALLOWED=NO build
```

Install dan jalankan bundle demo pada simulator iOS 27. Tunggu file `video-demo/DONE`.
Ukuran PNG tiga kali ukuran view agar tulisan dan grafik tetap tajam.
