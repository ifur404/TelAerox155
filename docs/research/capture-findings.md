# Analisis capture BLE

Capture PacketLogger dianalisis secara offline untuk memeriksa arah paket, reassembly L2CAP,
checksum, dan struktur frame. Nilai VIN, CCUID, passKey, UUID ponsel, timestamp terperinci, serta
pembacaan telemetri milik kendaraan telah dihapus dari dokumen publik.

## Ringkasan hasil

Kesalahan pada analisis awal berasal dari membaca packet-boundary flag sebagai arah paket dan
memeriksa potongan L2CAP seolah-olah frame ATT lengkap. Setelah reassembly, frame penuh memiliki
checksum yang valid pada sampel yang dianalisis.

| Frame | Jumlah pada capture | Panjang hasil reassembly | Checksum |
|---|---:|---:|---:|
| `0x55` | 277 | 47 byte | Valid pada seluruh frame |
| `0x56` | 279 | 30 byte | Valid pada seluruh frame |
| `0x57` | 1 | 59 byte | Valid |
| `0x59` | 20 | 77 byte | Valid pada seluruh frame |
| `0x5A` | 1 | 8 byte | Valid |
| `0x5B` | 1 | 67 byte | Valid |

Jumlah ini menggambarkan satu capture dan bukan jaminan untuk semua versi CCU.

## Arah dan reassembly L2CAP

Arah dibaca dari tipe record HCI: `0x02` adalah ACL data terkirim dan `0x03` adalah ACL data
diterima. Packet-boundary flag (`PB`) menunjukkan posisi fragmen dalam PDU, bukan arah komunikasi.

- Paket awal memuat panjang L2CAP little-endian. Panjang PDU lengkap adalah empat byte header L2CAP
  ditambah panjang payload yang dinyatakan.
- Paket lanjutan digabung sampai PDU lengkap sebelum ATT di-parse.
- Pada capture yang diperiksa, 732 PDU L2CAP menghasilkan 731 PDU ATT dan satu PDU dengan CID lain.
- Tidak ditemukan fragmen lanjutan tanpa PDU awal yang sesuai.

Karena itu, decoder capture harus menyelesaikan reassembly sebelum menilai panjang frame, batas
field, atau checksum.

## Checksum

Checksum byte terakhir dihitung dari semua byte sebelumnya:

```text
checksum = (256 - (sum(byte[0 .. n-2]) & 0xFF)) & 0xFF
```

Semua frame yang tercantum pada tabel ringkasan lolos pemeriksaan checksum pada capture tersebut.
Frame autentikasi `0xAA` dan frame periodik `0xA6` yang terlihat pada arah TX juga memiliki checksum
valid.

## Autentikasi

Capture menunjukkan satu frame auth `0xAA` sepanjang 60 byte, diikuti balasan `0x5A` sepanjang 8
byte. Balasan memiliki flag StartProcessing bernilai sukses.

Nilai payload autentikasi tidak dipublikasikan. Secara umum, frame auth mencakup header, identifier
CCU, passKey, identifier ponsel, flag bonding, counter, dan checksum. Rincian layout generik
tersedia pada [ringkasan protokol](findings.md); jangan mencatat nilai autentikasi dari capture
nyata di issue, log, atau dokumentasi publik.

## Frame periodik `0xA6`

Capture berisi pasangan perintah dengan command ID `0x058A` dan `0x058B`, berulang selama stream
telemetri. Pemeriksaan menunjukkan keduanya memakai counter berurutan dan checksum yang valid.
Payload `0x058A` membawa field waktu; satu byte tetap pada sampel belum dapat dijelaskan.

Frame telemetri pertama terlihat sebelum perintah `0xA6` pertama. Ini menunjukkan bahwa `0xA6` bukan
pemicu awal stream pada capture tersebut. Apakah stream berlanjut tanpa keep-alive belum diketahui
dan tidak perlu diuji dengan memperluas write di luar kebijakan proyek.

## Struktur telemetri

- Frame `0x55` memiliki dua record TLV dengan ID `{00 01}` dan `{00 48}`. Record kedua berisi
  odometer. Nilai numerik pada payload yang diperiksa menggunakan byte order big-endian dan faktor
  skala sepersepuluh.
- Frame `0x56` memuat record status/CAN. Sebagian ID memiliki nama pada mapping contoh dan sebagian
  belum diketahui.
- Frame `0x59` yang diamati membawa halaman parameter berurutan. Makna seluruh field belum tersedia
  dalam mapping contoh.
- Frame `0x5B` memuat blok informasi kendaraan, termasuk satu field nomor rangka. Nilai field dan
  counter kendaraan tidak ditampilkan di sini.

Parser sebaiknya memvalidasi checksum, membaca jumlah record, lalu mengikuti panjang tiap record
TLV. Jangan menyimpulkan arti field yang belum dikenal dari satu capture.

## Kesimpulan dan batas

Capture mendukung penggunaan tipe HCI untuk menentukan arah, reassembly L2CAP sebelum parsing ATT,
pemeriksaan checksum, serta pembacaan TLV dengan panjang variabel. Capture tunggal tidak cukup untuk
menjelaskan semua ID CAN, field halaman `0x59`, atau byte tetap pada payload waktu.

Temuan ini tidak membuktikan kompatibilitas dengan seluruh model/tahun, dan tidak menggantikan
validasi pada perangkat target. Analisis dilakukan offline; dokumen ini tidak memuat capture atau
kredensial mentah.
