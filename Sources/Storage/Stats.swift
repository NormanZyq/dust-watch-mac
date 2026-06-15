import Foundation

// MARK: - Aggregated stats structs
//
// These are pre-computed aggregates over a time range. They're
// returned by Database.fetchDailyStats / fetchHourlyStats and used
// by the Overview tab, the heatmap, and the Compare chart.
//
// We keep the structs small and value-typed so they can flow through
// SwiftUI without observation overhead.

struct DailyStats: Equatable, Identifiable {
    /// Midnight of the day (local time) this row represents.
    let date: Date
    let sampleCount: Int
    let cpuTempPeak: Double?
    let cpuTempAvg: Double?
    let cpuTempMin: Double?
    let gpuTempPeak: Double?
    let gpuTempAvg: Double?
    let fanRpmPeak: Int?
    let fanRpmAvg: Double?

    var id: Date { date }
}

struct HourlyStats: Equatable, Identifiable {
    let hour: Date
    let sampleCount: Int
    let cpuTempPeak: Double?
    let cpuTempAvg: Double?
    let cpuTempMin: Double?
    let gpuTempPeak: Double?
    let gpuTempAvg: Double?
    let fanRpmPeak: Int?
    let fanRpmAvg: Double?

    var id: Date { hour }
}

struct SummaryStats: Equatable {
    let from: Date
    let to: Date
    let sampleCount: Int
    let cpuTempPeak: Double?
    let cpuTempAvg: Double?
    let cpuTempMin: Double?
    let gpuTempPeak: Double?
    let gpuTempAvg: Double?
    let fanRpmPeak: Int?
    let fanRpmAvg: Double?
    /// Number of minutes where CPU temp was above `thresholdC`.
    let cpuMinutesAboveThreshold: Int

    static func empty(from: Date, to: Date) -> SummaryStats {
        SummaryStats(
            from: from, to: to, sampleCount: 0,
            cpuTempPeak: nil, cpuTempAvg: nil, cpuTempMin: nil,
            gpuTempPeak: nil, gpuTempAvg: nil,
            fanRpmPeak: nil, fanRpmAvg: nil,
            cpuMinutesAboveThreshold: 0
        )
    }
}
