import Foundation

/// Formats rows of cells into evenly aligned columns, padding each column to its widest cell.
/// A raw tab-separated join only lines up by accident: alignment then depends on the terminal's
/// fixed tab stops (commonly every 8 columns), so any cell wider than one stop — a long app name,
/// a version string — throws every column after it out of alignment.
public enum TableFormatter {
    public static func rows(_ rows: [[String]], spacing: Int = 2) -> [String] {
        guard let columnCount = rows.map(\.count).max(), columnCount > 0 else { return rows.map { $0.joined() } }
        let widths = (0..<columnCount).map { column in rows.map { $0.count > column ? $0[column].terminalDisplayWidth : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell -> String in
                guard index < row.count - 1 else { return cell }
                return cell + String(repeating: " ", count: max(0, widths[index] - cell.terminalDisplayWidth) + spacing)
            }.joined()
        }
    }
}

extension String {
    /// Approximate terminal column width: most East Asian and emoji characters render as two
    /// columns wide even though each is a single `Character` (grapheme cluster), so `count`
    /// alone under-counts them and misaligns every column after one. Not a full Unicode
    /// wcwidth implementation, but covers the ranges actually seen in application, formula,
    /// and package names.
    var terminalDisplayWidth: Int { reduce(0) { $0 + $1.terminalDisplayWidth } }
}

private extension Character {
    var terminalDisplayWidth: Int {
        for scalar in unicodeScalars {
            if scalar.properties.isEmoji, scalar.properties.isEmojiPresentation || unicodeScalars.count > 1 { return 2 }
            switch scalar.value {
            case 0x1100...0x115F,  // Hangul Jamo
                0x2E80...0x303E,  // CJK Radicals, Kangxi Radicals, CJK Symbols and Punctuation
                0x3041...0x33FF,  // Hiragana .. CJK Compatibility
                0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
                0x4E00...0x9FFF,  // CJK Unified Ideographs
                0xA000...0xA4CF,  // Yi Syllables and Radicals
                0xAC00...0xD7A3,  // Hangul Syllables
                0xF900...0xFAFF,  // CJK Compatibility Ideographs
                0xFE30...0xFE4F,  // CJK Compatibility Forms
                0xFF00...0xFF60,  // Fullwidth Forms
                0xFFE0...0xFFE6,
                0x20000...0x3FFFD:  // CJK Unified Ideographs Extension B and beyond
                return 2
            default:
                continue
            }
        }
        return 1
    }
}
