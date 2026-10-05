import Foundation
import SwiftUI

/// Preview dibatasi supaya file rekaman sampai 20 MB tidak dibaca seluruhnya
/// atau membuat halaman detail berat. Pembacaan berjalan di luar MainActor.
nonisolated struct RawLogPreview: Sendable {
    let text: String
    let isTruncated: Bool

    static func load(from url: URL) throws -> RawLogPreview {
        let byteLimit = 64 * 1024
        let lineLimit = 200
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        let exceedsByteLimit = data.count > byteLimit
        var prefix = Data(data.prefix(byteLimit))
        // Buang baris terakhir yang terpotong agar karakter UTF-8 dan frame
        // panjang tidak ditampilkan seolah-olah isinya lengkap.
        if exceedsByteLimit, let newline = prefix.lastIndex(of: 0x0A) {
            prefix = Data(prefix.prefix(through: newline))
        }
        var lines = String(decoding: prefix, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return RawLogPreview(text: lines.prefix(lineLimit).joined(separator: "\n"),
                             isTruncated: exceedsByteLimit || lines.count > lineLimit)
    }
}

struct RawLogPreviewView: View {
    let url: URL
    let isActive: Bool
    let accent: Color

    @State private var preview: RawLogPreview?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                ProgressView("Membaca log…")
                    .tint(accent)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let preview, !preview.text.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(preview.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(10)
                }
                .frame(height: 300)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))

                if preview.isTruncated {
                    Text("Menampilkan bagian awal log, maksimal 200 baris / 64 KB. Bagikan file untuk membaca seluruh isi.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Belum ada isi log — frame BLE akan muncul saat motor terhubung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isActive {
                Text("Rekaman masih berjalan. Muat ulang untuk melihat isi terbaru.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await loadPreview() }
            } label: {
                Label("Muat ulang preview", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .tint(accent)
            .disabled(isLoading)
        }
        .padding(.vertical, 4)
        .task(id: isActive) { await loadPreview() }
    }

    private func loadPreview() async {
        isLoading = true
        errorMessage = nil
        let result = await Task.detached(priority: .userInitiated) {
            Result { try RawLogPreview.load(from: url) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let value): preview = value
        case .failure: errorMessage = "Log tidak bisa dibaca. File mungkin sudah dihapus atau tidak tersedia."
        }
        isLoading = false
    }
}
