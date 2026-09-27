# Auth pairing — input VIN / QR & rencana derivasi passKey tanpa snip

> Konteks: motor & akun punya sendiri (Aerox 155 ABS, pasar Indonesia).
> Client tetap **read-only** sesuai kontrak `AGENTS.md` — dokumen ini cuma
> soal *cara mendapatkan kredensial auth motor sendiri secara sah*, bukan
> menembus device orang lain atau menambah write baru.
>
> Dokumen ini melengkapi `findings.md §6.1` (frame auth `0xAA`) dan
> `findings.md §8` (asal-usul `passKey`). Tidak menggantikan keduanya.

## 1. Dua cara memasukkan identitas kendaraan saat pairing

Aplikasi resmi (Yamaha Motor ON / Y-Connect) butuh **identitas kendaraan**
sebelum bisa konek ke CCU. Ada dua jalur input yang tersedia di app:

1. **Scan QR** — stiker/kartu QR yang disertakan bareng perangkat YConnect
   (bukan QR yang tercetak permanen di motor). Di-scan pakai kamera; decode
   QR pakai native lib MLKit `libbarhopper.so` (PROTO/QR) yang sudah tercatat
   di `findings.md §1`. Isi QR (VIN saja vs. VIN+metadata) **BELUM JELAS** —
   perlu decode satu QR nyata untuk konfirmasi payload-nya.
2. **Ketik manual nomor rangka (VIN / frame number)** — digit nomor rangka
   fisik motor, diketik langsung di form pairing.

Kedua jalur bermuara ke satu nilai yang sama: **VIN**. QR = cara cepat
mengisi VIN; ketik manual = cara alternatif. Keduanya feed ke alur cloud yang
sama di `findings.md §8`.

## 2. Kenapa VIN saja belum cukup (state saat ini)

Dari RE statis APK (`findings.md §8`, **[VERIFIED]**):

```
VIN (dari QR atau ketik)
  → GraphQL CreateUserVehicleMutation(VIN)  ── butuh internet + Yamaha Motor ID
  → cloud Yamaha balikin passKey (6 digit)
  → passKey masuk ke frame auth 0xAA byte[19..24]
```

- **`passKey` diturunkan di server**, bukan di app. APK **tidak** memuat
  algoritma/kunci untuk menghitung `passKey` dari VIN secara lokal
  (grep crypto = nihil selain pengiriman frame). Jadi VIN → passKey saat ini
  adalah kotak hitam di sisi cloud.
- Artinya: **punya VIN saja (via QR atau ketik) belum otomatis bikin kita
  bisa auth** tanpa memanggil cloud atau tanpa tahu passKey-nya.

## 3. Yang membuat "connect tanpa auth JSON hasil snip" itu mungkin / tidak

Tujuan: app pengganti bisa auth ke motor **sendiri** tanpa harus menyalin
`secrets.local.json` hasil sniff PacketLogger. Tiga komponen frame `0xAA`:

| Field | Asal | Bisa dihasilkan sendiri tanpa snip? |
|---|---|---|
| `phoneUUID` (byte 25-56) | UUID acak per-install, CCU terima UUID apa pun berformat benar (`findings.md §8`) | **Ya** — generate sendiri |
| `ccuid` (byte 5-18) | 14 char terakhir nama advertisement BLE motor | **Ya** — baca dari hasil scan BLE, gak perlu snip |
| `passKey` (byte 19-24) | **Server-derived dari VIN** | **Belum** — ini satu-satunya penghalang |

Jadi penghalang tunggalnya = **passKey**. `ccuid` & `phoneUUID` sudah bisa
didapat/dibuat sendiri secara sah tanpa `secrets.local.json`.

## 4. Pertanyaan terbuka untuk RE lanjutan (fokus: dapat passKey sah)

Urut dari yang paling tidak invasif:

1. **Replikasi panggilan cloud VIN → passKey (paling menjanjikan & sah).**
   Panggil `CreateUserVehicleMutation` / `GetMcVehicleInfoQuery` sendiri
   (`feature_pairing/data/**/UserVehicleRepositoryImpl`) pakai VIN motor
   sendiri + Yamaha Motor ID sendiri. Yang perlu dipetakan:
   - endpoint GraphQL + skema request/response persisnya (dari APK / capture HTTPS resmi),
   - cara auth ke API (token Yamaha Motor ID; alur login),
   - apakah passKey **stabil per VIN** (sekali ambil, simpan selamanya) atau
     berubah per pairing. Kalau stabil → cukup ambil sekali, tidak perlu snip BLE lagi.
2. **Decode isi QR stiker YConnect.** Konfirmasi apakah QR memuat lebih dari
   VIN (misal langsung memuat passKey / seed). Kalau QR ternyata mengandung
   passKey, jalur ini melewati cloud sepenuhnya. Perlu: scan 1 QR nyata,
   decode via zxing/MLKit, dump payload mentah.
3. **Cek ulang derivasi lokal di native lib.** `findings.md` menyimpulkan
   tidak ada derivasi lokal di bytecode Java/Kotlin, tapi belum menelusuri
   isi `.so` (`libbarhopper.so` dsb.) untuk logika terkait passKey. Prob.
   rendah, tapi belum ditutup.
4. **Ruang passKey 6 digit.** Hanya sebagai catatan sifat: 6 digit numerik =
   ruang kecil. Analisis apakah CCU membatasi percobaan / lockout, murni
   untuk memahami desain — **bukan** rencana brute-force ke motor (tetap
   read-only, tetap hanya kirim frame auth sesuai kontrak).

## 5. Batasan yang tetap dipegang

- Client tetap read-only: satu-satunya write ke motor = frame auth `0xAA`
  dan keep-alive `0xA6`, identik dengan app resmi (`AGENTS.md`).
- Kredensial motor sendiri (VIN, passKey, ccuid, phoneUUID) hanya disimpan di
  `secrets.local.json` yang sudah di-`.gitignore` — jangan pernah di-commit /
  di-print / dikirim ke layanan eksternal.
- Semua eksperimen ditargetkan ke motor & akun milik sendiri.
