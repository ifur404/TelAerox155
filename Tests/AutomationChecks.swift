import Foundation

/// Pemeriksaan otomatis untuk kebijakan hubungkan otomatis (auto-connect),
/// rekam perjalanan otomatis (auto-record), jeda berhenti (grace period),
/// override manual, dan backoff reconnect. Dijalankan lewat Tests/run.sh.
@main
@MainActor
struct AutomationChecks {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() {
        checkAutoConnectPolicy()
        checkAutoRecordLifecycle()
        checkAutoRecordOverridesAndEdgeCases()
        checkRideActivityTracker()
        checkIdlingStopProtection()
        checkInactivityAutoCutAndSplit()
        checkMinimumDurationDiscard()
        checkReconnectBackoff()
        checkSessionRecorderAutoStopIntegration()
        print("Lulus \(checks) pemeriksaan otomatisasi auto-connect, auto-record, potong diam, buang singkat, dan backoff.")
    }

    static func checkAutoConnectPolicy() {
        // Default OFF agar perilaku lama tetap manual.
        var policy = AutoConnectPolicy()
        expect(!policy.isEnabled && !policy.shouldBeStandby && policy.mode == .off,
               "Default auto-connect harus OFF")

        // Nyalakan tanpa pairing -> tidak memulai standby.
        let noPairingAction = policy.setEnabled(true, isCurrentlyConnectedOrConnecting: false, isCurrentlyStandby: false)
        expect(noPairingAction == .none && !policy.shouldBeStandby && policy.mode == .off,
               "Auto-connect tanpa pairing tidak boleh masuk standby")

        // Selesai pairing saat toggle aktif -> siap standby.
        policy.didCompletePairing()
        expect(policy.shouldBeStandby && policy.mode == .armed,
               "Pairing selesai saat auto-connect ON membuat mode armed")

        // User tekan Putuskan/Jeda manual -> dijeda sementara (tidak melawan user).
        policy.userDidDisconnect()
        expect(!policy.shouldBeStandby && policy.mode == .paused,
               "Putuskan manual menjeda auto-connect sementara")

        // User tekan Hubungkan -> mencabut jeda.
        policy.userDidConnect()
        expect(policy.shouldBeStandby && policy.mode == .armed,
               "Hubungkan manual mencabut jeda auto-connect")

        // Toggle OFF saat sedang standby -> harus menghentikan standby.
        let stopAction = policy.setEnabled(false, isCurrentlyConnectedOrConnecting: false, isCurrentlyStandby: true)
        expect(stopAction == .stopStandby && !policy.shouldBeStandby && policy.mode == .off,
               "Mematikan auto-connect saat standby menghentikan pending connect")

        // Toggle ON saat idle dengan pairing -> memulai standby.
        let startAction = policy.setEnabled(true, isCurrentlyConnectedOrConnecting: false, isCurrentlyStandby: false)
        expect(startAction == .startStandby && policy.shouldBeStandby,
               "Menyalakan auto-connect saat idle memulai standby pasif")

        // Toggle ON saat sudah streaming -> tidak mengganggu koneksi aktif.
        var activePolicy = AutoConnectPolicy(isEnabled: false, hasPairing: true)
        let whileStreaming = activePolicy.setEnabled(true, isCurrentlyConnectedOrConnecting: true, isCurrentlyStandby: false)
        expect(whileStreaming == .none && activePolicy.shouldBeStandby,
               "Menyalakan auto-connect saat streaming tidak restart koneksi")

        // Toggle OFF saat sedang streaming -> tidak memutus sesi aktif.
        let offWhileStreaming = activePolicy.setEnabled(false, isCurrentlyConnectedOrConnecting: true, isCurrentlyStandby: false)
        expect(offWhileStreaming == .none && !activePolicy.shouldBeStandby,
               "Mematikan auto-connect saat streaming tidak memutus sesi aktif")

        // Lupakan pairing saat armed -> hentikan standby.
        let forgetAction = policy.didForgetPairing()
        expect(forgetAction == .stopStandby && !policy.hasPairing && !policy.shouldBeStandby,
               "Lupakan pairing menghentikan mode siaga")
    }

    static func checkAutoRecordLifecycle() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // Default OFF -> streaming tidak memulai rekaman.
        var disabled = AutoRecordCoordinator(isEnabled: false, gracePeriod: .twoMinutes)
        expect(disabled.bleStateChanged(isStreaming: true, isRecording: false, at: t0).isEmpty,
               "Rekam otomatis OFF tidak memulai rekaman saat streaming")

        // Aktif -> streaming langsung memulai rekaman otomatis.
        var coord = AutoRecordCoordinator(
            isEnabled: true,
            gracePeriod: .twoMinutes,
            inactivityTimeout: .off,
            minimumDuration: .oneMinute
        )
        let startCmds = coord.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        expect(startCmds == [.startAutomaticRecording] && coord.ownership == .automatic,
               "Streaming saat auto-record ON memulai rekaman otomatis")
        expect(coord.autoStopDeadline == nil, "Tidak ada countdown saat masih streaming")

        // Putus sesaat (mis. isi bensin / sinyal drop) -> mulai hitung mundur grace period.
        let t1 = t0.addingTimeInterval(600)
        let discCmds = coord.bleStateChanged(isStreaming: false, isRecording: true, at: t1)
        expect(discCmds.isEmpty, "Putus BLE tidak langsung stop sebelum grace period")
        expect(coord.autoStopDeadline == t1.addingTimeInterval(120), "Tenggat grace period tepat 2 menit")

        // Transisi state non-streaming berulang tidak boleh mereset countdown.
        let t1b = t1.addingTimeInterval(30)
        _ = coord.bleStateChanged(isStreaming: false, isRecording: true, at: t1b)
        expect(coord.autoStopDeadline == t1.addingTimeInterval(120),
               "Transisi non-streaming lanjutan tidak mereset hitung mundur")
        expect(coord.remainingGraceSeconds(at: t1.addingTimeInterval(45)) == 75,
               "Sisa waktu grace period dihitung akurat")

        // Sebelum 2 menit belum berhenti.
        expect(coord.tick(isRecording: true, at: t1.addingTimeInterval(119)) == nil,
               "Belum berhenti sebelum grace period habis")

        // Tersambung lagi sebelum grace period habis -> lanjut file yang sama!
        let reconnectCmds = coord.bleStateChanged(isStreaming: true, isRecording: true, at: t1.addingTimeInterval(90))
        expect(reconnectCmds.isEmpty && coord.autoStopDeadline == nil && coord.ownership == .automatic,
               "Sambung ulang sebelum grace period membatalkan auto-stop tanpa memecah file")

        // Putus permanen (parkir) -> melewati 2 menit -> berhenti otomatis!
        let t2 = t1.addingTimeInterval(300)
        _ = coord.bleStateChanged(isStreaming: false, isRecording: true, at: t2)
        let stopCmd = coord.tick(isRecording: true, at: t2.addingTimeInterval(120))
        expect(stopCmd == .stopAutomaticRecording(reason: AutoRecordCoordinator.autoStopReason(for: .twoMinutes)),
               "Melewati grace period memicu berhenti otomatis")
        expect(coord.ownership == .none && coord.autoStopDeadline == nil,
               "State bersih setelah auto-stop")
    }

    static func checkAutoRecordOverridesAndEdgeCases() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. Sleep/suspend berjam-jam melewati grace period (mis. GPS mati/ditolak),
        // lalu motor menyala lagi sore harinya -> tutup file lama DULU lalu mulai file baru!
        var sleepCoord = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .off)
        _ = sleepCoord.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        let parkTime = t0.addingTimeInterval(600)
        _ = sleepCoord.bleStateChanged(isStreaming: false, isRecording: true, at: parkTime)
        let eveningRide = parkTime.addingTimeInterval(9 * 3600)
        let wakeCmds = sleepCoord.bleStateChanged(isStreaming: true, isRecording: true, at: eveningRide)
        expect(wakeCmds == [
            .stopAutomaticRecording(reason: AutoRecordCoordinator.autoStopReason(for: .twoMinutes)),
            .startAutomaticRecording
        ], "Bangun setelah sleep melewati grace period menutup rekaman lama lalu memulai rekaman baru")
        expect(sleepCoord.ownership == .automatic && sleepCoord.autoStopDeadline == nil,
               "Rekaman perjalanan baru aktif tanpa sisa countdown lama")

        // 2. Stop manual saat masih streaming -> TIDAK auto-start lagi di sesi motor yang sama.
        var manualStop = AutoRecordCoordinator(isEnabled: true, gracePeriod: .oneMinute)
        _ = manualStop.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        manualStop.userStoppedRecording()
        expect(manualStop.bleStateChanged(isStreaming: true, isRecording: false, at: t0.addingTimeInterval(5)).isEmpty,
               "Stop manual menahan auto-start pada sesi motor yang sama")
        // Setelah motor sempat putus lalu nyambung lagi -> baru auto-start kembali.
        _ = manualStop.bleStateChanged(isStreaming: false, isRecording: false, at: t0.addingTimeInterval(60))
        expect(manualStop.bleStateChanged(isStreaming: true, isRecording: false, at: t0.addingTimeInterval(120)) == [.startAutomaticRecording],
               "Sesi koneksi motor berikutnya kembali memulai auto-record")

        // 3. Rekaman dimulai manual -> jeda putus BLE TIDAK boleh menghentikannya saat BLE putus.
        var manualRec = AutoRecordCoordinator(isEnabled: true, gracePeriod: .oneMinute, inactivityTimeout: .off)
        manualRec.userStartedManualRecording(supportsActivityCut: true, at: t0)
        _ = manualRec.bleStateChanged(isStreaming: true, isRecording: true, at: t0)
        _ = manualRec.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(10))
        expect(manualRec.disconnectDeadline == nil && manualRec.autoStopDeadline == nil,
               "Rekaman manual tidak memasang tenggat putus BLE")
        expect(manualRec.tick(isRecording: true, at: t0.addingTimeInterval(600)) == nil,
               "Rekaman manual tidak pernah dihentikan oleh jeda putus BLE")

        // 4. Rekaman berhenti karena limit eksternal (20 MB / 6 jam) -> tidak loop mulai baru.
        var limitCoord = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes)
        _ = limitCoord.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        limitCoord.recorderStoppedExternally()
        expect(limitCoord.bleStateChanged(isStreaming: true, isRecording: false, at: t0.addingTimeInterval(1)).isEmpty,
               "Berhenti karena limit/error disk tidak memicu loop auto-start")

        // 5. Mematikan toggle auto-record saat rekaman otomatis aktif -> dialihkan ke manual (tidak putus mendadak).
        var toggleOff = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .off)
        _ = toggleOff.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = toggleOff.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(10))
        expect(toggleOff.setEnabled(false, isRecording: true, at: t0.addingTimeInterval(20)) == nil,
               "Mematikan auto-record tidak menghentikan rekaman yang sedang berjalan")
        expect(toggleOff.ownership == .manual && toggleOff.disconnectDeadline == nil,
               "Rekaman dialihkan ke kendali manual saat auto-record dimatikan")

        // 6. Menyalakan toggle auto-record saat sudah streaming dan belum merekam -> langsung mulai.
        var toggleOn = AutoRecordCoordinator(isEnabled: false, gracePeriod: .twoMinutes)
        _ = toggleOn.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        expect(toggleOn.setEnabled(true, isRecording: false, at: t0.addingTimeInterval(5)) == .startAutomaticRecording,
               "Menyalakan auto-record saat sudah streaming langsung memulai rekaman")

        // 7. Mengubah grace period di tengah countdown langsung menyesuaikan tenggat.
        var graceChange = AutoRecordCoordinator(isEnabled: true, gracePeriod: .fiveMinutes, inactivityTimeout: .off, minimumDuration: .off)
        _ = graceChange.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = graceChange.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(10))
        let shrunk = graceChange.setGracePeriod(.oneMinute, isRecording: true, at: t0.addingTimeInterval(80))
        expect(shrunk == .stopAutomaticRecording(reason: AutoRecordCoordinator.autoStopReason(for: .oneMinute)),
               "Memperpendek grace period di bawah durasi putus yang sudah berlalu langsung menghentikan rekaman")

        // 8. Parsing nilai grace period, inactivity timeout, dan minimum duration fallback aman.
        expect(AutoStopGracePeriod.from(rawSeconds: 999) == .twoMinutes,
               "Nilai grace period tak dikenal kembali ke default 2 menit")
        expect(InactivityCutTimeout.from(rawSeconds: 999) == .fiveMinutes,
               "Nilai batas diam tak dikenal kembali ke default 5 menit")
        expect(InactivityCutTimeout.from(rawSeconds: 0) == .off,
               "Nilai 0 memetakan batas diam ke Mati")
        expect(MinimumRecordingDuration.from(rawSeconds: 999) == .oneMinute,
               "Nilai durasi minimal tak dikenal kembali ke default 1 menit")
        expect(MinimumRecordingDuration.from(rawSeconds: 0) == .off,
               "Nilai 0 memetakan durasi minimal ke Mati")
    }

    static func checkRideActivityTracker() {
        var tracker = RideActivityTracker()

        // Diam dengan mesin idle (1600 rpm, speed 0) -> tidak dianggap aktivitas berkendara.
        let idleEngine = RideActivityInput(
            ecuSpeedKmh: 0, ecuRPM: 1600, ecuKeyOff: false,
            gpsSpeedKmh: 0.4, gpsLatitude: -6.9175, gpsLongitude: 107.6191, gpsHorizontalAccuracy: 5
        )
        expect(!tracker.isActive(idleEngine), "Mesin idle tanpa gerak tidak dianggap aktivitas berkendara")

        // Kunci OFF walau angka ECU tersisa -> tidak aktif.
        let keyOff = RideActivityInput(ecuSpeedKmh: 30, ecuRPM: 4000, ecuKeyOff: true)
        expect(!tracker.isActive(keyOff), "Data ECU saat kunci OFF tidak dianggap aktivitas")

        // Kecepatan ECU >= 2 km/h -> aktif.
        expect(tracker.isActive(RideActivityInput(ecuSpeedKmh: 2.0, ecuRPM: 1800)),
               "Kecepatan ECU >= 2 km/h terdeteksi aktif")

        // Revving/bukaan gas tinggi >= 2800 RPM -> aktif.
        expect(tracker.isActive(RideActivityInput(ecuSpeedKmh: 0, ecuRPM: 2800)),
               "RPM >= 2800 (digas) terdeteksi aktif")

        // GPS speed >= 3 km/h dengan akurasi baik -> aktif.
        expect(tracker.isActive(RideActivityInput(gpsSpeedKmh: 3.2, gpsHorizontalAccuracy: 8)),
               "Kecepatan GPS >= 3 km/h dengan akurasi baik terdeteksi aktif")
        expect(!tracker.isActive(RideActivityInput(gpsSpeedKmh: 1.5, gpsHorizontalAccuracy: 5)),
               "Jitter GPS < 3 km/h tidak dianggap aktif")
        expect(!tracker.isActive(RideActivityInput(gpsSpeedKmh: 25, gpsHorizontalAccuracy: 50)),
               "GPS dengan akurasi buruk (> 30 m) diabaikan")

        // Cadangan perpindahan koordinat GPS (ketika speed nil):
        tracker.reset()
        let anchor = RideActivityInput(gpsLatitude: -6.91750, gpsLongitude: 107.61910, gpsHorizontalAccuracy: 5)
        expect(!tracker.isActive(anchor), "Fix pertama hanya menetapkan jangkar diam")
        let jitter = RideActivityInput(gpsLatitude: -6.91758, gpsLongitude: 107.61910, gpsHorizontalAccuracy: 5) // ~9 m
        expect(!tracker.isActive(jitter), "Perpindahan GPS kecil (~9 m) tetap dianggap diam")
        let moved = RideActivityInput(gpsLatitude: -6.91780, gpsLongitude: 107.61910, gpsHorizontalAccuracy: 5) // ~33 m
        expect(tracker.isActive(moved), "Perpindahan GPS >= 25 m terdeteksi bergerak")

        // Akurasi 25 m membutuhkan perpindahan >= max(25, 37.5) m.
        tracker.reset()
        _ = tracker.isActive(RideActivityInput(gpsLatitude: -6.91750, gpsLongitude: 107.61910, gpsHorizontalAccuracy: 25))
        expect(!tracker.isActive(RideActivityInput(gpsLatitude: -6.91777, gpsLongitude: 107.61910, gpsHorizontalAccuracy: 25)),
               "Perpindahan ~30 m dengan akurasi 25 m masih di bawah ambang adaptif")
        expect(tracker.isActive(RideActivityInput(gpsLatitude: -6.91790, gpsLongitude: 107.61910, gpsHorizontalAccuracy: 25)),
               "Perpindahan ~44 m dengan akurasi 25 m terdeteksi bergerak")
    }

    static func checkIdlingStopProtection() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. Kontak nyala di garasi tanpa pernah jalan (RPM 0, speed 0) -> BUKAN Idling Stop!
        var garageTracker = RideActivityTracker()
        let garageSample = RideActivityInput(isBLEStreaming: true, ecuSpeedKmh: 0, ecuRPM: 0, ecuThrottleDeg: 0, ecuKeyOff: false)
        expect(garageTracker.evaluate(garageSample) == .inactive,
               "Kontak ON di garasi sebelum pernah jalan bukan Idling Stop")

        // 2. Motor sempat jalan & mesin hidup -> berhenti di lampu merah -> SSS mematikan mesin (RPM 0, key ON)
        var sssTracker = RideActivityTracker()
        let riding = RideActivityInput(isBLEStreaming: true, ecuSpeedKmh: 35, ecuRPM: 4500, ecuThrottleDeg: 18, ecuKeyOff: false)
        expect(sssTracker.evaluate(riding) == .active, "Sedang melaju terdeteksi aktif")
        let stoppedIdle = RideActivityInput(isBLEStreaming: true, ecuSpeedKmh: 0, ecuRPM: 1600, ecuThrottleDeg: 0, ecuKeyOff: false)
        expect(sssTracker.evaluate(stoppedIdle) == .inactive, "Baru berhenti dengan mesin idle biasa")
        let sssActive = RideActivityInput(isBLEStreaming: true, ecuSpeedKmh: 0, ecuRPM: 0, ecuThrottleDeg: 0, ecuKeyOff: false)
        expect(sssTracker.evaluate(sssActive) == .idlingStop,
               "Berhenti setelah melaju dengan RPM 0 & kunci ON terdeteksi sebagai Idling Stop (SSS)")

        // Putar gas sedikit (throttle >= 2°) atau mesin nyala kembali dari SSS (0 -> 1600 rpm) -> langsung aktif!
        let throttleWake = RideActivityInput(isBLEStreaming: true, ecuSpeedKmh: 0, ecuRPM: 0, ecuThrottleDeg: 3, ecuKeyOff: false)
        expect(sssTracker.evaluate(throttleWake) == .active, "Bukaan gas >= 2° langsung terdeteksi aktif")
        expect(sssTracker.evaluate(sssActive) == .idlingStop, "Kembali diam RPM 0 tetap terdeteksi Idling Stop")
        let engineRestart = RideActivityInput(isBLEStreaming: true, ecuSpeedKmh: 0, ecuRPM: 1600, ecuThrottleDeg: 0, ecuKeyOff: false)
        expect(sssTracker.evaluate(engineRestart) == .active,
               "Mesin menyala kembali dari SSS (RPM 0 -> 1600) terdeteksi aktif")

        // Kunci OFF (aki < 5 V) bukan Idling Stop!
        let keyOffSample = RideActivityInput(isBLEStreaming: true, ecuSpeedKmh: 0, ecuRPM: 0, ecuThrottleDeg: 0, ecuKeyOff: true)
        expect(sssTracker.evaluate(keyOffSample) == .inactive, "Kunci kontak OFF tidak dianggap Idling Stop")

        // 3. Coordinator: meski potong diam diset 3 menit, Idling Stop selama 6 menit di lampu merah/kereta
        // TIDAK memotong rekaman dan TIDAK memunculkan peringatan countdown prematur!
        var coord = AutoRecordCoordinator(
            isEnabled: true,
            gracePeriod: .twoMinutes,
            inactivityTimeout: .threeMinutes,
            minimumDuration: .oneMinute
        )
        _ = coord.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = coord.processActivity(.active, isRecording: true, at: t0.addingTimeInterval(10))
        _ = coord.processActivity(.active, isRecording: true, at: t0.addingTimeInterval(300))

        // Masuk SSS pada t+305; tetap di SSS hingga t+660 (6 menit > batas normal 3 menit!)
        expect(coord.processActivity(.idlingStop, isRecording: true, at: t0.addingTimeInterval(305)) == nil,
               "Masuk Idling Stop tidak memotong")
        expect(coord.isInIdlingStop, "Status Idling Stop aktif di coordinator")
        expect(coord.processActivity(.idlingStop, isRecording: true, at: t0.addingTimeInterval(660)) == nil,
               "Idling Stop 6 menit tidak terpotong walau batas diam 3 menit")
        expect(coord.visibleAutoStopCountdown(at: t0.addingTimeInterval(660)) == nil,
               "Countdown diam tidak mengganggu UI selama Idling Stop normal")

        // Lampu hijau -> mesin nyala / gas dibuka -> keluar dari SSS dan lanjut 1 file yang sama!
        expect(coord.processActivity(.active, isRecording: true, at: t0.addingTimeInterval(670)) == nil,
               "Keluar dari Idling Stop melanjutkan rekaman tanpa memotong")
        expect(!coord.isInIdlingStop, "Status Idling Stop mati begitu bergerak lagi")

        // 4. Jika lupa kunci ON dalam SSS hingga batas pengaman 15 menit -> muncul di 60 dtk terakhir lalu potong & simpan.
        _ = coord.processActivity(.idlingStop, isRecording: true, at: t0.addingTimeInterval(680))
        expect(coord.visibleAutoStopCountdown(at: t0.addingTimeInterval(670 + 14 * 60 + 10))?.kind == .inactivity,
               "60 detik terakhir sebelum batas pengaman 15 menit menampilkan countdown")
        let safetyCut = coord.processActivity(.idlingStop, isRecording: true, at: t0.addingTimeInterval(670 + 15 * 60))
        expect(safetyCut == .stopAutomaticRecording(reason: AutoRecordCoordinator.inactivityStopReason(for: .threeMinutes)),
               "Batas pengaman 15 menit tetap memotong jika kunci ON benar-benar lupa dimatikan")

        // 5. Jika setelah 6 menit SSS rider mematikan kunci (isi bensin) -> tidak langsung potong retroaktif,
        // tetap memberi grace period putus BLE 2 menit!
        var refuel = AutoRecordCoordinator(
            isEnabled: true,
            gracePeriod: .twoMinutes,
            inactivityTimeout: .threeMinutes,
            minimumDuration: .oneMinute
        )
        _ = refuel.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = refuel.processActivity(.active, isRecording: true, at: t0.addingTimeInterval(10))
        _ = refuel.processActivity(.active, isRecording: true, at: t0.addingTimeInterval(300))
        _ = refuel.processActivity(.idlingStop, isRecording: true, at: t0.addingTimeInterval(660))
        let discCmds = refuel.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(665))
        expect(discCmds.isEmpty && !refuel.isInIdlingStop,
               "Mematikan kunci setelah SSS panjang tidak memotong seketika")
        expect(refuel.tick(isRecording: true, at: t0.addingTimeInterval(720)) == nil,
               "Tetap menghormati jeda putus BLE (mis. isi bensin)")
        expect(refuel.bleStateChanged(isStreaming: true, isRecording: true, at: t0.addingTimeInterval(750)).isEmpty,
               "Menyalakan kembali sebelum grace period habis melanjutkan file yang sama")
    }

    static func checkInactivityAutoCutAndSplit() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. Perjalanan 10 menit -> parkir 5 menit dengan kontak menyala -> potong otomatis ->
        // siaga menunggu bergerak -> mulai gerak lagi -> otomatis mulai segmen rekaman baru!
        var coord = AutoRecordCoordinator(
            isEnabled: true,
            gracePeriod: .twoMinutes,
            inactivityTimeout: .fiveMinutes,
            minimumDuration: .oneMinute
        )
        expect(coord.bleStateChanged(isStreaming: true, isRecording: false, at: t0) == [.startAutomaticRecording],
               "Mulai segmen pertama saat streaming")

        // Bergerak di t+10 dan t+600 (10 menit riding), sempat berhenti 2 menit di tengah (lampu merah).
        expect(coord.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(10)) == nil,
               "Aktivitas awal tidak memicu stop")
        expect(coord.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(120)) == nil,
               "Berhenti 2 menit di lampu merah belum memotong rekaman")
        expect(coord.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(600)) == nil,
               "Aktivitas baru mereset jam diam")

        // Berhenti parkir di t+600; 30 detik pertama countdown belum ditampilkan di UI.
        expect(coord.visibleAutoStopCountdown(at: t0.addingTimeInterval(630)) == nil,
               "Countdown diam belum tampil di UI selama 30 detik pertama (tidak ganggu lampu merah)")
        // Setelah 60 detik diam, countdown diam mulai tampil di UI.
        let visible = coord.visibleAutoStopCountdown(at: t0.addingTimeInterval(660))
        expect(visible?.kind == .inactivity && visible?.deadline == t0.addingTimeInterval(900),
               "Countdown diam tampil setelah 60 detik tidak aktif")

        // 4 menit 59 detik belum dipotong.
        expect(coord.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(899)) == nil,
               "Belum dipotong sebelum 5 menit diam")

        // Tepat 5 menit diam (t+900) -> potong & simpan segmen 1, lalu masuk mode siaga aktivitas!
        let cutCmd = coord.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(900))
        expect(cutCmd == .stopAutomaticRecording(reason: AutoRecordCoordinator.inactivityStopReason(for: .fiveMinutes)),
               "Melewati 5 menit diam memotong dan menyimpan perjalanan")
        expect(coord.ownership == .none && coord.waitingForActivityToRestart,
               "Setelah potong diam saat BLE terhubung, coordinator siaga menunggu aktivitas baru")

        // Selama masih parkir diam, tidak langsung mulai rekaman kosong baru.
        expect(coord.processActivity(isActive: false, isRecording: false, at: t0.addingTimeInterval(1200)) == nil,
               "Tetap diam pasca-potong tidak memulai rekaman kosong")

        // Begitu motor mulai berjalan lagi di t+1500 -> otomatis mulai segmen perjalanan baru!
        let resumeCmd = coord.processActivity(isActive: true, isRecording: false, at: t0.addingTimeInterval(1500))
        expect(resumeCmd == .startAutomaticRecording && coord.ownership == .automatic && !coord.waitingForActivityToRestart,
               "Aktivitas kembali pasca-potong otomatis memulai segmen rekaman baru")

        // 2. Jika putus BLE saat sedang siaga pasca-potong -> siaga direset, koneksi berikutnya mulai normal.
        var waitDisconnect = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .threeMinutes, minimumDuration: .off)
        _ = waitDisconnect.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = waitDisconnect.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(5))
        _ = waitDisconnect.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(185))
        expect(waitDisconnect.waitingForActivityToRestart, "Siaga setelah potong 3 menit")
        _ = waitDisconnect.bleStateChanged(isStreaming: false, isRecording: false, at: t0.addingTimeInterval(200))
        expect(!waitDisconnect.waitingForActivityToRestart, "Disconnect membersihkan status siaga pasca-potong")
        expect(waitDisconnect.bleStateChanged(isStreaming: true, isRecording: false, at: t0.addingTimeInterval(260)) == [.startAutomaticRecording],
               "Koneksi baru kembali memulai auto-record seperti biasa")

        // 3. Rekaman CSV manual yang lupa dimatikan juga dipotong otomatis saat diam lama.
        var manualCSV = AutoRecordCoordinator(isEnabled: false, gracePeriod: .twoMinutes, inactivityTimeout: .threeMinutes, minimumDuration: .thirtySeconds)
        manualCSV.userStartedManualRecording(supportsActivityCut: true, at: t0)
        _ = manualCSV.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(5))
        _ = manualCSV.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(120))
        let manualCut = manualCSV.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(300))
        expect(manualCut == .stopAutomaticRecording(reason: AutoRecordCoordinator.inactivityStopReason(for: .threeMinutes)),
               "Rekaman CSV manual yang lupa dimatikan ikut dipotong otomatis saat diam")
        expect(!manualCSV.waitingForActivityToRestart,
               "Rekaman manual yang terpotong tidak otomatis restart sendiri")

        // 4. Rekaman BLE Mentah (RAW) TIDAK pernah dipotong otomatis oleh timer diam.
        var rawRec = AutoRecordCoordinator(isEnabled: false, gracePeriod: .twoMinutes, inactivityTimeout: .threeMinutes, minimumDuration: .oneMinute)
        rawRec.userStartedManualRecording(supportsActivityCut: false, at: t0)
        expect(rawRec.inactivityDeadline == nil, "BLE mentah tidak memasang tenggat diam")
        expect(rawRec.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(3600)) == nil,
               "BLE mentah tidak pernah dipotong karena tidak ada aktivitas")

        // 5. Jika kedua tenggat aktif (putus BLE & diam), yang lebih cepat tiba menang.
        var race = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .fiveMinutes, minimumDuration: .off)
        _ = race.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = race.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(100))
        // Diam sejak t+100 (tenggat diam t+400); putus BLE di t+370 (tenggat putus t+490) -> diam menang di t+400!
        _ = race.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(370))
        expect(race.nextAutoStopCountdown == AutoStopCountdown(deadline: t0.addingTimeInterval(400), kind: .inactivity),
               "Tenggat diam lebih dekat harus menang atas tenggat putus BLE")
        let raceCmd = race.tick(isRecording: true, at: t0.addingTimeInterval(400))
        expect(raceCmd == .stopAutomaticRecording(reason: AutoRecordCoordinator.inactivityStopReason(for: .fiveMinutes)),
               "Perintah stop mengikuti tenggat yang lebih dulu tercapai")

        // 6. Memperpendek batas diam di tengah kondisi diam langsung memotong.
        var shrinkIdle = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .tenMinutes, minimumDuration: .off)
        _ = shrinkIdle.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = shrinkIdle.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(10))
        let shrunkCmd = shrinkIdle.setInactivityTimeout(.threeMinutes, isRecording: true, at: t0.addingTimeInterval(200))
        expect(shrunkCmd == .stopAutomaticRecording(reason: AutoRecordCoordinator.inactivityStopReason(for: .threeMinutes)),
               "Memperpendek batas diam di bawah durasi diam berjalan langsung memotong")
    }

    static func checkMinimumDurationDiscard() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. Kontak nyala sebentar 15 detik lalu mati (putus BLE) -> setelah grace period 2 menit,
        // durasi efektif tetap 15 detik (< 1 menit) -> BUANG otomatis (tidak jadi record)!
        var shortDisconnect = AutoRecordCoordinator(
            isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .fiveMinutes, minimumDuration: .oneMinute
        )
        _ = shortDisconnect.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = shortDisconnect.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(15))
        let discardDisc = shortDisconnect.tick(isRecording: true, at: t0.addingTimeInterval(135))
        expect(discardDisc == .discardAutomaticRecording(reason: AutoRecordCoordinator.autoDiscardReason(for: .disconnected, minimumDuration: .oneMinute)),
               "Sesi 15 detik yang putus BLE dibuang otomatis meski grace period 2 menit")

        // 2. Kontak nyala di garasi tanpa pernah bergerak selama 5 menit -> potong diam ->
        // durasi aktif 0 detik (< 1 menit) -> BUANG otomatis!
        var idleGarage = AutoRecordCoordinator(
            isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .fiveMinutes, minimumDuration: .oneMinute
        )
        _ = idleGarage.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        let discardIdle = idleGarage.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(300))
        expect(discardIdle == .discardAutomaticRecording(reason: AutoRecordCoordinator.autoDiscardReason(for: .inactivity, minimumDuration: .oneMinute)),
               "Kontak nyala diam 5 menit di garasi tanpa gerak dibuang otomatis")
        expect(idleGarage.waitingForActivityToRestart,
               "Setelah buang otomatis karena diam, tetap siaga menunggu aktivitas jika nanti mulai jalan")

        // 3. Diam 3 menit, geser motor 10 detik, lalu diam lagi 5 menit -> rentang aktif hanya 10 detik -> BUANG!
        var briefMove = AutoRecordCoordinator(
            isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .fiveMinutes, minimumDuration: .oneMinute
        )
        _ = briefMove.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = briefMove.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(180))
        _ = briefMove.processActivity(isActive: true, isRecording: true, at: t0.addingTimeInterval(190))
        let discardBrief = briefMove.processActivity(isActive: false, isRecording: true, at: t0.addingTimeInterval(490))
        expect(discardBrief == .discardAutomaticRecording(reason: AutoRecordCoordinator.autoDiscardReason(for: .inactivity, minimumDuration: .oneMinute)),
               "Geser motor 10 detik saja lalu diam 5 menit tetap dibuang otomatis")

        // 4. Bangun dari sleep berjam-jam setelah sesi singkat 20 detik -> buang sesi lama lalu mulai sesi baru!
        var shortSleep = AutoRecordCoordinator(
            isEnabled: true, gracePeriod: .twoMinutes, inactivityTimeout: .fiveMinutes, minimumDuration: .oneMinute
        )
        _ = shortSleep.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = shortSleep.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(20))
        let wakeShort = shortSleep.bleStateChanged(isStreaming: true, isRecording: true, at: t0.addingTimeInterval(3600))
        expect(wakeShort == [
            .discardAutomaticRecording(reason: AutoRecordCoordinator.autoDiscardReason(for: .disconnected, minimumDuration: .oneMinute)),
            .startAutomaticRecording
        ], "Bangun dari sleep membuang sesi lama yang terlalu singkat lalu memulai sesi baru")

        // 5. Stop manual CSV yang masih singkat (< 1 menit):
        // allowDiscardIfTooShort = true -> buang; allowDiscardIfTooShort = false -> simpan.
        var manualShort = AutoRecordCoordinator(isEnabled: false, minimumDuration: .oneMinute)
        manualShort.userStartedManualRecording(supportsActivityCut: true, at: t0)
        expect(manualShort.shouldDiscard(for: nil, at: t0.addingTimeInterval(20)),
               "Rekaman CSV manual 20 detik terdeteksi terlalu singkat")
        let reason = manualShort.userStoppedRecording(allowDiscardIfTooShort: true, at: t0.addingTimeInterval(20))
        expect(reason == AutoRecordCoordinator.shortManualDiscardReason(for: .oneMinute),
               "Stop & Buang mengembalikan alasan pembuangan")

        manualShort.userStartedManualRecording(supportsActivityCut: true, at: t0)
        let keepReason = manualShort.userStoppedRecording(allowDiscardIfTooShort: false, at: t0.addingTimeInterval(20))
        expect(keepReason == nil, "Tetap Simpan tidak membuang rekaman manual singkat")

        // 6. BLE mentah (RAW) tidak pernah dianggap terlalu singkat.
        var rawShort = AutoRecordCoordinator(isEnabled: false, minimumDuration: .twoMinutes)
        rawShort.userStartedManualRecording(supportsActivityCut: false, at: t0)
        expect(!rawShort.shouldDiscard(for: nil, at: t0.addingTimeInterval(5)),
               "BLE mentah 5 detik tidak dianggap terlalu singkat")

        // 7. Jika minimumDuration == .off -> sesi 5 detik tetap disimpan.
        var minOff = AutoRecordCoordinator(isEnabled: true, gracePeriod: .oneMinute, inactivityTimeout: .off, minimumDuration: .off)
        _ = minOff.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = minOff.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(5))
        let keepShort = minOff.tick(isRecording: true, at: t0.addingTimeInterval(65))
        expect(keepShort == .stopAutomaticRecording(reason: AutoRecordCoordinator.autoStopReason(for: .oneMinute)),
               "Saat durasi minimal dimatikan, sesi singkat tetap disimpan")
    }

    static func checkReconnectBackoff() {
        var backoff = ReconnectBackoff()
        expect(backoff.nextDelay() == 3, "Delay kegagalan #1 adalah 3 detik")
        expect(backoff.nextDelay() == 10, "Delay kegagalan #2 adalah 10 detik")
        expect(backoff.nextDelay() == 30, "Delay kegagalan #3 adalah 30 detik")
        expect(backoff.nextDelay() == 60, "Delay kegagalan #4 adalah 60 detik")
        expect(backoff.nextDelay() == 60, "Delay tetap dibatasi maksimal 60 detik")
        backoff.reset()
        expect(backoff.consecutiveFailures == 0 && backoff.nextDelay() == 3,
               "Reset setelah streaming mengembalikan delay ke awal")
    }

    static func checkSessionRecorderAutoStopIntegration() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("telaerox-auto-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = SessionRecorder(library: RecordingLibrary(directory: dir))
        let url = recorder.start(format: .csv, includesMotionAndBarometer: false, placement: .pocket)
        expect(url != nil && recorder.isRecording, "Recorder mulai sesi CSV otomatis")
        let reason = AutoRecordCoordinator.autoStopReason(for: .twoMinutes)
        recorder.stop(reason: reason)
        expect(!recorder.isRecording && recorder.stopReason == reason,
               "Alasan berhenti otomatis tersimpan di recorder")
        expect(recorder.library.sessions.first?.stopReason == reason,
               "Alasan berhenti otomatis tersimpan di indeks riwayat")

        // Integrasi discard(reason:): hapus file di disk, hapus dari RecordingLibrary, tampilkan notice.
        let shortURL = recorder.start(format: .csv, includesMotionAndBarometer: false, placement: .pocket)!
        expect(FileManager.default.fileExists(atPath: shortURL.path), "File sesi singkat dibuat saat start")
        let countBeforeDiscard = recorder.library.sessions.count
        let discardReason = AutoRecordCoordinator.autoDiscardReason(for: .inactivity, minimumDuration: .oneMinute)
        recorder.discard(reason: discardReason)
        expect(!recorder.isRecording && recorder.fileURL == nil && recorder.lastDiscardedNotice == discardReason,
               "Discard menghentikan sesi, mengosongkan fileURL, dan mengisi pemberitahuan")
        expect(!FileManager.default.fileExists(atPath: shortURL.path),
               "File sesi terlalu singkat benar-benar terhapus dari disk")
        expect(recorder.library.sessions.count == countBeforeDiscard - 1
               && !recorder.library.sessions.contains(where: { $0.fileName == shortURL.lastPathComponent }),
               "Entri sesi terlalu singkat terhapus dari indeks riwayat")

        // Memulai rekaman baru membersihkan lastDiscardedNotice.
        _ = recorder.start(format: .csv, includesMotionAndBarometer: false, placement: .pocket)
        expect(recorder.lastDiscardedNotice == nil, "Mulai rekaman baru membersihkan pesan buang sebelumnya")
        recorder.stop()
    }
}
