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
        checkReconnectBackoff()
        checkSessionRecorderAutoStopIntegration()
        print("Lulus \(checks) pemeriksaan otomatisasi auto-connect, auto-record, grace period, dan backoff.")
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
        var coord = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes)
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
        var sleepCoord = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes)
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

        // 3. Rekaman dimulai manual -> auto-stop TIDAK boleh menghentikannya saat BLE putus.
        var manualRec = AutoRecordCoordinator(isEnabled: true, gracePeriod: .oneMinute)
        manualRec.userStartedManualRecording()
        _ = manualRec.bleStateChanged(isStreaming: true, isRecording: true, at: t0)
        _ = manualRec.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(10))
        expect(manualRec.autoStopDeadline == nil, "Rekaman manual tidak memasang tenggat auto-stop")
        expect(manualRec.tick(isRecording: true, at: t0.addingTimeInterval(600)) == nil,
               "Rekaman manual tidak pernah dihentikan oleh auto-stop")

        // 4. Rekaman berhenti karena limit eksternal (20 MB / 6 jam) -> tidak loop mulai baru.
        var limitCoord = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes)
        _ = limitCoord.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        limitCoord.recorderStoppedExternally()
        expect(limitCoord.bleStateChanged(isStreaming: true, isRecording: false, at: t0.addingTimeInterval(1)).isEmpty,
               "Berhenti karena limit/error disk tidak memicu loop auto-start")

        // 5. Mematikan toggle auto-record saat rekaman otomatis aktif -> dialihkan ke manual (tidak putus mendadak).
        var toggleOff = AutoRecordCoordinator(isEnabled: true, gracePeriod: .twoMinutes)
        _ = toggleOff.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = toggleOff.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(10))
        expect(toggleOff.setEnabled(false, isRecording: true, at: t0.addingTimeInterval(20)) == nil,
               "Mematikan auto-record tidak menghentikan rekaman yang sedang berjalan")
        expect(toggleOff.ownership == .manual && toggleOff.autoStopDeadline == nil,
               "Rekaman dialihkan ke kendali manual saat auto-record dimatikan")

        // 6. Menyalakan toggle auto-record saat sudah streaming dan belum merekam -> langsung mulai.
        var toggleOn = AutoRecordCoordinator(isEnabled: false, gracePeriod: .twoMinutes)
        _ = toggleOn.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        expect(toggleOn.setEnabled(true, isRecording: false, at: t0.addingTimeInterval(5)) == .startAutomaticRecording,
               "Menyalakan auto-record saat sudah streaming langsung memulai rekaman")

        // 7. Mengubah grace period di tengah countdown langsung menyesuaikan tenggat.
        var graceChange = AutoRecordCoordinator(isEnabled: true, gracePeriod: .fiveMinutes)
        _ = graceChange.bleStateChanged(isStreaming: true, isRecording: false, at: t0)
        _ = graceChange.bleStateChanged(isStreaming: false, isRecording: true, at: t0.addingTimeInterval(10))
        let shrunk = graceChange.setGracePeriod(.oneMinute, isRecording: true, at: t0.addingTimeInterval(80))
        expect(shrunk == .stopAutomaticRecording(reason: AutoRecordCoordinator.autoStopReason(for: .oneMinute)),
               "Memperpendek grace period di bawah durasi putus yang sudah berlalu langsung menghentikan rekaman")

        // 8. Parsing nilai grace period fallback aman.
        expect(AutoStopGracePeriod.from(rawSeconds: 999) == .twoMinutes,
               "Nilai grace period tak dikenal kembali ke default 2 menit")
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
    }
}
