import Foundation

extension String {
    var terminalText: String {
        String(unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value))
        })
    }

    var terminalInline: String {
        terminalText.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
}
