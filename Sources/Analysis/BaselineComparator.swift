import Foundation

// MARK: - BaselineComparator
//
// Detects degraded cooling performance by comparing a recent window against
// a historical baseline. The hard part is separating real degradation from
// two confounds the user explicitly cares about:
//
//   (a) Workload. A machine under sustained heavy load is legitimately hot
//       with fast fans — that is not degradation. We handle this by
//       STRATIFYING on load: we only ever compare samples at the same load
//       level (bucket) against each other.
//
//   (b) Ambient / room temperature. A hotter room raises every temperature
//       by roughly the same amount, baseline and recent alike, and a few
//       degrees of seasonal drift is right at the alert threshold. Comparing
//       absolute temperatures would fire on summer arriving. We handle this
//       WITHOUT needing an ambient sensor (most Macs, including desktops,
//       don't expose a usable one) by measuring the TEMPERATURE RISE ABOVE
//       IDLE within each window:
//
//           chipTemp ≈ ambient + thermalResistance × power
//           rise(load) = temp(load) − temp(idle)
//                      ≈ thermalResistance × (power(load) − power(idle))
//
//       The ambient term cancels in the subtraction. If cooling degrades
//       (dust, dried paste), thermalResistance rises and so does `rise`. If
//       only the room got hotter, idle and loaded temps move together and
//       `rise` is unchanged. So we compare the DISTRIBUTION OF RISE in the
//       baseline window to the distribution of rise in the recent window.
//
// We run the same analysis independently for the CPU (bucketed by CPU load)
// and the GPU (bucketed by GPU load), and return whichever subsystem shows
// the most significant, ambient-corrected degradation. Fan RPM at the same
// bucket is carried as corroborating evidence.
//
// Statistics: per bucket we build the rise samples for each window and run a
// Mann-Whitney U test (non-parametric — temperature is skewed). Subtracting
// each window's own idle median is a constant per-window shift, so the test
// reads as "did the rise distribution move up?". We trigger only when the
// shift is both statistically significant (p < 0.05) and large enough to
// matter (≥ the user's threshold), or when fans had to spin significantly
// faster to hold the same bucket.

struct ThermalFinding: Equatable {
    enum Subsystem: String, Equatable { case cpu = "CPU", gpu = "GPU" }

    let subsystem: Subsystem

    // The load bucket (0..loadBuckets-1) where degradation was strongest.
    let cpuPState: Int            // kept this name for UI/back-compat; it is the load bucket

    // Absolute medians (for the comparison chart the UI already draws).
    let baselineMedian: Double
    let recentMedian: Double

    // Ambient-corrected signal: how much the rise-above-idle grew.
    let baselineRise: Double      // median rise above idle, baseline window
    let recentRise: Double        // median rise above idle, recent window
    let riseDelta: Double         // recentRise - baselineRise  (the headline number)
    let ambientCorrected: Bool    // false if no idle reference was available

    // `tempDelta` keeps its old meaning for existing UI bindings, but is now
    // the ambient-corrected riseDelta when correction was possible (falling
    // back to the raw median delta otherwise).
    let tempDelta: Double

    let fanBaselineMean: Double
    let fanRecentMean: Double
    let fanDelta: Double

    let pValue: Double
    let baselineCount: Int
    let recentCount: Int
}

struct DustRiskAssessment: Equatable {
    enum Level: Equatable {
        case insufficientData
        case none
        case minor
        case needsCleaning
    }

    let level: Level
    let evidence: ThermalFinding?
    let baselineSampleCount: Int
    let recentSampleCount: Int
    let requiredSamplesPerWindow: Int
    let baselineCoverage: Double
    let recentCoverage: Double
}

enum BaselineComparator {

    // Load is bucketed into this many levels (0..N-1) by round(load*(N-1)).
    // Matches the synthetic generator and the Sampler's P-State derivation.
    private static let loadBuckets = 9      // 0..8
    private static let minSamplesPerBucket = 30
    private static let minWindowCoverage = 0.65

    private struct WorkloadBucket: Hashable, Comparable {
        let primary: Int
        let secondary: Int

        static func < (lhs: WorkloadBucket, rhs: WorkloadBucket) -> Bool {
            if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
            return lhs.secondary < rhs.secondary
        }
    }

    /// Run the comparison and return the single most-significant finding
    /// (largest ambient-corrected rise delta) across CPU and GPU, or nil.
    static func run(database: Database, config: Config) throws -> ThermalFinding? {
        let assessment = try assessDustRisk(database: database, config: config)
        guard assessment.level == .needsCleaning else { return nil }
        return assessment.evidence
    }

    /// Return a dashboard-friendly risk assessment without changing the
    /// notification policy. Only `.needsCleaning` maps to an alertable finding;
    /// `.minor` is a significant but below-threshold shift shown as early
    /// warning context in the Overview tab.
    static func assessDustRisk(database: Database, config: Config) throws -> DustRiskAssessment {
        let now = Int64(Date().timeIntervalSince1970)
        let baselineStart = now - Int64((config.baselineDays + config.compareDays)) * 86400
        let baselineEnd   = now - Int64(config.compareDays) * 86400
        let recentStart   = now - Int64(config.compareDays) * 86400
        let recentEnd     = now

        // RAW per-sample data only — the rollups have lost the load
        // dimension and the per-sample distribution the test needs.
        let baseline = try database.fetchRawSamplesForAnalysis(from: baselineStart, to: baselineEnd)
        let recent   = try database.fetchRawSamplesForAnalysis(from: recentStart,   to: recentEnd)

        let required = minSamplesPerBucket * 2
        let baselineCoverage = windowCoverage(samples: baseline, from: baselineStart, to: baselineEnd)
        let recentCoverage = windowCoverage(samples: recent, from: recentStart, to: recentEnd)
        guard baseline.count >= required,
              recent.count >= required,
              baselineCoverage >= minWindowCoverage,
              recentCoverage >= minWindowCoverage else {
            return DustRiskAssessment(
                level: .insufficientData,
                evidence: nil,
                baselineSampleCount: baseline.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: baselineCoverage,
                recentCoverage: recentCoverage
            )
        }

        let cpuCandidates = analyzeCandidates(
            subsystem: .cpu,
            baseline: baseline, recent: recent, config: config,
            primaryLoad: { $0.cpuLoad },
            secondaryLoad: { $0.gpuLoad },
            temp: { $0.cpuTempC }
        )
        let gpuCandidates = analyzeCandidates(
            subsystem: .gpu,
            baseline: baseline, recent: recent, config: config,
            primaryLoad: { $0.gpuLoad },
            secondaryLoad: { $0.cpuLoad },
            temp: { $0.gpuTempC }
        )
        let candidates = cpuCandidates + gpuCandidates

        if let alertable = candidates
            .filter({ isAlertable($0, config: config) })
            .max(by: { $0.riseDelta < $1.riseDelta })
        {
            return DustRiskAssessment(
                level: .needsCleaning,
                evidence: alertable,
                baselineSampleCount: baseline.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: baselineCoverage,
                recentCoverage: recentCoverage
            )
        }

        if let minor = candidates
            .filter({ isMinorRisk($0, config: config) })
            .max(by: { $0.riseDelta < $1.riseDelta })
        {
            return DustRiskAssessment(
                level: .minor,
                evidence: minor,
                baselineSampleCount: baseline.count,
                recentSampleCount: recent.count,
                requiredSamplesPerWindow: required,
                baselineCoverage: baselineCoverage,
                recentCoverage: recentCoverage
            )
        }

        return DustRiskAssessment(
            level: .none,
            evidence: nil,
            baselineSampleCount: baseline.count,
            recentSampleCount: recent.count,
            requiredSamplesPerWindow: required,
            baselineCoverage: baselineCoverage,
            recentCoverage: recentCoverage
        )
    }

    // MARK: - Core analysis for one subsystem

    private static func analyzeCandidates(
        subsystem: ThermalFinding.Subsystem,
        baseline: [Sample], recent: [Sample], config: Config,
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?,
        temp: (Sample) -> Double?
    ) -> [ThermalFinding] {

        let baseBuckets = bucketByLoad(
            baseline, primaryLoad: primaryLoad, secondaryLoad: secondaryLoad, temp: temp)
        let recBuckets  = bucketByLoad(
            recent, primaryLoad: primaryLoad, secondaryLoad: secondaryLoad, temp: temp)

        // Idle reference = the lowest populated bucket present in BOTH
        // windows. Its median temperature stands in for "ambient + idle
        // power" and is subtracted from every sample in the same window.
        guard let idleBucket = lowestSharedBucket(baseBuckets, recBuckets) else {
            // No common idle reference → cannot ambient-correct. Fall back to
            // an absolute-temperature comparison at the worst shared bucket.
            return absoluteFallbackCandidates(
                subsystem: subsystem,
                baseBuckets: baseBuckets, recBuckets: recBuckets,
                baseline: baseline, recent: recent, config: config,
                primaryLoad: primaryLoad,
                secondaryLoad: secondaryLoad
            )
        }

        let baseIdleMed = median(baseBuckets[idleBucket] ?? [])
        let recIdleMed  = median(recBuckets[idleBucket] ?? [])

        var candidates: [ThermalFinding] = []

        // Compare every loaded bucket (above idle) shared by both windows.
        let sharedBuckets = Set(baseBuckets.keys).intersection(recBuckets.keys)
            .filter { $0.primary > idleBucket.primary }
            .sorted()

        for b in sharedBuckets {
            let baseTemps = baseBuckets[b] ?? []
            let recTemps  = recBuckets[b]  ?? []
            guard baseTemps.count >= minSamplesPerBucket,
                  recTemps.count  >= minSamplesPerBucket else { continue }

            // Rise above this window's own idle median (cancels ambient).
            let baseRise = baseTemps.map { $0 - baseIdleMed }
            let recRise  = recTemps.map  { $0 - recIdleMed }

            let baseRiseMed = median(baseRise)
            let recRiseMed  = median(recRise)
            let riseDelta   = recRiseMed - baseRiseMed

            // Significance of the shift in the rise distribution.
            let u = mannWhitneyU(baseRise, recRise)
            let p = mannWhitneyPValue(U: u, n1: baseRise.count, n2: recRise.count)

            // Fan evidence at this bucket.
            let (fanBase, fanRec, fanDelta) = fanStats(
                baseline: baseline, recent: recent, bucket: b,
                primaryLoad: primaryLoad,
                secondaryLoad: secondaryLoad)

            let candidate = ThermalFinding(
                subsystem: subsystem,
                cpuPState: b.primary,
                baselineMedian: median(baseTemps),
                recentMedian:   median(recTemps),
                baselineRise:   baseRiseMed,
                recentRise:     recRiseMed,
                riseDelta:      riseDelta,
                ambientCorrected: true,
                tempDelta:      riseDelta,
                fanBaselineMean: fanBase,
                fanRecentMean:   fanRec,
                fanDelta:        fanDelta,
                pValue:          p,
                baselineCount:   baseTemps.count,
                recentCount:     recTemps.count
            )
            candidates.append(candidate)
        }
        return candidates
    }

    // MARK: - Absolute-temperature fallback
    //
    // Used only when there is no shared idle bucket to anchor the rise (e.g.
    // a machine that is never idle in one of the windows). We compare
    // absolute temperatures at the worst shared bucket and flag the finding
    // as NOT ambient-corrected so the UI/alert can soften the wording.

    private static func absoluteFallbackCandidates(
        subsystem: ThermalFinding.Subsystem,
        baseBuckets: [WorkloadBucket: [Double]], recBuckets: [WorkloadBucket: [Double]],
        baseline: [Sample], recent: [Sample], config: Config,
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?
    ) -> [ThermalFinding] {
        let shared = Set(baseBuckets.keys).intersection(recBuckets.keys).sorted()
        var candidates: [ThermalFinding] = []
        for b in shared {
            let baseTemps = baseBuckets[b] ?? []
            let recTemps  = recBuckets[b]  ?? []
            guard baseTemps.count >= minSamplesPerBucket,
                  recTemps.count  >= minSamplesPerBucket else { continue }

            let baseMed = median(baseTemps)
            let recMed  = median(recTemps)
            let delta   = recMed - baseMed
            let u = mannWhitneyU(baseTemps, recTemps)
            let p = mannWhitneyPValue(U: u, n1: baseTemps.count, n2: recTemps.count)
            let (fanBase, fanRec, fanDelta) = fanStats(
                baseline: baseline, recent: recent, bucket: b,
                primaryLoad: primaryLoad,
                secondaryLoad: secondaryLoad)

            let candidate = ThermalFinding(
                subsystem: subsystem,
                cpuPState: b.primary,
                baselineMedian: baseMed,
                recentMedian:   recMed,
                baselineRise:   0,
                recentRise:     0,
                riseDelta:      delta,
                ambientCorrected: false,
                tempDelta:      delta,
                fanBaselineMean: fanBase,
                fanRecentMean:   fanRec,
                fanDelta:        fanDelta,
                pValue:          p,
                baselineCount:   baseTemps.count,
                recentCount:     recTemps.count
            )
            candidates.append(candidate)
        }
        return candidates
    }

    private static func isAlertable(_ finding: ThermalFinding, config: Config) -> Bool {
        let tempTriggered = finding.pValue < 0.05 && finding.tempDelta >= config.tempThresholdC
        let fanTriggered = finding.pValue < 0.05 && finding.fanDelta >= Double(config.fanThresholdRPM)
        return tempTriggered || fanTriggered
    }

    private static func isMinorRisk(_ finding: ThermalFinding, config: Config) -> Bool {
        let tempFloor = max(1.0, config.tempThresholdC * 0.5)
        let fanFloor = max(150.0, Double(config.fanThresholdRPM) * 0.5)
        let tempShift = finding.tempDelta >= tempFloor
        let fanShift = finding.fanDelta >= fanFloor
        return finding.pValue < 0.05 && (tempShift || fanShift)
    }

    // MARK: - Bucketing helpers

    /// Group temperatures by the subsystem's own load and the other major
    /// subsystem's load. This keeps GPU-heavy game sessions from being
    /// compared against CPU-only baseline samples in the same CPU bucket.
    private static func bucketByLoad(
        _ samples: [Sample],
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?,
        temp: (Sample) -> Double?
    ) -> [WorkloadBucket: [Double]] {
        var out: [WorkloadBucket: [Double]] = [:]
        for s in samples {
            guard let primary = primaryLoad(s), let t = temp(s) else { continue }
            let secondary = secondaryLoad(s) ?? 0
            let bucket = WorkloadBucket(
                primary: loadBucket(primary),
                secondary: loadBucket(secondary)
            )
            out[bucket, default: []].append(t)
        }
        return out
    }

    private static func loadBucket(_ load: Double) -> Int {
        let clamped = max(0.0, min(1.0, load))
        return Int((clamped * Double(loadBuckets - 1)).rounded())
    }

    /// Lowest bucket index present in both windows with enough samples to be
    /// a stable idle reference.
    private static func lowestSharedBucket(
        _ a: [WorkloadBucket: [Double]], _ b: [WorkloadBucket: [Double]]
    ) -> WorkloadBucket? {
        Set(a.keys).intersection(b.keys)
            .filter { (a[$0]?.count ?? 0) >= minSamplesPerBucket
                   && (b[$0]?.count ?? 0) >= minSamplesPerBucket }
            .min()
    }

    /// Mean fan RPM at a given load bucket in each window, and the delta.
    private static func fanStats(
        baseline: [Sample], recent: [Sample],
        bucket: WorkloadBucket,
        primaryLoad: (Sample) -> Double?,
        secondaryLoad: (Sample) -> Double?
    ) -> (base: Double, rec: Double, delta: Double) {
        func meanFan(_ samples: [Sample]) -> Double {
            let fans = samples.compactMap { s -> Int? in
                guard let primary = primaryLoad(s) else { return nil }
                let secondary = secondaryLoad(s) ?? 0
                let sampleBucket = WorkloadBucket(
                    primary: loadBucket(primary),
                    secondary: loadBucket(secondary)
                )
                guard sampleBucket == bucket else { return nil }
                guard let f = s.maxFanRPM, f > 0 else { return nil }
                return f
            }
            return fans.isEmpty ? 0 : Double(fans.reduce(0, +)) / Double(fans.count)
        }
        let base = meanFan(baseline)
        let rec  = meanFan(recent)
        return (base, rec, rec - base)
    }

    private static func windowCoverage(samples: [Sample], from start: Int64, to end: Int64) -> Double {
        guard let first = samples.first?.timestamp.timeIntervalSince1970,
              let last = samples.last?.timestamp.timeIntervalSince1970,
              end > start else {
            return 0
        }
        return max(0, min(1, (last - first) / Double(end - start)))
    }

    // MARK: - Math helpers

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    // MARK: - Mann-Whitney U test
    //
    // U with the normal approximation and tie-corrected average ranks. Good
    // enough for alert triggering at n ≥ 30; a permutation test would be
    // overkill for a once-a-minute sampler.

    private static func mannWhitneyU(_ a: [Double], _ b: [Double]) -> Double {
        let combined: [(Double, Int)] = a.map { ($0, 0) } + b.map { ($0, 1) }
        let sorted = combined.sorted { $0.0 < $1.0 }
        var ranks = Array(repeating: 0.0, count: sorted.count)
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].0 == sorted[i].0 { j += 1 }
            let avg = Double(i + j) / 2.0 + 1   // average rank for ties
            for k in i...j { ranks[k] = avg }
            i = j + 1
        }
        var r1: Double = 0
        for (idx, item) in sorted.enumerated() where item.1 == 0 { r1 += ranks[idx] }
        let n1 = Double(a.count)
        let u1 = r1 - n1 * (n1 + 1) / 2
        return u1
    }

    private static func mannWhitneyPValue(U: Double, n1: Int, n2: Int) -> Double {
        let mu = Double(n1 * n2) / 2.0
        let n1d = Double(n1)
        let n2d = Double(n2)
        let sigma = (n1d * n2d * (n1d + n2d + 1) / 12.0).squareRoot()
        guard sigma > 0 else { return 1.0 }
        let z = (U - mu).magnitude - 0.5    // continuity correction
        return 2.0 * (1.0 - normalCdf(z / sigma))
    }

    /// Standard normal CDF via the Abramowitz & Stegun erf approximation.
    private static func normalCdf(_ z: Double) -> Double {
        let a1 =  0.254829592
        let a2 = -0.284496736
        let a3 =  1.421413741
        let a4 = -1.453152027
        let a5 =  1.061405429
        let p  =  0.3275911
        let sign = z < 0 ? -1.0 : 1.0
        let x = z.magnitude / sqrt(2.0)
        let t = 1.0 / (1.0 + p * x)
        let y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * exp(-x * x)
        return 0.5 * (1.0 + sign * y)
    }
}
