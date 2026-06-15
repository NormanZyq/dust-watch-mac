import Foundation
import IOKit

// Mirror the v2 SMCDevice: raw 80-byte buffer, key code as UInt32 BE at offset 0.

private let SMC_BYTES_SIZE = 80
private let SMC_GET_KEY_INFO: UInt32 = 9
private let SMC_READ_KEY:     UInt32 = 5

func writeU32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
    buf[off+0] = UInt8((v >> 24) & 0xFF)
    buf[off+1] = UInt8((v >> 16) & 0xFF)
    buf[off+2] = UInt8((v >>  8) & 0xFF)
    buf[off+3] = UInt8( v        & 0xFF)
}

func makeKey(_ s: String) -> UInt32 {
    let b = Array(s.utf8)
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

// Open service
var conn: io_connect_t = 0
let matching = IOServiceMatching("AppleSMC")
var it: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else {
    print("AppleSMC service not found"); exit(1)
}
defer { IOObjectRelease(it) }
let svc = IOIteratorNext(it)
guard svc != 0 else { print("No service"); exit(1) }
defer { IOObjectRelease(svc) }
guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else {
    print("IOServiceOpen failed"); exit(1)
}
defer { IOServiceClose(conn) }
print("AppleSMC opened ✓\n")

// Try all the candidate keys
let keys = ["Tp01","Tp09","Tp0D","Tp0E","Tp0F","Tp05",
            "Tg0f","Tg0p","TC0P","TC0E","TC0C","TC0D",
            "F0Ac","F1Ac",
            "PSI0","PSI1","PC0C","Pm0h"]

print("== getKeyInfo (command 9) ==")
for k in keys {
    var buf = [UInt8](repeating: 0, count: SMC_BYTES_SIZE)
    writeU32(&buf, 0, makeKey(k))
    var outSize = SMC_BYTES_SIZE
    let kr = buf.withUnsafeMutableBytes { raw in
        IOConnectCallStructMethod(conn, SMC_GET_KEY_INFO, raw.baseAddress, SMC_BYTES_SIZE,
                                    raw.baseAddress, &outSize)
    }
    if kr == KERN_SUCCESS {
        let t = String(bytes: buf[24..<28], encoding: .ascii) ?? "????"
        let s = (UInt16(buf[28]) << 8) | UInt16(buf[29])
        print("  \(k): type=\(t) size=\(s)  ✓")
    } else {
        print("  \(k): kr=\(kr)")
    }
}

print("\n== read (command 5) ==")
for k in ["Tp01","Tg0f","F0Ac","TC0P","TC0E"] {
    var buf = [UInt8](repeating: 0, count: SMC_BYTES_SIZE)
    writeU32(&buf, 0, makeKey(k))
    writeU32(&buf, 16, 32)  // request 32 bytes
    var outSize = SMC_BYTES_SIZE
    let kr = buf.withUnsafeMutableBytes { raw in
        IOConnectCallStructMethod(conn, SMC_READ_KEY, raw.baseAddress, SMC_BYTES_SIZE,
                                    raw.baseAddress, &outSize)
    }
    if kr == KERN_SUCCESS {
        let d = buf[24..<32].map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  \(k): \(d)")
    } else {
        print("  \(k): kr=\(kr)")
    }
}
