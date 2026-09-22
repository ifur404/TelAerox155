Gue lagi reverse engineering protokol BLE Yamaha Y-Connect buat bikin
app pengganti untuk Aerox 155 ABS (pasar Indonesia). Target akhirnya app
iOS read-only yang nampilin telemetri dari CCU motor.

Yang gue punya: file APK Y-Connect (path: ./yconnect.apk)
Yang gue mau dari sesi ini: peta protokol BLE-nya, dari analisis statis APK.

TUGAS:

1. Decompile APK pakai jadx (install kalau belum ada). Laporin dulu:
   - versi app & minSdk
   - ada obfuscation (ProGuard/R8/DexGuard)? seberapa parah
   - ada native lib (.so) di lib/? kalau ada, sebut arsitektur & nama
   - ada anti-tamper / root detection?

2. Petakan permukaan BLE-nya:
   - semua UUID 128-bit vendor (abaikan UUID standar Bluetooth SIG)
   - kelas yang extend BluetoothGattCallback atau pakai BluetoothLeScanner
   - characteristic mana yang read / write / notify
   - nama device / service UUID yang dipakai buat filter saat scanning

3. Bedah struktur frame:
   - gimana payload disusun sebelum dikirim (cari builder/encoder,
     ByteBuffer, byte[] manipulation)
   - ada header, command ID, length field, checksum/CRC?
   - gimana notification dari CCU di-parse jadi nilai (odometer, fuel,
     voltage, error code)
   - satuan & skala tiap field kalau ketahuan (mis. odometer dikali 10)

4. PENTING — auth/pairing:
   Pairing minta nomor rangka (frame number / VIN) sebelum konek.
   Telusuri nomor rangka itu dipakai buat apa:
   - cuma validasi form lokal?
   - dikirim ke cloud Yamaha buat verifikasi?
   - dipakai sebagai kunci/seed di handshake sama CCU (hashing, key
     derivation, challenge-response)?
   Ini penentu apakah proyek ini feasible, jadi kerjain sampai tuntas.

5. Pisahin mana fitur yang butuh cloud Yamaha (Yamaha Motor ID, ranking,
   riding log) vs murni lokal BLE. Gue cuma butuh yang lokal.

OUTPUT:
Tulis temuannya ke ./findings.md — terstruktur, dengan cuplikan kode
yang relevan dan nama kelas/method aslinya biar bisa gue telusuri lagi.
Tandai jelas mana yang lu yakin vs mana yang masih dugaan.

BATASAN:
- Analisis statis doang. Jangan ada kode yang nulis/ngirim apa pun ke
  motor — ini kendaraan yang gue naikin.
- Kalau ada bagian yang keobfuscate parah sampai nggak kebaca, bilang
  aja, jangan ngarang interpretasi.