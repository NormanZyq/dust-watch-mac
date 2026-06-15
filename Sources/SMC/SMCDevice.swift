import Foundation
import IOKit

// MARK: - AppleSMC Direct IOKit Interface
//
// The user-space `AppleSMC.framework` private framework was removed in
// recent macOS releases, but the underlying `AppleSMC` IOKit service (the
// IOAppleSMC kext's UserClient) is unchanged and has been stable for 15+
// years. We talk to it the same way smcFanControl / osx-cpu-temp / SMCKit
// always have — there is nothing to reverse-engineer.
//
// The protocol is ONE IOConnect selector (KERNEL_INDEX_SMC = 2). What the
// call does is decided by the `data8` command byte inside the struct, not
// by the selector:
//
//   data8 = 9  (kSMCGetKeyInfo) — given a key, return its dataType + dataSize
//   data8 = 5  (kSMCReadBytes)  — given a key + size, return the raw bytes
//
// A read is therefore two calls: first GetKeyInfo to learn the type/size,
// then ReadBytes to fetch the value. We never guess offsets or sizes.
//
// SMCKeyData_t is the canonical 80-byte struct. Under natural C alignment
// on arm64 the field offsets are fixed (see the constants below). All
// multi-byte integer fields are NATIVE (little-endian on Apple Silicon) —
// this is the single detail most broken reimplementations get wrong by
// assuming big-endian.
//
//   struct SMCKeyData_t {                          // offset
//       UInt32                  key;               //  0
//       SMCVersion              vers;              //  4   (8 bytes)
//       SMCPLimitData           pLimitData;        // 12   (16 bytes)
//       SMCKeyInfoData          keyInfo;           // 28
//           UInt32 dataSize;                       // 28
//           UInt32 dataType;                       // 32
//           UInt8  dataAttributes;                 // 36
//       UInt8                   result;            // 40
//       UInt8                   status;            // 41
//       UInt8                   data8;             // 42  (command)
//       UInt32                  data32;            // 44
//       UInt8                   bytes[32];         // 48
//   };                                             // total 80

private enum SMCStruct {
    static let size            = 80
    static let offKey          = 0
    static let offKeyInfoSize  = 28   // keyInfo.dataSize
    static let offKeyInfoType  = 32   // keyInfo.dataType
    static let offResult       = 40
    static let offData8        = 42   // command byte
    static let offBytes        = 48   // start of bytes[32]
    static let bytesCapacity   = 32
}

private let KERNEL_INDEX_SMC: UInt32 = 2     // the only IOConnect selector
private let kSMCReadBytes:    UInt8 = 5
private let kSMCGetKeyInfo:   UInt8 = 9
private let kSMCSuccess:      UInt8 = 0

final class SMCDevice {
    private var connection: io_connect_t = 0
    private(set) var isOpen: Bool = false

    // GetKeyInfo is relatively expensive and the (type,size) for a key
    // never changes for the life of the machine, so cache it.
    private var keyInfoCache: [UInt32: (type: SMCDataType, size: UInt32)] = [:]

    func open() throws {
        guard !isOpen else { return }
        // IOServiceGetMatchingService consumes one reference and returns a
        // single matching service — simpler than iterating.
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
        isOpen = true
    }

    func close() {
        if isOpen && connection != 0 {
            IOServiceClose(connection)
            connection = 0
            isOpen = false
        }
        keyInfoCache.removeAll()
    }

    deinit { close() }

    // MARK: - Low-level call

    /// Issue one IOConnectCallStructMethod with an 80-byte in/out struct.
    /// Returns the output struct, or throws on IOKit / SMC-level failure.
    private func callSMC(_ input: inout [UInt8]) throws -> [UInt8] {
        precondition(isOpen, "SMCDevice.open() must be called first")
        var output = [UInt8](repeating: 0, count: SMCStruct.size)
        var outputSize = SMCStruct.size

        let kr = input.withUnsafeMutableBytes { ip in
            output.withUnsafeMutableBytes { op in
                IOConnectCallStructMethod(
                    connection,
                    KERNEL_INDEX_SMC,
                    ip.baseAddress, SMCStruct.size,
                    op.baseAddress, &outputSize
                )
            }
        }
        guard kr == KERN_SUCCESS else { throw SMCError.readFailed(kr) }

        // The kext reports key-level errors (e.g. unknown key) in the
        // `result` byte even when the IOKit call itself succeeds.
        let result = output[SMCStruct.offResult]
        guard result == kSMCSuccess else { throw SMCError.smcError(result) }
        return output
    }

    // MARK: - Key info

    /// Look up the data type and byte size for a key (data8 = 9). Cached.
    private func keyInfo(_ key: SMCKey) throws -> (type: SMCDataType, size: UInt32) {
        if let cached = keyInfoCache[key.code] { return cached }

        var input = [UInt8](repeating: 0, count: SMCStruct.size)
        putLE32(&input, SMCStruct.offKey, key.code)
        input[SMCStruct.offData8] = kSMCGetKeyInfo

        let out = try callSMC(&input)
        let size = getLE32(out, SMCStruct.offKeyInfoSize)
        let typeRaw = getLE32(out, SMCStruct.offKeyInfoType)
        let type = SMCDataType(fourCCCode: typeRaw)

        let info = (type: type, size: size)
        keyInfoCache[key.code] = info
        return info
    }

    // MARK: - Read

    /// Read a key's raw value bytes plus its decoded data type.
    /// Performs GetKeyInfo (cached) then ReadBytes.
    func readRaw(_ key: SMCKey) throws -> (data: Data, type: SMCDataType, size: UInt32) {
        let info = try keyInfo(key)
        guard info.size > 0, info.size <= UInt32(SMCStruct.bytesCapacity) else {
            throw SMCError.badSize(key: key, size: info.size)
        }

        var input = [UInt8](repeating: 0, count: SMCStruct.size)
        putLE32(&input, SMCStruct.offKey, key.code)
        putLE32(&input, SMCStruct.offKeyInfoSize, info.size)  // tell kext how many bytes
        input[SMCStruct.offData8] = kSMCReadBytes

        let out = try callSMC(&input)
        let n = Int(info.size)
        let bytes = Array(out[SMCStruct.offBytes ..< SMCStruct.offBytes + n])
        return (Data(bytes), info.type, info.size)
    }

    /// Convenience: read a key and decode it as a Double in one call.
    func read(_ key: SMCKey) throws -> Double {
        let result = try readRaw(key)
        guard let value = result.type.parse(result.data) else {
            throw SMCError.parseFailed(key: key, type: result.type)
        }
        return value
    }

    /// Total number of keys the SMC exposes (the `#KEY` pseudo-key).
    /// Useful as a connectivity check.
    func keyCount() throws -> Int {
        Int(try read(SMCKey("#KEY")))
    }

    // MARK: - Endian helpers
    //
    // SMCKeyData_t integer fields are native-endian (little on arm64).

    @inline(__always)
    private func putLE32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buf[offset + 0] = UInt8( value        & 0xFF)
        buf[offset + 1] = UInt8((value >>  8) & 0xFF)
        buf[offset + 2] = UInt8((value >> 16) & 0xFF)
        buf[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    @inline(__always)
    private func getLE32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buf[offset + 0])
            | (UInt32(buf[offset + 1]) <<  8)
            | (UInt32(buf[offset + 2]) << 16)
            | (UInt32(buf[offset + 3]) << 24)
    }
}

enum SMCError: Error, LocalizedError {
    case serviceNotFound
    case openFailed(kern_return_t)
    case readFailed(kern_return_t)
    case smcError(UInt8)
    case badSize(key: SMCKey, size: UInt32)
    case parseFailed(key: SMCKey, type: SMCDataType)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found in IOKit registry."
        case .openFailed(let kr):
            return "IOServiceOpen failed: kern_return_t=\(kr)"
        case .readFailed(let kr):
            return "SMC IOKit call failed: kern_return_t=\(kr)"
        case .smcError(let r):
            return "SMC returned result byte 0x\(String(r, radix: 16)) (key likely not present)."
        case .badSize(let key, let size):
            return "SMC key \(key) reported an unusable size: \(size)."
        case .parseFailed(let key, let type):
            return "Could not parse SMC key \(key) as type \(type)."
        }
    }
}
