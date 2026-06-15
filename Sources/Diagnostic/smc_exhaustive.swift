import Foundation
import IOKit

// MARK: - Exhaustive SMC struct probe
//
// We have one known fact: Macs Fan Control reads SMC successfully on
// this Mac. We have one strong hypothesis: the 80-byte struct with
// selector 2 and a 0x09 byte somewhere in it is roughly right, but
// the exact magic-byte position and the output-data offsets need
// to be found.
//
// This script systematically tests combinations to find one that
// returns *different* values for two unrelated keys (Tp01 and F0Ac).
// If we find that, we know SMC read is working and we can re-parse
// at the right offset. If all combinations return the same value,
// SMC read is fundamentally broken and we need a different approach.

// Open the SMC connection
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
print("✓ SMC connection open\n")

func makeKey(_ s: String) -> UInt32 {
    let b = Array(s.utf8)
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

func callSMC(selector: UInt32, input: inout [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: 80)
    var outSize = 80
    _ = input.withUnsafeMutableBufferPointer { ip in
        output.withUnsafeMutableBufferPointer { op in
            IOConnectCallStructMethod(conn, selector, ip.baseAddress, 80,
                                        op.baseAddress, &outSize)
        }
    }
    return output
}

// Step 1: read Tp01 and F0Ac with the *current best guess* to see the baseline.
print("=== Baseline: Tp01 and F0Ac with selector=2, magic=0x09 at 0x2A ===")
do {
    var input = [UInt8](repeating: 0, count: 80)
    let key = makeKey("Tp01")
    input[0] = UInt8((key >> 24) & 0xFF)
    input[1] = UInt8((key >> 16) & 0xFF)
    input[2] = UInt8((key >>  8) & 0xFF)
    input[3] = UInt8( key        & 0xFF)
    input[0x2A] = 0x09
    let out1 = callSMC(selector: 2, input: &input)
    print("Tp01 out: \(out1[0..<32].map { String(format: "%02x", $0) }.joined(separator: " "))")

    input[0] = UInt8((makeKey("F0Ac") >> 24) & 0xFF)
    input[1] = UInt8((makeKey("F0Ac") >> 16) & 0xFF)
    input[2] = UInt8((makeKey("F0Ac") >>  8) & 0xFF)
    input[3] = UInt8((makeKey("F0Ac")        & 0xFF))
    let out2 = callSMC(selector: 2, input: &input)
    print("F0Ac out: \(out2[0..<32].map { String(format: "%02x", $0) }.joined(separator: " "))")
    print("Outputs identical? \(out1 == out2)\n")
}

// Step 2: Try every selector from 0 to 15 with current magic.
// A working selector should make Tp01 and F0Ac produce different output.
print("=== Sweep: selector 0..15, magic 0x09 @ 0x2A ===")
for sel: UInt32 in 0...15 {
    var input = [UInt8](repeating: 0, count: 80)
    let k1 = makeKey("Tp01"); let k2 = makeKey("F0Ac")
    input[0] = UInt8((k1 >> 24) & 0xFF); input[1] = UInt8((k1 >> 16) & 0xFF)
    input[2] = UInt8((k1 >>  8) & 0xFF); input[3] = UInt8( k1        & 0xFF)
    input[0x2A] = 0x09
    let out1 = callSMC(selector: sel, input: &input)
    input[0] = UInt8((k2 >> 24) & 0xFF); input[1] = UInt8((k2 >> 16) & 0xFF)
    input[2] = UInt8((k2 >>  8) & 0xFF); input[3] = UInt8( k2        & 0xFF)
    let out2 = callSMC(selector: sel, input: &input)
    let diff = out1 != out2
    let any1 = out1.contains(where: { $0 != 0 })
    let any2 = out2.contains(where: { $0 != 0 })
    let marker = diff ? " ★" : ""
    print("  sel=\(sel): Tp01_any=\(any1) F0Ac_any=\(any2) different=\(diff)\(marker)")
}
print()

// Step 3: For the most promising selector, sweep the magic-byte position
// and value to find one that produces variable data.
print("=== Sweep: magic byte position × value (sel=2) ===")
let bestSel: UInt32 = 2
for offset in stride(from: 0, through: 79, by: 4) {
    for magic in [UInt8(0x00), 0x01, 0x09, 0x0a, 0x0c, 0x0e, 0x0f, 0x20, 0x80, 0xff] {
        var input = [UInt8](repeating: 0, count: 80)
        let k1 = makeKey("Tp01"); let k2 = makeKey("F0Ac")
        input[0] = UInt8((k1 >> 24) & 0xFF); input[1] = UInt8((k1 >> 16) & 0xFF)
        input[2] = UInt8((k1 >>  8) & 0xFF); input[3] = UInt8( k1        & 0xFF)
        input[offset] = magic
        let out1 = callSMC(selector: bestSel, input: &input)
        input[0] = UInt8((k2 >> 24) & 0xFF); input[1] = UInt8((k2 >> 16) & 0xFF)
        input[2] = UInt8((k2 >>  8) & 0xFF); input[3] = UInt8( k2        & 0xFF)
        let out2 = callSMC(selector: bestSel, input: &input)
        if out1 != out2 {
            print("  ★ off=0x\(String(offset, radix: 16, uppercase: false)) magic=0x\(String(magic, radix: 16)) Tp01≠F0Ac")
        }
    }
}
print()

// Step 4: Try reading a definitely-missing key (TC0P = Intel key) and
// compare to Tp01. If the outputs differ, the SMC IS responding with
// key-specific data; if they're identical, the read is just echoing.
print("=== Sanity: existing key (Tp01) vs missing key (TC0P) ===")
for sel: UInt32 in [0, 1, 2, 3, 5, 9] {
    var input = [UInt8](repeating: 0, count: 80)
    let k1 = makeKey("Tp01")
    input[0] = UInt8((k1 >> 24) & 0xFF); input[1] = UInt8((k1 >> 16) & 0xFF)
    input[2] = UInt8((k1 >>  8) & 0xFF); input[3] = UInt8( k1        & 0xFF)
    input[0x2A] = 0x09
    let out1 = callSMC(selector: sel, input: &input)
    input[0] = UInt8((makeKey("TC0P") >> 24) & 0xFF); input[1] = UInt8((makeKey("TC0P") >> 16) & 0xFF)
    input[2] = UInt8((makeKey("TC0P") >>  8) & 0xFF); input[3] = UInt8( makeKey("TC0P")        & 0xFF)
    let out2 = callSMC(selector: sel, input: &input)
    let marker = out1 != out2 ? " ★ KEY-SPECIFIC" : ""
    print("  sel=\(sel): Tp01=[\(out1[0..<16].map { String(format: "%02x", $0) }.joined(separator: " "))]")
    print("          TC0P=[\(out2[0..<16].map { String(format: "%02x", $0) }.joined(separator: " "))]\(marker)")
}
print()
print("=== Done ===")
