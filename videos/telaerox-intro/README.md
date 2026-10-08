# TelAerox155 — Dari Jalan, Jadi Cerita

Intro vertikal 1080×1920, 30 fps, 8 detik. Dibuat dengan fframes 1.2.0 dan Skia Metal.

- 0–2,5 detik: rute ilustrasi tergambar di atas peta abstrak.
- 2,5–4,5 detik: rute berubah menjadi grafik, diikuti ringkasan jarak dan durasi.
- 4,5–8 detik: identitas TelAerox155 dan “Setiap perjalanan punya cerita.”

Rute, grafik, jarak 12,8 km, dan durasi 24 menit adalah ilustrasi sintetis. Tidak ada data kendaraan atau lokasi pengguna. Simbol rute merupakan aset intro, bukan perubahan ikon aplikasi. Suara atmosfer dan beat dibuat secara sintetis, bukan rekaman motor atau jalan.

## Menonton dan merender

Gunakan Rust stable terbaru (diverifikasi dengan 1.99 pada macOS 27). Jika Homebrew Rust lama berada lebih awal di PATH, jalankan `export PATH="$HOME/.cargo/bin:$PATH"`.

```sh
cargo run --release -- preview
cargo run --release -- timeline
cargo run --release -- inspect --all-frames --fail-on warning
cargo run --release -- strip -n 12
cargo run --release -- frame 1.8s,3.8s,6s
cargo run --release -- audio analyze
cargo run --release -- render -o telaerox155-intro.mp4
```

Sumber animasi: `src/lib.rs`. Audio: `scripts/make_audio.py`, kemudian normalisasi dengan FFmpeg:

```sh
python3 scripts/make_audio.py
ffmpeg -y -i audio-work/intro-raw.wav -af 'acompressor=threshold=0.15:ratio=3:attack=8:release=100,loudnorm=I=-14:TP=-1.5:LRA=7' -ar 48000 media/intro.wav
```

Font DM Sans Medium disertakan oleh generator resmi fframes. Semua teks berada di area aman vertikal; hasil akhir ditahan tanpa fade ke hitam agar mudah disambung ke video berikutnya.

## Video pengenalan aplikasi — 30 detik

Versi panjang memakai enam adegan, musik instrumental sintetis orisinal 96 BPM,
dan efek transisi. Tidak memakai narasi. Visual merupakan ilustrasi fitur aplikasi,
bukan rekaman layar asli. Versi intro 8 detik tetap tersedia.

| Waktu | Isi |
|---|---|
| 0–5 dtk | TelAerox155, telemetri Aerox di iPhone |
| 5–10 dtk | Rekam telemetri dan GPS |
| 10–15 dtk | Putar ulang rute |
| 15–20 dtk | Grafik kecepatan dari rekaman |
| 20–25 dtk | Ringkasan jarak, durasi, dan rata-rata |
| 25–30 dtk | Nama aplikasi dan tagline |

Transisi silang mulai sekitar 0,33 detik sebelum batas tiap adegan.

```sh
cargo run --release --bin telaerox-story -- preview
cargo run --release --bin telaerox-story -- inspect --all-frames --fail-on warning
cargo run --release --bin telaerox-story -- strip -n 18 -o story-strip.png
cargo run --release --bin telaerox-story -- render -o telaerox155-pengenalan-30s.mp4
```

Sumber: `src/story.rs`; musik: `scripts/make_story_audio.py`.
Audio stereo dimuat dari `audio/` saat runtime sehingga kanal kiri/kanan tetap terjaga.

```sh
python3 scripts/make_story_audio.py
ffmpeg -y -i audio-work/story-raw.wav -af loudnorm=I=-14:TP=-1.5:LRA=7 -ar 48000 audio/story-music.wav
```

## Pengenalan dengan fokus analisis motor — 30 detik

Video hasil render: [telaerox155-analisis-motor-maps-30s.mp4](telaerox155-analisis-motor-maps-30s.mp4) (30 detik, 1080×1920, 30 fps).
Versi sebelum peta tetap tersedia sebagai `telaerox155-analisis-motor-30s.mp4`.
Sumber: `src/motor.rs`; capture: `motor-assets/`; petunjuk reproduksi: `capture/README.md`.

Visual diambil dari komponen SwiftUI asli melalui simulator, diisi hasil analisis CSV
sintetis. Bukan rekaman kendaraan pengguna. Beberapa panel digulir atau ditata ulang
untuk keterbacaan video vertikal. Bentuk grafik dan perhitungannya memakai kode aplikasi.

| Waktu | Fitur yang ditampilkan |
|---|---|
| 0–3 dtk | Pengenalan TelAerox155, analisis dari rekaman |
| 3–8 dtk | Suhu mesin/udara dan tegangan aki sepanjang rekaman |
| 8–13 dtk | Grafik kecepatan, RPM, dan bukaan gas |
| 13–18 dtk | Kurva CVT: RPM vs kecepatan, warna bukaan gas |
| 18–22 dtk | Peta rute berwarna sesuai kecepatan |
| 22–27 dtk | Posisi di peta dan pembacaan sensor saat replay |
| 27–30 dtk | Habis riding, buka datanya. TelAerox155. |

Copy terbaru dan alasan pemilihan kalimat ada di `COPY.md`. Indikator adegan dekoratif
di bawah sudah dihapus; slider di dalam tampilan replay tetap menjadi bagian demonstrasi fitur.

```sh
cargo run --release --bin telaerox-motor -- preview
cargo run --release --bin telaerox-motor -- inspect --all-frames --fail-on warning
cargo run --release --bin telaerox-motor -- strip -n 21 -o motor-maps-strip.png
cargo run --release --bin telaerox-motor -- render -o telaerox155-analisis-motor-maps-30s.mp4
```

Musik dan efek transisi berasal dari `scripts/make_motor_audio.py`:

```sh
python3 scripts/make_motor_audio.py
ffmpeg -y -i audio-work/motor-raw.wav -af loudnorm=I=-14:TP=-1.8:LRA=7 -ar 48000 audio/motor-music.wav
```

Kurva CVT adalah visualisasi hubungan sensor, bukan diagnosis kerusakan otomatis.
Tidak ada penilaian “motor sehat” atau klaim tuning/perintah kontrol kendaraan.
