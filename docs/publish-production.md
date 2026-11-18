# Publish ke production (Sideload Upkan)

Production untuk TelAerox155 adalah katalog [Sideload Upkan](https://sideload.upkan.id) — dokumentasi
API resmi ada di <https://sideload.upkan.id/developers>. Aplikasi dari katalog ini dipasang lewat
AltStore, SideStore, TrollStore, atau unduhan IPA biasa.

## Prasyarat

1. **API key** di file `.env` pada root repo (sudah diabaikan Git):

   ```sh
   SIDELOAD_KEY=upk_xxxxxxxx
   ```

   Key dibuat di Dashboard → API keys setelah login Google. Jangan commit, mencetak, atau menempel
   isi `.env` ke chat/log/layanan lain.
2. `jq` dan Xcode command line tools terpasang.
3. **Naikkan build number** sebelum publish. Kombinasi versi + build harus unik per aplikasi; build
   yang sudah *approved* tidak bisa di-upload ulang. Ubah `CURRENT_PROJECT_VERSION` (dan
   `MARKETING_VERSION` bila rilis versi baru) di `TelAerox155.xcodeproj/project.pbxproj` untuk
   konfigurasi Debug dan Release.

Bundle ID: `com.rupi.TelAerox155`.

## Cara publish

```sh
bash scripts/publish-sideload.sh --changelog "Ringkasan perubahan untuk pengguna"
```

Script akan:

1. Memuat `SIDELOAD_KEY` dari `.env` dan memverifikasinya lewat `GET /api/v1/me`.
2. Menjalankan `scripts/build-ipa.sh` (Release, `iphoneos`, unsigned) → `build/TelAerox155.ipa`.
3. Memastikan `secrets.local.json` tidak ikut di dalam IPA.
4. Upload ke `POST /api/v1/publish` dengan changelog di header `X-Changelog` (URL-encoded).

Opsi:

| Opsi | Fungsi |
|---|---|
| `--changelog "teks"` | Changelog (wajib, atau pakai `--changelog-file`) |
| `--changelog-file FILE` | Ambil changelog dari file |
| `--skip-build` | Pakai IPA yang sudah ada di `build/` |
| `--ipa PATH` | Upload IPA lain |

Setelah upload, respons berisi `status: pending` atau `status: approved`. Versi baru menunggu review
admin; versi lama tetap live sampai disetujui. Cek status via
`GET https://sideload.upkan.id/api/v1/apps/com.rupi.TelAerox155`.

## Referensi API

Base URL `https://sideload.upkan.id`, header `Authorization: Bearer $SIDELOAD_KEY` untuk semua
endpoint tulis. Error selalu berbentuk `{ "error": "..." }`.

| Method | Path | Fungsi |
|---|---|---|
| POST | `/api/v1/publish?filename=X.ipa` | Upload IPA ≤ 95 MB; body = byte IPA, header `X-Changelog` |
| POST | `/api/v1/uploads` | Mulai multipart upload, body `{ fileName, size }` |
| PUT | `/api/v1/uploads/:id/parts/:n` | Kirim part ke-n (64 MB, kecuali terakhir) → `{ partNumber, etag }` |
| POST | `/api/v1/uploads/:id/complete` | Selesaikan, body `{ parts, changelog?, app?, replace? }` |
| DELETE | `/api/v1/uploads/:id` | Batalkan multipart upload |
| PATCH | `/api/v1/apps/:bundleId` | Ubah metadata (name, subtitle, description, category, dll.) |
| PUT | `/api/v1/apps/:bundleId/icon` | Ganti ikon (PNG/JPEG/WebP, maks 2 MB) |
| GET | `/api/v1/apps/:bundleId/screenshots` | Daftar screenshot + status review |
| POST | `/api/v1/apps/:bundleId/screenshots?device=iphone\|ipad` | Tambah screenshot (maks 8 MB, sisi terpendek ≥ 320 px, maks 10/device) |
| PUT | `/api/v1/apps/:bundleId/screenshots` | Atur urutan `{ device, ids }`; id yang tidak disebut dihapus |
| DELETE | `/api/v1/apps/:bundleId/screenshots/:id` | Hapus screenshot |
| DELETE | `/api/v1/apps/:bundleId/versions/:id` | Hapus versi |
| GET | `/api/v1/me` | Cek akun & key |
| GET | `/api/v1/apps`, `/api/v1/apps/:bundleId` | Data publik (tanpa auth) |

Kategori metadata: `games`, `utilities`, `social`, `entertainment`, `photo-video`, `lifestyle`,
`developer`, `other`.

### IPA > 95 MB, metadata, dan screenshot

Untuk file besar atau upload metadata/screenshot sekaligus, situs menyediakan client resmi
`publish.mjs` (Node). Unduh dan **baca isinya dulu** sebelum dijalankan:

```sh
curl -fsSLO https://sideload.upkan.id/publish.mjs
set -a; source .env; set +a
node publish.mjs build/TelAerox155.ipa \
  --changelog "..." \
  --metadata app.json \
  --screenshots screenshots/iphone
```

Opsi lain: `--changelog-file`, `--icon icon.png`, `--ipad-screenshots dir`, `--replace` (timpa
versi+build yang masih pending/rejected), `--bundle-id` (upload screenshot tanpa IPA).

## Aturan

- Bundle ID dimiliki uploader pertama; developer lain mendapat 403.
- Key yang dibatasi ke satu bundle ID menolak IPA dengan bundle ID lain (403).
- Screenshot baru juga direview; perubahan urutan dan penghapusan langsung berlaku.
- Publish adalah aksi outward-facing: agent hanya menjalankannya bila diminta eksplisit.
