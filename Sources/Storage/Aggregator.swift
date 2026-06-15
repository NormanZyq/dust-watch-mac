import Foundation

// MARK: - Config
//
// User-tunable settings, persisted in the `config` table. The default
// values match what a casual user would want; power users can tweak.

struct Config: Equatable {
    var sampleIntervalSec: Int   = 60
    var tempThresholdC:    Double = 3.0
    var fanThresholdRPM:   Int    = 500
    var baselineDays:      Int    = 60
    var compareDays:       Int    = 7
    var notificationsEnabled: Bool = true
}

// MARK: - Aggregator
//
// Periodically rolls up old data so the database stays small:
//
//   samples (raw, 1-min)    -- N days  -->    samples_hourly
//   samples_hourly          -- 1 year  -->    samples_daily
//   samples_daily           -- kept forever
//
// N (raw retention) is NOT a fixed 30 days: it is derived from the
// degradation detector's baseline window (Database.rawRetentionDays), so
// the detector always has per-sample data covering its full baseline. The
// rollups lose the per-sample load/P-State distribution, which the
// Mann-Whitney test and load-bucketing require — so raw rows must survive
// at least as long as the baseline reaches back.
//
// Runs on its own hourly timer (see Sampler.scheduleAggregation), never on
// the per-sample path.

enum Aggregator {
    static let hourRetentionDays: Int = 365

    static func run(database: Database) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let rawCutoff  = now - Int64(database.rawRetentionDays()) * 86400
        let hourCutoff = now - Int64(hourRetentionDays) * 86400
        try database.aggregate(rawCutoffSec: rawCutoff, hourCutoffSec: hourCutoff)
    }
}
