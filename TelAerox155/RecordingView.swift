import SwiftUI
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// Halaman "Rekam Sesi" — dipisah dari sheet Log Diagnostik (dulu dua hal ini
/// nyampur di satu sheet dan membingungkan: toggle log, format, tombol rekam,
/// dan tombol salin/bagikan log semuanya berdempetan tanpa hierarki jelas).
///
/// Alurnya sekarang satu arah dari atas ke bawah:
/// 1. Kartu kontrol — pilih jenis rekaman → "Mulai Rekam", atau (saat merekam)
///    timer besar + statistik + "Stop".
/// 2. Kartu "Tersimpan" — muncul begitu rekaman berhenti, langsung bisa dibuka.
/// 3. Riwayat — SEMUA sesi yang pernah direkam (permanen, lihat
///    `RecordingLibrary`), tap untuk detail/ringkasan/bagikan.
struct RecordingView: View {
    @ObservedObject var store: TelemetryStore
    @ObservedObject var recorder: SessionRecorder
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var location: LocationProvider
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    @AppStorage("recordFormat") private var formatRaw: String = SessionRecorder.Format.csv.rawValue
    @State private var confirmStop = false
    @State private var pendingDelete: RecordingSession?
    @State private var shareURL: URL?
    @State private var path: [String] = []
    /// Sesi yang barusan selesai direkam — ditampilkan sebagai kartu
    /// "Tersimpan" di atas riwayat sampai sheet ditutup.
    @State private var justSavedID: String?
    @State private var startFailed = false

    private var selectedFormat: SessionRecorder.Format {
        SessionRecorder.Format(rawValue: formatRaw) ?? .csv
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if recorder.isRecording {
                        RecordingLiveCard(store: store, recorder: recorder, location: location,
                                          accent: accent) { confirmStop = true }
                    } else {
                        startCard
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if let id = justSavedID, !recorder.isRecording,
                   let saved = library.sessions.first(where: { $0.id == id }) {
                    Section {
                        savedCard(saved)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                }

                historySection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(RecordingPalette.background.ignoresSafeArea())
            .navigationTitle("Rekam Sesi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { id in
                RecordingDetailView(sessionID: id, recorder: recorder, library: library, accent: accent)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Tangkap file yang ditambah/dihapus lewat app Files sejak terakhir dibuka.
            library.reload(activeFileName: recorder.isRecording ? recorder.fileURL?.lastPathComponent : nil)
        }
        .onChange(of: recorder.isRecording) { wasRecording, isRecording in
            if wasRecording && !isRecording {
                justSavedID = recorder.fileURL?.lastPathComponent
            } else if isRecording {
                justSavedID = nil
            }
        }
        .confirmationDialog("Hentikan rekaman?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop & Simpan", role: .destructive) { recorder.stop() }
            Button("Lanjut Merekam", role: .cancel) {}
        } message: {
            Text("Data yang sudah terekam tetap tersimpan permanen di Riwayat.")
        }
        .confirmationDialog("Hapus rekaman ini?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { session in
            Button("Hapus Permanen", role: .destructive) {
                if justSavedID == session.id { justSavedID = nil }
                library.delete(session)
            }
            Button("Batal", role: .cancel) {}
        } message: { session in
            Text("\"\(session.displayTitle)\" akan dihapus dari HP dan tidak bisa dikembalikan.")
        }
        .alert("Gagal memulai rekaman", isPresented: $startFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("File rekaman tidak bisa dibuat. Cek sisa penyimpanan HP.")
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) },
                             set: { shareURL = $0?.url })) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
    }

    // MARK: - Mulai rekam

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mau rekam apa?")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(SessionRecorder.Format.allCases) { f in
                formatOption(f)
            }

            connectionHint

            if selectedFormat == .csv {
                GPSStatusRow(location: location, accent: accent, requestingOnStart: true)
            }

            Button {
                if recorder.start(format: selectedFormat) == nil { startFailed = true }
            } label: {
                Label("Mulai Rekam", systemImage: "record.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(RecordingPalette.red, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            Text("Tetap jalan walau layar dikunci. Berhenti otomatis setelah 6 jam atau 20 MB. Setiap sesi tersimpan permanen di Riwayat di bawah.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RecordingPalette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func formatOption(_ f: SessionRecorder.Format) -> some View {
        let selected = f == selectedFormat
        return Button {
            formatRaw = f.rawValue
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: f.icon)
                    .font(.title3)
                    .foregroundStyle(selected ? accent : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(f.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if f == .csv {
                            Text("Disarankan")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(accent)
                                .background(accent.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(f.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? accent : .white.opacity(0.25))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? accent.opacity(0.12) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? accent : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var connectionHint: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isActive ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(store.isActive ? .green : .orange)
            Text(store.isActive
                 ? "Motor terhubung — data langsung masuk begitu mulai."
                 : "Motor belum terhubung. Rekaman tetap bisa dimulai; data masuk begitu tersambung.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tersimpan

    private func savedCard(_ s: RecordingSession) -> some View {
        Button { path.append(s.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: s.stopReason == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(s.stopReason == nil ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rekaman tersimpan")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(s.stopReason ?? RecordingFormat.summaryLine(s))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Text("Buka")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Riwayat

    private var historySection: some View {
        Section {
            if library.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Belum ada rekaman")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text("Sesi yang kamu rekam akan muncul di sini dan tidak hilang walau app ditutup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(RecordingPalette.card)
            } else {
                ForEach(library.sessions) { s in
                    let isActive = recorder.isRecording && recorder.fileURL?.lastPathComponent == s.id
                    NavigationLink(value: s.id) {
                        RecordingRow(session: s, isActive: isActive, liveBytes: recorder.bytesWritten,
                                     accent: accent)
                    }
                    .listRowBackground(RecordingPalette.card)
                    .swipeActions(edge: .trailing) {
                        if !isActive {
                            Button(role: .destructive) { pendingDelete = s } label: {
                                Label("Hapus", systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !isActive, let url = library.url(for: s) {
                            Button { shareURL = url } label: {
                                Label("Bagikan", systemImage: "square.and.arrow.up")
                            }
                            .tint(accent)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Riwayat")
                Spacer()
                if !library.sessions.isEmpty {
                    Text("\(library.sessions.count) sesi")
                }
            }
        } footer: {
            if !library.sessions.isEmpty {
                Text("Geser kanan untuk bagikan, geser kiri untuk hapus. File juga bisa dibuka di app Files › Di iPhone Saya › TelAerox.")
            }
        }
    }
}

// MARK: - Kartu saat merekam

/// Dipisah jadi View sendiri supaya TimelineView 1 Hz cuma me-render ulang
/// kartu ini, bukan seluruh List riwayat.
private struct RecordingLiveCard: View {
    @ObservedObject var store: TelemetryStore
    @ObservedObject var recorder: SessionRecorder
    @ObservedObject var location: LocationProvider
    let accent: Color
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(RecordingPalette.red)
                    .symbolEffect(.pulse, options: .repeating)
                Text("SEDANG MEREKAM")
                    .font(.caption.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(RecordingPalette.red)
                Spacer()
                Label(recorder.format.title, systemImage: recorder.format.icon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: recorder.startedAt ?? .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(recorder.startedAt ?? context.date)
                Text(RecordingFormat.clock(elapsed))
                    .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                stat(recorder.format == .csv ? "Baris data" : "Frame",
                     value: recorder.lineCount.formatted())
                stat("Ukuran", value: RecordingFormat.size(recorder.bytesWritten))
                stat("Motor", value: store.isActive ? "Terhubung" : "Terputus",
                     color: store.isActive ? .green : .orange)
            }

            if !store.isActive {
                Text(recorder.format == .csv
                     ? "Motor tidak terhubung — baris data tidak ditulis sampai tersambung lagi. Timer tetap jalan."
                     : "Motor tidak terhubung — belum ada frame masuk.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if recorder.format == .csv {
                GPSStatusRow(location: location, accent: accent, requestingOnStart: false)
            }

            Button(action: onStop) {
                Label("Stop Rekam", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(RecordingPalette.red.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(RecordingPalette.red.opacity(0.4), lineWidth: 1)
        )
    }

    private func stat(_ title: String, value: String, color: Color = .white) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Baris riwayat

private struct RecordingRow: View {
    let session: RecordingSession
    let isActive: Bool
    let liveBytes: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.format.icon)
                .font(.body)
                .foregroundStyle(isActive ? RecordingPalette.red : accent)
                .frame(width: 36, height: 36)
                .background((isActive ? RecordingPalette.red : accent).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if isActive {
                    Text("Sedang merekam • \(RecordingFormat.size(liveBytes))")
                        .font(.caption)
                        .foregroundStyle(RecordingPalette.red)
                } else {
                    Text(RecordingFormat.summaryLine(session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if session.stopReason != nil && !isActive {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail sesi

struct RecordingDetailView: View {
    let sessionID: String
    @ObservedObject var recorder: SessionRecorder
    @ObservedObject var library: RecordingLibrary
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    @State private var analysis: TripAnalysis?
    /// Kursor waktu bersama peta/chart/replay — dibuat begitu analisis siap.
    @State private var playback: TripPlayback?
    /// Mulai `true` supaya frame pertama langsung menampilkan indikator
    /// loading — kalau `false`, sebelum `.task` sempat jalan layar sempat
    /// berkedip "Belum ada baris data" padahal file-nya belum dibaca.
    @State private var loadingSummary = true
    @State private var showShareCard = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var renameText = ""

    private var session: RecordingSession? {
        library.sessions.first { $0.id == sessionID }
    }

    private var isActive: Bool {
        recorder.isRecording && recorder.fileURL?.lastPathComponent == sessionID
    }

    var body: some View {
        Group {
            if let s = session {
                content(s)
            } else {
                ContentUnavailableView("Rekaman tidak ditemukan", systemImage: "questionmark.folder",
                                       description: Text("File-nya mungkin sudah dihapus lewat app Files."))
            }
        }
        .background(RecordingPalette.background.ignoresSafeArea())
        .navigationTitle("Detail Rekaman")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session?.endedAt) { await loadSummary() }
        .safeAreaInset(edge: .bottom) {
            if let playback, let s = session, s.format == .csv, !isActive {
                TripPlaybackBar(playback: playback, accent: accent)
            }
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) },
                             set: { shareURL = $0?.url })) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
        .sheet(isPresented: $showShareCard) {
            if let a = analysis, let s = session {
                TripShareCardSheet(analysis: a, session: s, accent: accent)
            }
        }
        .alert("Ganti nama", isPresented: $showRename) {
            TextField("mis. Tes tanjakan Dago", text: $renameText)
            Button("Simpan") {
                if let s = session { library.rename(s, to: renameText) }
            }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("Kosongkan untuk pakai tanggal & jam sebagai nama.")
        }
        .confirmationDialog("Hapus rekaman ini?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Hapus Permanen", role: .destructive) {
                if let s = session { library.delete(s) }
                dismiss()
            }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("File akan dihapus dari HP dan tidak bisa dikembalikan.")
        }
    }

    private func content(_ s: RecordingSession) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: s.format.icon)
                            .foregroundStyle(accent)
                        Text(s.format.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                        if isActive {
                            Text("• SEDANG MEREKAM")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(RecordingPalette.red)
                        }
                    }
                    Button {
                        renameText = s.title ?? ""
                        showRename = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.displayTitle)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Text(RecordingFormat.timeRange(s))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(RecordingPalette.card)

            if let reason = s.stopReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .listRowBackground(RecordingPalette.card)
            }

            if s.format == .csv && !isActive {
                analysisSections
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    tile("Durasi", s.duration.map(RecordingFormat.duration) ?? "Berjalan…", icon: "timer")
                    tile("Ukuran", RecordingFormat.size(isActive ? recorder.bytesWritten : s.bytes), icon: "internaldrive")
                    tile(s.format == .csv ? "Baris data" : "Frame",
                         lineCountText(s), icon: "list.number")
                    tile("Format file", s.format.fileExtension.uppercased(), icon: "doc")
                }
                .padding(.vertical, 4)
            } header: {
                if analysis != nil { Text("File") }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))


            Section {
                Button {
                    shareURL = library.url(for: s)
                } label: {
                    Label("Bagikan / Simpan ke Files", systemImage: "square.and.arrow.up")
                }
                .disabled(isActive)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Hapus Rekaman", systemImage: "trash")
                }
                .disabled(isActive)
            } footer: {
                Text(isActive
                     ? "Stop rekaman dulu untuk membagikan atau menghapus."
                     : "Nama file: \(s.fileName)")
                    .font(.caption2.monospaced())
            }
            .listRowBackground(RecordingPalette.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Semua bagian hasil analisis CSV: peta, statistik, chart, CVT, gaya
    /// berkendara, distribusi, info kendaraan, catatan data.
    @ViewBuilder
    private var analysisSections: some View {
        if let a = analysis, let playback, !a.samples.isEmpty {
            if a.hasRoute {
                Section {
                    TripMapCard(analysis: a, playback: playback, accent: accent)
                        .padding(.vertical, 6)
                }
                .listRowBackground(RecordingPalette.card)
            }

            Section {
                TripStatsGrid(analysis: a)
                    .padding(.vertical, 4)
                Button {
                    playback.pause()
                    showShareCard = true
                } label: {
                    Label("Buat Kartu Sosmed", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.black)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            Section {
                TripTimelineCharts(analysis: a, playback: playback)
            } header: {
                Text("Grafik")
            } footer: {
                Text("Geser mendatar atau tap di grafik untuk menggeser kursor — peta dan grafik lain ikut. Tekan ▶︎ untuk replay.")
            }
            .listRowBackground(RecordingPalette.card)

            if a.cvtPoints.count >= 10 {
                Section {
                    TripCVTChart(analysis: a, playback: playback)
                }
                .listRowBackground(RecordingPalette.card)
            }

            if !a.modeSeconds.isEmpty {
                Section {
                    TripModeBreakdown(analysis: a)
                }
                .listRowBackground(RecordingPalette.card)
            }

            if !a.speedHistogram.isEmpty || !a.rpmHistogram.isEmpty {
                Section {
                    TripHistogramCard(analysis: a)
                }
                .listRowBackground(RecordingPalette.card)
            }

            if a.vin != nil || a.hasECU {
                Section("Kendaraan") {
                    TripVehicleInfo(analysis: a)
                }
                .listRowBackground(RecordingPalette.card)
            }

            if a.rowsBeforeECU + a.rowsAfterKeyOff + a.gpsRejected > 0 || a.fuelMl != nil
                || a.speedoErrorPercent != nil {
                Section("Catatan data") {
                    TripDataNotes(analysis: a)
                }
                .listRowBackground(RecordingPalette.card)
            }
        } else if loadingSummary {
            Section {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(accent)
                    Text("Menganalisis rekaman…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(loadingHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
            .listRowBackground(RecordingPalette.card)
        } else {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Belum ada baris data — motor mungkin tidak terhubung selama rekaman.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await loadSummary() }
                    } label: {
                        Label("Muat ulang", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(accent)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(RecordingPalette.card)
        }
    }

    private func tile(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RecordingPalette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func lineCountText(_ s: RecordingSession) -> String {
        if isActive { return recorder.lineCount.formatted() }
        if s.lineCount > 0 { return s.lineCount.formatted() }
        // Rekaman versi lama tidak punya hitungan di indeks — pakai hasil
        // ringkasan CSV kalau sudah ada.
        if let rows = analysis?.rawRows { return rows.formatted() }
        return "—"
    }

    /// Keterangan di bawah spinner — rekaman panjang (puluhan MB) butuh
    /// beberapa detik untuk di-parse, jadi kasih tahu ukurannya.
    private var loadingHint: String {
        guard let s = session, s.bytes > 0 else { return "Membaca file log…" }
        return "Membaca \(RecordingFormat.size(s.bytes)) data log. Rekaman panjang bisa butuh beberapa detik."
    }

    private func loadSummary() async {
        guard let s = session, s.format == .csv, !isActive, let url = library.url(for: s) else {
            loadingSummary = false
            return
        }
        loadingSummary = true
        let result = await Task.detached(priority: .userInitiated) { TripAnalysis.load(from: url) }.value
        // `.task(id:)` membatalkan task lama saat `endedAt` berubah (mis.
        // `library.reload()` menandai sesi yang terhenti) lalu menjalankan
        // yang baru. Task.detached tidak ikut batal, jadi hasil task lama
        // tetap datang belakangan — abaikan supaya tidak mematikan spinner
        // milik load yang baru / menimpa hasilnya dengan data basi.
        guard !Task.isCancelled else { return }
        playback?.pause()
        analysis = result
        playback = result.map { TripPlayback(analysis: $0) }
        loadingSummary = false
    }
}

// MARK: - Tombol header

/// Tombol "Rekam" di header ContentView — ikon biasa saat idle, berubah jadi
/// pil merah berisi timer saat merekam, supaya status rekaman selalu kelihatan
/// dari layar utama tanpa harus membuka sheet.
struct RecordHeaderButton: View {
    @ObservedObject var recorder: SessionRecorder
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if recorder.isRecording {
                TimelineView(.periodic(from: recorder.startedAt ?? .now, by: 1)) { context in
                    HStack(spacing: 5) {
                        Circle().fill(.white).frame(width: 7, height: 7)
                        Text(RecordingFormat.clock(context.date.timeIntervalSince(recorder.startedAt ?? context.date)))
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RecordingPalette.red, in: Capsule())
                }
            } else {
                Image(systemName: "record.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Sedang merekam — buka halaman rekam" : "Rekam sesi")
    }
}

// MARK: - GPS

/// Status GPS buat kolom gps_* di CSV — GPS baru benar-benar nyala saat
/// rekaman CSV berjalan (lihat TelemetryStore.bindRecorderToLocation), jadi
/// baris ini juga jadi indikator "kenapa kolom gps_* di CSV kosong" kalau izin
/// belum diberikan atau belum ada fix.
struct GPSStatusRow: View {
    @ObservedObject var location: LocationProvider
    let accent: Color
    /// true = ditampilkan SEBELUM rekaman mulai (GPS belum nyala).
    let requestingOnStart: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill")
                .font(.caption)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if location.authorizationStatus == .denied || location.authorizationStatus == .restricted
                || location.authorizationStatus == .authorizedWhenInUse {
                Button("Pengaturan") {
                    #if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .buttonStyle(.plain)
            }
        }
    }

    private var color: Color {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if requestingOnStart { return .green }
            return location.lastLocation != nil ? .green : .orange
        case .denied, .restricted:
            return .red
        default:
            return .secondary
        }
    }

    private var text: String {
        switch location.authorizationStatus {
        case .denied, .restricted:
            return "Izin lokasi ditolak — rekaman jalan tanpa GPS."
        case .notDetermined:
            return "Izin lokasi akan diminta saat rekaman dimulai (untuk kolom GPS)."
        case .authorizedWhenInUse:
            // Dengan izin ini pun GPS tetap lanjut di background SELAMA
            // update-nya dimulai di foreground (persis yang dilakukan tombol
            // "Mulai Rekam") — "Selalu" cuma lebih pasti.
            let base = requestingOnStart ? "GPS siap." :
                (location.lastLocation != nil ? "GPS aktif." : "GPS menunggu sinyal…")
            return base + " Pilih izin \"Selalu\" supaya lebih pasti saat layar dikunci."
        case .authorizedAlways:
            if requestingOnStart { return "GPS siap." }
            return location.lastLocation != nil ? "GPS aktif." : "GPS menunggu sinyal…"
        @unknown default:
            return ""
        }
    }
}

// MARK: - Helper

enum RecordingPalette {
    static let red = Color(red: 0.95, green: 0.26, blue: 0.30)
    static let card = Color.white.opacity(0.06)
    static let background = LinearGradient(colors: [Color(red: 0.04, green: 0.07, blue: 0.12),
                                                     Color(red: 0.09, green: 0.13, blue: 0.20)],
                                           startPoint: .top, endPoint: .bottom)
}

enum RecordingFormat {
    /// 00:42 / 12:03 / 1:02:03
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// "1j 05m" / "5m 12d" / "42d"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%dj %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02dd", m, sec) }
        return "\(sec)d"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "25m 10d • 1,2 MB • 1.503 baris"
    static func summaryLine(_ s: RecordingSession) -> String {
        var parts: [String] = []
        if let d = s.duration { parts.append(duration(d)) }
        parts.append(size(s.bytes))
        if s.lineCount > 0 {
            parts.append("\(s.lineCount.formatted()) \(s.format == .csv ? "baris" : "frame")")
        }
        return parts.joined(separator: " • ")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "22 Sep 2026, 20:14 – 20:39"
    static func timeRange(_ s: RecordingSession) -> String {
        let start = dayFormatter.string(from: s.startedAt)
        guard let end = s.endedAt else { return "\(start) – sekarang" }
        if Calendar.current.isDate(s.startedAt, inSameDayAs: end) {
            return "\(start) – \(timeFormatter.string(from: end))"
        }
        return "\(start) – \(dayFormatter.string(from: end))"
    }
}
