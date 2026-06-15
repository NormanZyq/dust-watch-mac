import Foundation

// MARK: - SMCReader
//
// High-level wrapper around SMCDevice that exposes a stable, typed
// interface for the rest of the app. It hides the SMC key constants and
// the failure modes of individual sensors behind a single `SystemSnapshot`.

final class SMCReader {
    private let device: SMCDevice

    // Apple Silicon CPU die-temperature probes. There are many (Tp01..TpXX
    // across performance/efficiency cores); we average the ones that read
    // successfully so a missing probe on a given SoC doesn't break the
    // reading. All report as `flt` on modern hardware.
    private static let cpuTempKeys: [SMCKey] = [
        SMCKey("Tp01"), SMCKey("Tp05"), SMCKey("Tp09"), SMCKey("Tp0D"),
        SMCKey("Tp0H"), SMCKey("Tp0L"), SMCKey("Tp0P"), SMCKey("Tp0X"),
        SMCKey("Tp0b"), SMCKey("Tp0f"), SMCKey("Tp0j"), SMCKey("Tp0n"),
    ]

    // Apple Silicon GPU temperature probes.
    private static let gpuTempKeys: [SMCKey] = [
        SMCKey("Tg0f"), SMCKey("Tg0j"),
    ]

    init(device: SMCDevice) {
        self.device = device
    }

    // MARK: - Self-test
    //
    // Confirms the SMC is returning real, distinct sensor data rather than
    // a stuck/garbage layout. We read a temperature and a fan and check the
    // values are present, finite, distinct, and in plausible ranges.

    private(set) var selfTestPassed = false

    func runSelfTest() {
        // The kext must at least know how many keys it has.
        guard let count = try? device.keyCount(), count > 0 else {
            selfTestPassed = false
            NSLog("SMCReader: self-test failed — #KEY unreadable. SMC disabled this session.")
            return
        }

        let temp = Self.cpuTempKeys.lazy.compactMap { try? self.device.read($0) }.first
        let fan  = (try? device.read(SMCKey("F0Ac")))

        // A temperature in a sane range is the primary signal. Fans are
        // optional (fanless Macs exist), so we don't require them.
        if let t = temp, t.isFinite, t > 0, t < 130 {
            selfTestPassed = true
            let fanStr = fan.map { String(format: "%.0f rpm", $0) } ?? "no fan"
            NSLog("SMCReader: self-test OK — \(count) keys, CPU \(String(format: "%.1f°C", t)), \(fanStr).")
        } else {
            selfTestPassed = false
            NSLog("SMCReader: self-test failed — no plausible CPU temperature. SMC disabled this session.")
        }
    }

    // MARK: - Fan discovery
    //
    // Read the fan count (FNum) once and build the live-RPM key list
    // (F0Ac, F1Ac, …) from it instead of hard-coding two fans.

    private lazy var fanRPMKeys: [SMCKey] = {
        let count = (try? device.read(SMCKey("FNum"))).map { Int($0) } ?? 0
        guard count > 0, count < 10 else { return [] }
        return (0..<count).map { SMCKey("F\($0)Ac") }
    }()

    // MARK: - Read all

    /// Read all sensors in one pass. Any sensor that fails is reported as
    /// nil / omitted — the caller decides whether to store partial data.
    func readAll() -> SystemSnapshot {
        var snapshot = SystemSnapshot(timestamp: Date())
        guard selfTestPassed else { return snapshot }

        let cpuTemps = Self.cpuTempKeys.compactMap { try? device.read($0) }
            .filter { $0.isFinite && $0 > 0 && $0 < 130 }
        if !cpuTemps.isEmpty {
            snapshot.cpuTempC = cpuTemps.reduce(0, +) / Double(cpuTemps.count)
        }

        let gpuTemps = Self.gpuTempKeys.compactMap { try? device.read($0) }
            .filter { $0.isFinite && $0 > 0 && $0 < 130 }
        if !gpuTemps.isEmpty {
            snapshot.gpuTempC = gpuTemps.reduce(0, +) / Double(gpuTemps.count)
        }

        snapshot.fanRPMs = fanRPMKeys.compactMap { try? device.read($0) }
            .filter { $0.isFinite && $0 >= 0 }
            .map { Int($0.rounded()) }

        // Advertised max CPU frequency (sysctl). Apple Silicon has no clean
        // per-sample current frequency; the anomaly detector buckets by load.
        snapshot.cpuFreqGHz = SystemStats.cpuMaxFrequencyGHz()

        return snapshot
    }
}

// MARK: - SystemSnapshot
//
// A point-in-time reading of every sensor the app tracks. Persisted to
// SQLite by Sampler. All fields are optional because a partial read is
// valid (e.g. a fanless Mac, or a probe missing on a given SoC).

struct SystemSnapshot {
    var timestamp: Date
    var cpuTempC:  Double?
    var gpuTempC:  Double?
    var cpuFreqGHz: Double?
    var cpuLoad:    Double?     // 0..1
    var gpuLoad:    Double?     // 0..1, approximate
    var cpuPState:  [Int] = []  // raw P-State indices per cluster
    var fanRPMs:    [Int] = []
}
