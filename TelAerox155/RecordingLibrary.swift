import Foundation
import Combine

/// Satu sesi rekaman yang tersimpan di disk. Metadata-nya disimpan di indeks
/// JSON (lihat `RecordingLibrary`), file datanya sendiri tetap di Documents.
///
/// nonisolated: murni data (Codable + dipakai dari Task.detached buat baca
/// ringkasan CSV) — di bawah SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor tanpa ini
/// conformance Codable/Equatable-nya ikut ter-infer MainActor-isolated.
nonisolated struct RecordingSession: Identifiable, Codable, Equatable, Sendable {
    /// Nama file (bukan path penuh) — unik per sesi, sekaligus jadi id.
    let fileName: String
    let format: SessionRecorder.Format
    let startedAt: Date
    /// nil = masih merekam (atau app dimatikan sistem sebelum sempat di-stop —
    /// diperbaiki otomatis saat `RecordingLibrary.reload()`).
    var endedAt: Date?
    var bytes: Int
    /// Baris data yang ditulis: baris CSV (tanpa header) atau frame BLE Raw.
    var lineCount: Int
    /// Kenapa rekaman berhenti kalau BUKAN karena user menekan Stop (limit
    /// ukuran/durasi, gagal nulis, app dimatikan sistem).
    var stopReason: String?
    /// Nama opsional dari user ("Tes tanjakan", "Harian ke kantor", dll).
    var title: String?

    var id: String { fileName }

    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var displayTitle: String {
        if let t = title, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        // FormatStyle (Sendable), bukan DateFormatter statis — struct ini
        // nonisolated, jadi static let non-Sendable akan memicu warning.
        return startedAt.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)
            .year().hour().minute().locale(Locale(identifier: "id_ID")))
    }
}

/// Riwayat SEMUA sesi rekaman — permanen, bertahan walau app ditutup, di-kill
/// sistem, atau HP restart.
///
/// Sebelumnya UI cuma ingat SATU file terakhir (`SessionRecorder.fileURL`,
/// di memori) — begitu app ditutup atau mulai rekam baru, sesi lama "hilang"
/// dari UI walau file-nya sebenarnya masih ada di Documents. Sekarang:
///
/// - Metadata tiap sesi disimpan di indeks JSON di Application Support
///   (tidak kelihatan di app Files, tidak bisa kehapus user tanpa sengaja).
/// - `reload()` tetap MEMINDAI folder Documents — file rekaman yang tidak
///   punya entri indeks (mis. dari versi app lama, atau indeks rusak) tetap
///   muncul dengan metadata hasil tebakan (tanggal dari nama file, ukuran &
///   waktu selesai dari atribut file). Jadi sumber kebenaran tetap file-nya:
///   selama file ada, sesi tidak pernah hilang dari daftar.
/// - Entri yang file-nya sudah tidak ada (dihapus lewat app Files) dibuang.
final class RecordingLibrary: ObservableObject {
    /// Terbaru di atas.
    @Published private(set) var sessions: [RecordingSession] = []

    static let filePrefix = "telaerox-rec_"

    private let fm = FileManager.default
    private let directoryOverride: URL?

    var documentsDirectory: URL? {
        directoryOverride ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private var indexURL: URL? {
        guard let dir = directoryOverride ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recordings-index.json")
    }

    /// Override dipakai pengujian agar tidak menyentuh rekaman pengguna.
    init(directory: URL? = nil) {
        directoryOverride = directory
        reload(activeFileName: nil)
    }

    func url(for session: RecordingSession) -> URL? {
        documentsDirectory?.appendingPathComponent(session.fileName)
    }

    /// Sinkronkan indeks dengan isi folder Documents. `activeFileName` = file
    /// yang SEDANG direkam (kalau ada) — entrinya dibiarkan `endedAt == nil`.
    func reload(activeFileName: String?) {
        let indexed = loadIndex()
        var byName = Dictionary(indexed.map { ($0.fileName, $0) }, uniquingKeysWith: { a, _ in a })

        var result: [RecordingSession] = []
        let files = (try? fm.contentsOfDirectory(at: documentsDirectory ?? URL(fileURLWithPath: "/"),
                                                 includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(Self.filePrefix),
                  let format = SessionRecorder.Format(fileExtension: file.pathExtension) else { continue }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate

            if var s = byName.removeValue(forKey: name) {
                if s.endedAt == nil && name != activeFileName {
                    // Rekaman yang tidak sempat di-stop (app di-kill sistem /
                    // HP mati) — datanya tetap ada sampai baris terakhir yang
                    // sempat ditulis, jadi tetap disimpan, cuma ditandai.
                    s.endedAt = modified ?? s.startedAt
                    s.bytes = size
                    s.stopReason = s.stopReason ?? "Terhenti tak terduga — app ditutup sistem sebelum rekaman di-stop."
                } else if name != activeFileName {
                    s.bytes = size
                }
                result.append(s)
            } else {
                // File tanpa entri indeks (rekaman versi lama dsb).
                let started = Self.startDate(fromFileName: name) ?? modified ?? Date()
                result.append(RecordingSession(fileName: name, format: format, startedAt: started,
                                               endedAt: name == activeFileName ? nil : (modified ?? started),
                                               bytes: size, lineCount: 0, stopReason: nil, title: nil))
            }
        }
        sessions = result.sorted { $0.startedAt > $1.startedAt }
        saveIndex()
    }

    /// Tambah atau perbarui satu sesi (dipanggil SessionRecorder saat mulai,
    /// berkala selama merekam, dan saat berhenti).
    func upsert(_ session: RecordingSession) {
        if let i = sessions.firstIndex(where: { $0.fileName == session.fileName }) {
            // Judul diatur user dari UI — jangan tertimpa update dari recorder.
            var s = session
            if s.title == nil { s.title = sessions[i].title }
            sessions[i] = s
        } else {
            sessions.insert(session, at: 0)
            sessions.sort { $0.startedAt > $1.startedAt }
        }
        saveIndex()
    }

    func rename(_ session: RecordingSession, to title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[i].title = trimmed.isEmpty ? nil : trimmed
        saveIndex()
    }

    /// Hapus file + entrinya. Satu-satunya jalan sesi hilang dari daftar
    /// (selain dihapus manual lewat app Files) — dan UI selalu minta
    /// konfirmasi dulu.
    func delete(_ session: RecordingSession) {
        if let url = url(for: session) {
            try? fm.removeItem(at: url)
        }
        sessions.removeAll { $0.id == session.id }
        saveIndex()
    }

    // MARK: - Persistensi indeks

    private func loadIndex() -> [RecordingSession] {
        guard let url = indexURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecordingSession].self, from: data)) ?? []
    }

    private func saveIndex() {
        guard let url = indexURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sessions) else { return }
        // Atomic supaya indeks tidak pernah setengah tertulis kalau app di-kill
        // di tengah penulisan; proteksi sama seperti file rekaman (tetap bisa
        // ditulis saat layar terkunci).
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// "telaerox-rec_2026-09-22_20-14-05.csv" → Date.
    static func startDate(fromFileName name: String) -> Date? {
        guard name.hasPrefix(filePrefix) else { return nil }
        let stamp = name.dropFirst(filePrefix.count).prefix(19)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.date(from: String(stamp))
    }
}
