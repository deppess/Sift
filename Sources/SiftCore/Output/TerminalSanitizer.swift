import Foundation

public extension String {
    var terminalText: String {
        var result = String.UnicodeScalarView()
        let scalars = Array(unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}" {
                index += 1
                guard index < scalars.count else { continue }
                switch scalars[index].value {
                case 0x5B:  // CSI: ESC [ ... final byte
                    index += 1
                    while index < scalars.count {
                        let value = scalars[index].value
                        index += 1
                        if (0x40...0x7E).contains(value) { break }
                    }
                case 0x58, 0x5D, 0x50, 0x5E, 0x5F:  // SOS, OSC, DCS, PM, APC: terminate at BEL or ST
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x07 {
                            index += 1
                            break
                        }
                        if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                default:  // Other ESC functions have a one-character final byte.
                    index += 1
                }
            } else if scalar.value == 0x9B {  // 8-bit CSI
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if (0x40...0x7E).contains(value) { break }
                }
            } else if [0x90, 0x98, 0x9D, 0x9E, 0x9F].contains(scalar.value) {  // 8-bit DCS, SOS, OSC, PM, APC
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 0x07 || scalars[index].value == 0x9C {
                        index += 1
                        break
                    }
                    if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            } else if scalar == "\n" || scalar == "\t"
                || (scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value) && !isInvisibleFormatControl(scalar))
            {
                result.append(scalar)
                index += 1
            } else {
                index += 1
            }
        }
        return String(result)
    }

    private func isInvisibleFormatControl(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060, 0x2066...0x2069, 0xFEFF:
            true
        default:
            false
        }
    }

    var terminalInline: String {
        terminalText.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
}
