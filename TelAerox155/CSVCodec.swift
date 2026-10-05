import Foundation

/// Angka selalu memakai titik desimal, terlepas dari region iPhone.
nonisolated enum CSVCodec {
    static func number(_ value: Double?, decimals: Int = 3) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value)
    }

    static func row(_ fields: [String]) -> String {
        fields.map { field in
            // Field di aplikasi ini satu baris; hapus newline dari metadata.
            let text = field.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            if text.contains(",") || text.contains("\"") {
                return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return text
        }.joined(separator: ",")
    }

    static func fields(_ line: String) -> [String] {
        // Fast path untuk baris numerik; parser quoted dipakai untuk metadata.
        guard line.contains("\"") else { return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        var result: [String] = [], field = "", quoted = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i], next = line.index(after: i)
            if c == "\"" {
                if quoted && next < line.endIndex && line[next] == "\"" {
                    field.append("\""); i = line.index(after: next); continue
                }
                quoted.toggle()
            } else if c == "," && !quoted {
                result.append(field); field = ""
            } else { field.append(c) }
            i = next
        }
        result.append(field)
        return result
    }
}
