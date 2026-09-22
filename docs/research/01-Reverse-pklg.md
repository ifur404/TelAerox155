Gue punya capture Bluetooth dari iPhone (PacketLogger) berisi sesi
koneksi app Yamaha Y-Connect resmi ke CCU motor Aerox 155 ABS gue.
Tujuannya: konfirmasi protokol BLE yang udah gue bongkar dari APK, dan
ekstrak kredensial auth punya motor gue sendiri, buat dipakai di app
pengganti bikinan gue.

FILE:
- ./Aerox-155.pklg              (PacketLogger trace)
- ./Sample_SCCU1_MappingFile.json  (mapping telemetri dari APK)
- ./findings.md               (hasil RE statis dari APK — baca dulu ini)

Wireshark/tshark bisa baca .pklg langsung. Install kalau belum ada.

=== TUGAS ===

1. INVENTARIS
   Cari handle ATT yang dipakai, petakan ke UUID:
   - 6E400002-B5A3-F393-E0A9-E50E24DCCA9E = TX (write ke CCU)
   - 6E400003-B5A3-F393-E0A9-E50E24DCCA9E = RX (notify dari CCU)
   Laporin jumlah paket per arah, MTU yang dinegosiasi iOS, dan durasi
   sesi.

2. AUTH FRAME
   Cari write 60 byte ke TX yang byte[0] = 0xAA. Bongkar per field
   sesuai tabel di findings.md §6.1. Khusus:
   - tentukan endianness byte[2..3] — LE (00 7f) atau BE (7f 00)?
     Ini masih jadi pertanyaan terbuka, jawab dari data nyata.
   - verifikasi checksum: (256 - sum(byte[0..58]) & 0xFF) == byte[59]
   - byte[57] harusnya 0 (udah pernah pairing). Konfirmasi.
   Cari juga balasan 8 byte 0x5A di RX, cek startProcessingFlag == 1.

3. KREDENSIAL — tulis ke ./secrets.local.json, JANGAN ke findings
   Ekstrak: ccuid (byte 5-18), passKey (byte 19-24), phoneUUID
   (byte 25-56), plus auth frame utuh dalam hex.
   Tambahin ./secrets.local.json ke .gitignore.

4. FRAME RX
   Kelompokkan notifikasi per byte[0]: 0x55 / 0x56 / 0x59 / 0x5B.
   Per tipe laporin: jumlah, panjang (min/max/modus), interval kirim,
   dan berapa persen yang checksum-nya valid.
   Kalau ada frame yang keliatan kepotong (iOS nggak bisa minta MTU 512,
   biasanya mentok ~185) — tandai, ini risiko yang udah gue antisipasi.

5. VALIDASI LAYOUT TLV — ini bagian terpenting
   Buat frame 0x55: jalan TLV-nya (record count di byte[1], tiap record
   3-byte header + data, panjang di header[2]).
   - Konfirmasi bener 2 record: localID {00,01} dan {00,48}
   - Konfirmasi panjang data record 1 = 33 byte, jadi record 2 mulai di
     index 38 dan odometer di index 41
   - Kalau panjangnya BEDA dari dugaan gue, bilang. ByteNo absolut di
     mapping cuma valid kalau panjang record tetap.

6. DECODE + SANITY CHECK
   Pakai mapping JSON, decode frame 0x55. Buat odometer (ByteNo 41,
   UI32, faktor 1/10) coba DUA endianness, tampilkan dua-duanya —
   gue cocokkan sendiri sama angka di speedometer.
   Tampilkan juga: RPM, kecepatan, tegangan aki, suhu air, suhu intake,
   throttle, FI error count, DTC.
   Tandai nilai yang nggak masuk akal (aki