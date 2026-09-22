import Foundation

/// Pembangun frame periodik `0xA6` (058A/058B) yang dikirim CENTRAL setiap 1 detik
/// selama sesi streaming — persis perilaku app resmi Yamaha Motor On.
///
/// KENAPA INI ADA: hasil bandingkan dengan dekompilasi APK menunjukkan CCU
/// menerima uplink 1 Hz seumur sesi (`SCCUPeriodicDataSender`, mulai tepat saat
/// state == CONNECTED, berhenti saat DISCONNECTED). Client Swift lama hanya
/// menulis SATU frame (auth) lalu diam total — itu penyebab paling mungkin dari
/// "connect sukses tapi timeout beberapa detik kemudian": CCU (peripheral) atau
/// link BLE menganggap central idle dan memutus.
///
/// Dua varian berbagi SATU counter (dibuktikan capture: 058A dapat counter genap,
/// 058B ganjil, berselang-seling 1 Hz).
nonisolated public enum PeriodicFrame {

    /// 058A — 15 byte: tanggal/jam lokal + persen baterai HP.
    /// Layout dari p024u/b.java:75-88 (CanMessage058AEntity).
    /// [0]=0xA6 [1]=0x01 [2..3]=0x05,0x8A [4]=0x08(len)
    /// [5..6]=tahun BE u16 [7]=bulan [8]=tanggal [9]=jam [10]=menit [11]=detik
    /// [12]=batteryPercent<<1 [13]=counter [14]=checksum
    public static func build058A(date: Date = Date(),
                                  calendar: Calendar = Calendar(identifier: .gregorian),
                                  batteryPercent: Int,
                                  counter: UInt8) -> [UInt8] {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(clamping: min(max(comps.year ?? 0, 0), 9999))
        let month = UInt8(clamping: min(max(comps.month ?? 1, 1), 12))
        let day = UInt8(clamping: min(max(comps.day ?? 1, 1), 31))
        let hour = UInt8(clamping: min(max(comps.hour ?? 0, 0), 23))
        let minute = UInt8(clamping: min(max(comps.minute ?? 0, 0), 59))
        let second = UInt8(clamping: min(max(comps.second ?? 0, 0), 59))
        let battery = UInt8(clamping: min(max(batteryPercent, 0), 100))

        var b = [UInt8](repeating: 0, count: 15)
        b[0] = 0xA6
        b[1] = 0x01
        b[2] = 0x05; b[3] = 0x8A   // localID (BE)
        b[4] = 0x08                // panjang record
        b[5] = UInt8(year >> 8); b[6] = UInt8(year & 0xFF)
        b[7] = month
        b[8] = day
        b[9] = hour
        b[10] = minute
        b[11] = second
        b[12] = battery << 1
        b[13] = counter
        b[14] = Checksum.compute(b[0..<14])
        return b
    }

    /// 058B — 9 byte: flag notifikasi telepon relay. Kirim 0x00,0x00 = tidak ada
    /// notifikasi pending — TIDAK mengubah apa pun di motor, murni "aku masih di sini".
    /// Layout dari p024u/c.java:37-44 (CanMessage058BEntity).
    /// [0]=0xA6 [1]=0x01 [2..3]=0x05,0x8B [4]=0x02(len)
    /// [5]=notificationUpper [6]=notificationLower [7]=counter [8]=checksum
    public static func build058B(counter: UInt8,
                                  notificationUpper: UInt8 = 0x00,
                                  notificationLower: UInt8 = 0x00) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 9)
        b[0] = 0xA6
        b[1] = 0x01
        b[2] = 0x05; b[3] = 0x8B
        b[4] = 0x02
        b[5] = notificationUpper
        b[6] = notificationLower
        b[7] = counter
        b[8] = Checksum.compute(b[0..<8])
        return b
    }
}
