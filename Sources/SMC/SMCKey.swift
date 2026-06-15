import Foundation

// MARK: - SMC Key Encoding
//
// SMC keys are 4 ASCII characters packed into a UInt32 where byte0 is the
// MSB of the integer value:
//
//   "Tp01" -> ('T' << 24) | ('p' << 16) | ('0' << 8) | '1'
//
// Note this is the logical integer value of the key. When written into the
// SMCKeyData_t struct it is stored in native (little-endian) byte order by
// SMCDevice — the two concerns are kept separate on purpose.

struct SMCKey: Hashable, CustomStringConvertible {
    let code: UInt32

    /// Build an SMC key from 4 ASCII characters (e.g. "Tp01", "F0Ac", "#KEY").
    init(_ fourCC: String) {
        precondition(fourCC.count == 4, "SMC key must be 4 characters, got '\(fourCC)'")
        let bytes: [UInt8] = Array(fourCC.utf8)
        precondition(bytes.count == 4)
        let b0 = UInt32(bytes[0])
        let b1 = UInt32(bytes[1])
        let b2 = UInt32(bytes[2])
        let b3 = UInt32(bytes[3])
        self.code = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    /// Decode a UInt32 keyCode back to a 4-character string.
    var fourCC: String {
        let b0 = UInt8((code >> 24) & 0xFF)
        let b1 = UInt8((code >> 16) & 0xFF)
        let b2 = UInt8((code >>  8) & 0xFF)
        let b3 = UInt8( code        & 0xFF)
        return String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? "????"
    }

    var description: String { fourCC }
}

// MARK: - SMC Data Types
//
// The SMC reports each key's data type as its own 4-character code (e.g.
// "flt ", "sp78", "fpe2", "ui8 "). We decode that code rather than guessing
// the type from the byte length. The important modern detail: on Apple
// Silicon, temperatures and fan RPMs are reported as IEEE-754 little-endian
// `flt`, NOT the legacy Intel `sp78` / `fpe2` encodings (which we still
// support for completeness and older hardware).

enum SMCDataType: Equatable, CustomStringConvertible {
    case ui8
    case ui16
    case ui32
    case si8
    case si16
    case flt          // IEEE-754 32-bit float, little-endian
    case sp78         // signed 7.8 fixed point (legacy temperature)
    case fpe2         // fan RPM encoding (legacy)
    case flag         // 1-byte boolean
    case unknown(String)

    /// Build from the raw 4-byte type code returned by GetKeyInfo.
    /// Trailing spaces are trimmed ("flt " -> "flt").
    init(fourCCCode raw: UInt32) {
        let b0 = UInt8((raw >> 24) & 0xFF)
        let b1 = UInt8((raw >> 16) & 0xFF)
        let b2 = UInt8((raw >>  8) & 0xFF)
        let b3 = UInt8( raw        & 0xFF)
        let s = (String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? "")
            .trimmingCharacters(in: .whitespaces)
        switch s {
        case "ui8":  self = .ui8
        case "ui16": self = .ui16
        case "ui32": self = .ui32
        case "si8":  self = .si8
        case "si16": self = .si16
        case "flt":  self = .flt
        case "sp78": self = .sp78
        case "fpe2": self = .fpe2
        case "flag": self = .flag
        default:     self = .unknown(s)
        }
    }

    var description: String {
        switch self {
        case .ui8: return "ui8"
        case .ui16: return "ui16"
        case .ui32: return "ui32"
        case .si8: return "si8"
        case .si16: return "si16"
        case .flt: return "flt"
        case .sp78: return "sp78"
        case .fpe2: return "fpe2"
        case .flag: return "flag"
        case .unknown(let s): return "unknown(\(s))"
        }
    }

    /// Parse a raw SMC data buffer into a Double.
    /// - Returns: nil if the buffer is too short or the type is unsupported.
    func parse(_ data: Data) -> Double? {
        let b: [UInt8] = Array(data)
        switch self {
        case .ui8, .flag:
            guard b.count >= 1 else { return nil }
            return Double(b[0])

        case .si8:
            guard b.count >= 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))

        case .ui16:
            guard b.count >= 2 else { return nil }
            // SMC integer payloads are big-endian (most significant byte first).
            return Double((UInt16(b[0]) << 8) | UInt16(b[1]))

        case .si16:
            guard b.count >= 2 else { return nil }
            let raw = (UInt16(b[0]) << 8) | UInt16(b[1])
            return Double(Int16(bitPattern: raw))

        case .ui32:
            guard b.count >= 4 else { return nil }
            let v = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16)
                  | (UInt32(b[2]) <<  8) |  UInt32(b[3])
            return Double(v)

        case .flt:
            // IEEE-754 single precision, little-endian byte order.
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8)
                     | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return Double(Float(bitPattern: bits))

        case .sp78:
            // signed 7.8 fixed point, big-endian.
            guard b.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(b[0]) << 8) | UInt16(b[1]))
            return Double(raw) / 256.0

        case .fpe2:
            // legacy fan RPM: big-endian 14.2 fixed point.
            guard b.count >= 2 else { return nil }
            let raw = (UInt16(b[0]) << 8) | UInt16(b[1])
            return Double(raw) / 4.0

        case .unknown:
            return nil
        }
    }
}
