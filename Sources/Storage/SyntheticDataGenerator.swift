import Foundation

// MARK: - SyntheticDataGenerator
//
// When the SMC read isn't usable (typical on macOS 26 today), we
// still want the user to see the UI in action. This generator
// produces realistic-looking temperature/fan/load data and writes
// it directly to the database as if it were coming from the SMC.
//
// The output is:
//   - Deterministic for a given seed (so the user can regenerate
//     with a different seed and see different patterns)
//   - Realistic in shape: a daily rhythm (hot during work hours,
//     cool at night), a weekly rhythm (slightly warmer on weekdays),
//     and random noise
//   - Tied together: when CPU temp goes up, fan RPM goes up too
//   - "Good" thermals by default, with a gradual 0.01°C/day drift
//     so the long-term anomaly detector (Mann-Whitney U) has
//     something to find after a few weeks
//
// The generator is also useful for testing the alert pipeline: spin
// up 30 days of "all normal" data, then add a hot week on top, and
// confirm the comparator fires.

struct SyntheticConfig: Equatable, Codable {
    var enabled: Bool = false
    var seed: UInt64 = 42
    var daysOfData: Int = 30
    var ambientTemp: Double = 32.0   // CPU at rest, no work
    var loadTempBoost: Double = 28.0 // extra at 100% load
    var gpuTempOffset: Double = -3.0 // GPU typically cooler
    var fanRpmBase: Int = 1800
    var fanRpmPerDegree: Double = 80 // RPM bump per °C above 50°C
    var noiseLevel: Double = 0.8
    var dailyDrift: Double = 0.01    // °C per day, UNIFORM (ambient-like) shift
    // Load-scaled degradation: extra °C per day that is PROPORTIONAL to load.
    // This models a real cooling-capacity loss (rising thermal resistance):
    // idle stays put, loaded states get progressively hotter. The
    // ambient-corrected detector should fire on THIS but not on dailyDrift.
    var loadDegradationPerDay: Double = 0.0

    /// Used by the Database to know which "mode" the user picked.
    static let userDefaultsKey = "syntheticConfig.v1"

    /// Load from UserDefaults, or return the default config.
    static func load() -> SyntheticConfig {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let cfg = try? JSONDecoder().decode(SyntheticConfig.self, from: data) {
            return cfg
        }
        return SyntheticConfig()
    }

    /// Persist to UserDefaults.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

enum SyntheticDataGenerator {

    /// Generate and insert `days` worth of 1-minute samples ending at
    /// `endDate`. Existing samples in the same range are overwritten
    /// (INSERT OR REPLACE semantics).
    ///
    /// This is slow for large ranges (30 days × 24h × 60min = 43,200
    /// rows), so it runs on a background queue.
    static func generate(database: Database, days: Int, seed: UInt64,
                          endDate: Date = Date(),
                          progress: ((Double) -> Void)? = nil) throws {
        let cfg = SyntheticConfig(seed: seed, daysOfData: days)
        let totalSamples = days * 24 * 60
        let stepSeconds: TimeInterval = 60
        var rng = SplitMix64(seed: seed)

        // For performance, batch-insert with a transaction.
        try database.transaction {
            for i in 0..<totalSamples {
                let ts = endDate.addingTimeInterval(-Double(totalSamples - i) * stepSeconds)
                let sample = sampleAt(ts: ts, cfg: cfg, rng: &rng)
                try database.insert(sample)
                if let p = progress, i % 200 == 0 {
                    p(Double(i) / Double(totalSamples))
                }
            }
        }
        if let p = progress { p(1.0) }
    }

    /// Generate a single sample at a given timestamp. Exposed so the
    /// Sampler can use it for live demo mode (one sample at a time).
    static func sampleAt(ts: Date, cfg: SyntheticConfig,
                          rng: inout SplitMix64) -> Sample {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .weekday], from: ts)
        let hour = Double(comps.hour ?? 12)
        let minute = Double(comps.minute ?? 0)
        let weekday = comps.weekday ?? 1   // 1=Sun, 7=Sat

        // Daily rhythm: 0 at midnight, peaks around 14:00.
        let dailyPhase = (hour + minute / 60.0) / 24.0 * 2 * .pi
        let dailyCurve = (sin(dailyPhase - .pi / 2) + 1) / 2  // 0..1

        // Weekly rhythm: weekdays slightly warmer than weekends.
        let weekdayFactor: Double = (weekday == 1 || weekday == 7) ? 0.6 : 0.95

        // Random "task" load: occasional spikes to ~95% on top of the
        // base load. This makes the data look like a real machine.
        let spikeNoise = rng.nextDouble()
        let spike: Double = spikeNoise > 0.97 ? rng.nextDouble() * 0.7 : 0

        // Composite load: 0..1.
        let baseLoad = 0.15 + 0.55 * dailyCurve * weekdayFactor
        let load = max(0, min(1, baseLoad + spike))

        // Slow drift: 0.01 °C/day of "thermal degradation" simulation.
        // Newer samples (more recent dates) get a tiny bump, so over
        // a few weeks the median at any P-State rises a few tenths
        // of a degree — exactly the kind of small drift the alert
        // detector is designed to catch.
        let now = Date()
        let daysSinceSample = now.timeIntervalSince(ts) / 86400.0
        let drift = cfg.dailyDrift * daysSinceSample
        // Recent samples (small daysSinceSample) get MORE load-scaled
        // degradation than old ones, and it scales with load — so the rise
        // above idle grows over time while idle is untouched.
        let degradationAge = max(0, cfg.daysOfData - 0) // span in days
        let recencyFraction = degradationAge > 0
            ? max(0.0, 1.0 - daysSinceSample / Double(degradationAge))
            : 0.0
        let loadDegradation = cfg.loadDegradationPerDay
            * Double(cfg.daysOfData) * recencyFraction * load

        // Temperatures with Gaussian-ish noise via Box-Muller.
        let cpuTemp = cfg.ambientTemp
                     + cfg.loadTempBoost * load
                     + drift
                     + loadDegradation
                     + gaussian(rng: &rng) * cfg.noiseLevel
        let gpuTemp = cpuTemp + cfg.gpuTempOffset
                     + gaussian(rng: &rng) * cfg.noiseLevel

        // Fan RPM: stays at base below 50°C, ramps up linearly above.
        let above = max(0, cpuTemp - 50.0)
        let fanRpm = Double(cfg.fanRpmBase)
                   + above * cfg.fanRpmPerDegree
                   + abs(gaussian(rng: &rng)) * cfg.noiseLevel * 20

        // CPU P-State: rough proxy for frequency. 0 at idle, up to 8
        // under load. P-State is a qualitative index, not GHz.
        let pState = Int((load * 8).rounded())

        return Sample(
            timestamp: ts,
            cpuTempC:  cpuTemp,
            gpuTempC:  gpuTemp,
            cpuFreqGHz: nil,                          // not synthesized
            cpuLoad:   load,
            gpuLoad:   max(0, min(1, load * 0.6 + gaussian(rng: &rng) * 0.05)),
            cpuPState: load > 0.05 ? [pState] : [],
            fanRPMs:   fanRpm > 0 ? [Int(fanRpm.rounded())] : [],
            source:    .synthetic
        )
    }

    // MARK: - Helpers

    /// Box-Muller transform → standard normal sample.
    private static func gaussian(rng: inout SplitMix64) -> Double {
        let u1 = max(rng.nextDouble(), 1e-12)
        let u2 = rng.nextDouble()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

// MARK: - SplitMix64 PRNG
//
// A tiny, fast, deterministic 64-bit PRNG. Good enough for noise in
// synthetic data. Seedable, repeatable.

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double {
        // 53-bit precision
        return Double(next() >> 11) * (1.0 / Double(1 << 53))
    }
}
