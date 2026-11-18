# Publish ke production (Sideload Upkan)

Production untuk TelAerox155 adalah katalog [Sideload Upkan](https://sideload.upkan.id), halaman app:
<https://sideload.upkan.id/apps/telaerox155>. Aplikasi dari katalog ini dipasang lewat AltStore,
SideStore, TrollStore, atau unduhan IPA biasa. Panduan resmi untuk agent ada di
<https://sideload.upkan.id/publish.md>, dokumentasi API di <https://sideload.upkan.id/developers>.

## File yang terlibat

```
.env                         SIDELOAD_KEY (+ opsional SIDELOAD_URL). Rahasia, diabaikan Git
.env.example                 Contoh .env tanpa nilai (di-commit)
scripts/publish-sideload.sh  Perintah utama: cek key → build → cek secrets → upload
scripts/publish.mjs          CLI resmi Upkan (Node 18+, tanpa dependency); multipart + retry
scripts/sideload.json        Metadata listing app (nama, subtitle, deskripsi, kategori, link, warna)
scripts/build-ipa.sh         Build Release unsigned → build/TelAerox155.ipa
```

Bundle ID: `com.rupi.TelAerox155`.

## Prasyarat

1. **API key** di `.env` pada root repo:

   ```sh
   SIDELOAD_KEY=upk_xxxxxxxx
   ```

   Key dibuat di <https://sideload.upkan.id/dashboard/keys>. Jangan commit, mencetak, atau menempel
   isi `.env` ke chat/log/layanan lain.
2. Node.js 18+ dan Xcode command line tools terpasang.
3. **Naikkan build number** sebelum publish. Kombinasi versi + build harus unik per aplikasi (`409`
   bila sudah tayang). Ubah `CURRENT_PROJECT_VERSION` (dan `MARKETING_VERSION` bila rilis versi baru)
   di `TelAerox155.xcodeproj/project.pbxproj` untuk konfigurasi Debug dan Release.

## Cara publish

```sh
bash scripts/publish-sideload.sh --changelog "Ringkasan perubahan untuk pengguna"
```

Script akan:

1. Memuat `SIDELOAD_KEY` dari `.env` dan memverifikasinya lewat `GET /api/v1/me`.
2. Menjalankan `scripts/build-ipa.sh` (Release, `iphoneos`, unsigned) → `build/TelAerox155.ipa`.
3. Memastikan `secrets.local.json` tidak ikut di dalam IPA.
4. Menjalankan `scripts/publish.mjs` untuk upload multipart beserta metadata dari
   `scripts/sideload.json`. Bundle ID, versi, build, iOS minimal, dan ikon dibaca dari IPA.

| Opsi | Fungsi |
|---|---|
| `--changelog "teks"` | Changelog (wajib saat upload IPA, atau pakai `--changelog-file`) |
| `--changelog-file FILE` | Ambil changelog dari file |
| `--skip-build` | Pakai IPA yang sudah ada di `build/` |
| `--ipa PATH` | Upload IPA lain |
| `--listing-only` | Perbarui listing (metadata/ikon/screenshot) tanpa upload IPA |
| `--screenshots DIR` | Screenshot iPhone, urut nama file, maks 10 |
| `--ipad-screenshots DIR` | Screenshot iPad, maks 10 |
| `--icon FILE` | Ganti ikon listing (PNG/JPEG/WebP, maks 2 MB) |

Set screenshot di server dibuat persis sama dengan folder yang diberikan (yang sama tidak diupload
ulang, yang tidak ada di folder dihapus), jadi aman dijalankan setiap rilis.

Contoh memperbarui listing saja setelah mengubah `scripts/sideload.json`:

```sh
bash scripts/publish-sideload.sh --listing-only
bash scripts/publish-sideload.sh --listing-only --screenshots screenshots/iphone
```

## Hasil

- `status: "approved"`: sudah tayang.
- `status: "pending"`: menunggu review admin; versi lama tetap live. Jangan publish ulang build yang
  sama — naikkan build untuk perubahan berikutnya.
- `401`: key salah atau dicabut. Minta key baru dan perbarui `.env`.
- `403`: key dibatasi ke bundle ID lain, atau bundle ID milik developer lain.
- `409`: versi + build sudah tayang. Naikkan `CURRENT_PROJECT_VERSION`.
- `422`: file bukan IPA yang valid.

Status bisa dicek tanpa auth: `GET https://sideload.upkan.id/api/v1/apps/com.rupi.TelAerox155`.

## Memperbarui CLI

`scripts/publish.mjs` adalah salinan CLI resmi. Untuk memperbarui, unduh ulang lalu **baca diff-nya**
sebelum commit:

```sh
curl -fsSLo scripts/publish.mjs https://sideload.upkan.id/publish.mjs
git diff scripts/publish.mjs
```

Opsi `--replace` di CLI khusus admin (menimpa versi+build yang sudah approved), jadi tidak diteruskan
oleh `publish-sideload.sh`.

## Referensi API

Base URL `https://sideload.upkan.id`, header `Authorization: Bearer $SIDELOAD_KEY` untuk semua
endpoint tulis. Error selalu berbentuk `{ "error": "..." }`.

| Method | Path | Fungsi |
|---|---|---|
| POST | `/api/v1/publish?filename=X.ipa` | Upload IPA ≤ 95 MB dalam satu request; header `X-Changelog` |
| POST | `/api/v1/uploads` | Mulai multipart upload, body `{ fileName, size }` |
| PUT | `/api/v1/uploads/:id/parts/:n` | Kirim part ke-n → `{ partNumber, etag }` |
| POST | `/api/v1/uploads/:id/complete` | Selesaikan, body `{ parts, changelog?, app?, replace? }` |
| DELETE | `/api/v1/uploads/:id` | Batalkan multipart upload |
| PATCH | `/api/v1/apps/:bundleId` | Ubah metadata (name, subtitle, description, category, dll.) |
| PUT | `/api/v1/apps/:bundleId/icon` | Ganti ikon (PNG/JPEG/WebP, maks 2 MB) |
| GET | `/api/v1/apps/:bundleId/screenshots` | Daftar screenshot + status review |
| POST | `/api/v1/apps/:bundleId/screenshots?device=iphone\|ipad` | Tambah screenshot (maks 8 MB, maks 10/device) |
| PUT | `/api/v1/apps/:bundleId/screenshots` | Atur urutan `{ device, ids }`; id yang tidak disebut dihapus |
| DELETE | `/api/v1/apps/:bundleId/screenshots/:id` | Hapus screenshot |
| DELETE | `/api/v1/apps/:bundleId/versions/:id` | Hapus versi |
| GET | `/api/v1/me` | Cek akun & key |
| GET | `/api/v1/apps`, `/api/v1/apps/:bundleId` | Data publik (tanpa auth) |

Kategori metadata: `games`, `utilities`, `social`, `entertainment`, `photo-video`, `lifestyle`,
`developer`, `other`.

## Aturan

- Bundle ID dimiliki uploader pertama; developer lain mendapat 403.
- Screenshot baru juga direview; perubahan urutan dan penghapusan langsung berlaku.
- Publish dan `--listing-only` adalah aksi outward-facing: agent hanya menjalankannya bila diminta
  eksplisit.
