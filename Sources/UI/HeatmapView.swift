import SwiftUI

// MARK: - HeatmapView
//
// Calendar view for long-term thermal history. The default view colors each
// local day by sustained high-temperature duration, which is more diagnostic
// than a single daily peak. A CPU-peak mode remains available for quick
// outlier inspection.

struct HeatmapView: View {
    /// Number of weeks to display. Default 26 (half a year). User can
    /// change to 13 / 26 / 52 via a picker.
    @State private var weeks: Int = 26
    @State private var metric: HeatmapMetric = .hotDuration
    @State private var daily: [DailyStats] = []
    @State private var dailyDurations: [DailyThresholdDuration] = []
    @State private var sampleIntervalSec: Int = 60
    @State private var loading: Bool = false
    @State private var selected: DayCell?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            legend
            heatmapGrid
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Daily heatmap")).font(.title2).fontWeight(.semibold)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Picker(L("Metric"), selection: $metric) {
                    ForEach(HeatmapMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Picker(L("Range"), selection: $weeks) {
                    Text(L("13 weeks")).tag(13)
                    Text(L("26 weeks")).tag(26)
                    Text(L("52 weeks")).tag(52)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .onChange(of: weeks) { _ in load() }
            }
            Text(metric.description)
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 12) {
            Text(metric.lowLabel)
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(metric.legendColors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 14, height: 14)
            }
            Text(metric.highLabel)
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(L("Opacity shows sample coverage"))
                .font(.caption2).foregroundStyle(.secondary)
            Text(String(format: L("%d of %d days have data"), daysWithData, totalDays))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Grid
    //
    // We build a 2D array of weeks x days. Each week is 7 cells
    // (Sun-Sat). Empty days render as a subtle outlined cell. Days with
    // data use the selected metric's color scale.

    private var weeks7: [[DayCell]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = Self.heatmapStartDate(weeks: weeks)

        var statsByDay: [Date: DailyStats] = [:]
        for stats in daily {
            statsByDay[cal.startOfDay(for: stats.date)] = stats
        }

        var durationsByDay: [Date: DailyThresholdDuration] = [:]
        for duration in dailyDurations {
            durationsByDay[cal.startOfDay(for: duration.date)] = duration
        }

        var result: [[DayCell]] = []
        for w in 0..<weeks {
            var week: [DayCell] = []
            for d in 0..<7 {
                if let day = cal.date(byAdding: .day, value: w * 7 + d, to: start) {
                    let normalizedDay = cal.startOfDay(for: day)
                    week.append(DayCell(
                        date: normalizedDay,
                        isFuture: normalizedDay > today,
                        isToday: cal.isDateInToday(normalizedDay),
                        stats: statsByDay[normalizedDay],
                        duration: durationsByDay[normalizedDay]
                    ))
                }
            }
            result.append(week)
        }
        return result
    }

    @ViewBuilder
    private var heatmapGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(weeks7.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 4) {
                        ForEach(week) { cell in
                            DaySquare(
                                cell: cell,
                                metric: metric,
                                sampleIntervalSec: sampleIntervalSec
                            )
                            .onTapGesture {
                                if cell.stats != nil { selected = cell }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .popover(item: $selected) { day in
            DayDetail(cell: day, sampleIntervalSec: sampleIntervalSec)
        }
    }

    // MARK: - Counts

    private var daysWithData: Int { daily.count }
    private var totalDays: Int { weeks * 7 }

    // MARK: - Loading

    private func load() {
        loading = true
        let selectedWeeks = weeks
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Date()
            let start = Self.heatmapStartDate(weeks: selectedWeeks, now: now)
            let db = Sampler.shared.databaseHandle
            let daily = (try? db.fetchDailyStats(
                from: Int64(start.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? []
            let durations = (try? db.fetchDailyThresholdDurations(
                from: Int64(start.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? []
            let cfg = (try? db.loadConfig()) ?? Config()

            DispatchQueue.main.async {
                self.daily = daily
                self.dailyDurations = durations
                self.sampleIntervalSec = cfg.sampleIntervalSec
                self.loading = false
            }
        }
    }

    private static func heatmapStartDate(weeks: Int, now: Date = Date()) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let startOfWeek = cal.date(
            byAdding: .day,
            value: -cal.component(.weekday, from: today) + 1,
            to: today
        ) ?? today
        return cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: startOfWeek) ?? startOfWeek
    }
}

// MARK: - Metric

private enum HeatmapMetric: String, CaseIterable, Identifiable {
    case hotDuration
    case cpuPeak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hotDuration: return L("High-temp duration")
        case .cpuPeak: return L("CPU peak")
        }
    }

    var description: String {
        switch self {
        case .hotDuration:
            return L("Each square is one local day, colored by time above 70°C. Opacity reflects sample coverage.")
        case .cpuPeak:
            return L("Each square is one local day, colored by daily CPU peak. Opacity reflects sample coverage.")
        }
    }

    var lowLabel: String {
        switch self {
        case .hotDuration: return L("none")
        case .cpuPeak: return L("cool")
        }
    }

    var highLabel: String {
        switch self {
        case .hotDuration: return L("long")
        case .cpuPeak: return L("hot")
        }
    }

    var legendColors: [Color] {
        switch self {
        case .hotDuration: return DurationHeatPalette.colors
        case .cpuPeak: return PeakHeatPalette.colors
        }
    }
}

// MARK: - DayCell model

private struct DayCell: Identifiable {
    let date: Date
    let isFuture: Bool
    let isToday: Bool
    let stats: DailyStats?
    let duration: DailyThresholdDuration?

    var id: Date { date }

    func coverageFraction(sampleIntervalSec: Int, now: Date = Date()) -> Double {
        guard let stats, stats.sampleCount > 0 else { return 0 }
        let cal = Calendar.current
        let dayEnd = cal.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
        let expectedEnd = isToday ? min(now, dayEnd) : dayEnd
        let expectedSeconds = max(1, expectedEnd.timeIntervalSince(date))
        let representedSeconds = Double(stats.sampleCount * max(sampleIntervalSec, 1))
        return min(1, max(0, representedSeconds / expectedSeconds))
    }
}

// MARK: - DaySquare

private struct DaySquare: View {
    let cell: DayCell
    let metric: HeatmapMetric
    let sampleIntervalSec: Int

    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fillColor.opacity(fillOpacity))
            .frame(width: 16, height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(borderColor, style: borderStroke)
            )
            .overlay {
                if hovering && cell.stats != nil {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                }
            }
            .onHover { hovering = $0 }
            .help(tooltip)
    }

    private var fillColor: Color {
        if cell.isFuture { return Color.gray.opacity(0.05) }
        guard let stats = cell.stats else { return Color.gray.opacity(0.1) }
        switch metric {
        case .hotDuration:
            return DurationHeatPalette.color(forSeconds: cell.duration?.secondsAbove70 ?? 0)
        case .cpuPeak:
            return PeakHeatPalette.color(forPeak: stats.cpuTempPeak)
        }
    }

    private var fillOpacity: Double {
        guard cell.stats != nil, !cell.isFuture else { return 1 }
        let coverage = cell.coverageFraction(sampleIntervalSec: sampleIntervalSec)
        return 0.32 + coverage * 0.68
    }

    private var borderColor: Color {
        if cell.isToday { return .accentColor }
        if cell.isFuture { return .clear }
        guard cell.stats != nil else { return Color.gray.opacity(0.2) }
        if cell.coverageFraction(sampleIntervalSec: sampleIntervalSec) < 0.25 {
            return Color.secondary.opacity(0.5)
        }
        return Color.gray.opacity(0.22)
    }

    private var borderStroke: StrokeStyle {
        let coverage = cell.coverageFraction(sampleIntervalSec: sampleIntervalSec)
        let dash: [CGFloat] = cell.stats != nil && coverage < 0.25 && !cell.isToday ? [2, 2] : []
        return StrokeStyle(lineWidth: cell.isToday ? 1.5 : 0.5, dash: dash)
    }

    private var tooltip: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd (EEE)"
        var line = df.string(from: cell.date)
        guard let stats = cell.stats else {
            return line + "\n" + L("No data")
        }

        let hot70 = formatHeatmapDuration(cell.duration?.secondsAbove70 ?? 0)
        let hot75 = formatHeatmapDuration(cell.duration?.secondsAbove75 ?? 0)
        let cpu = stats.cpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—"
        let gpu = stats.gpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—"
        let coverage = formatHeatmapPercent(cell.coverageFraction(sampleIntervalSec: sampleIntervalSec))

        line += "\n" + L("Above 70°C: %@  Above 75°C: %@", hot70, hot75)
        line += "\n" + L("CPU peak: %@  GPU peak: %@  (%@ samples)", cpu, gpu, String(stats.sampleCount))
        line += "\n" + L("Coverage: %@", coverage)
        return line
    }
}

// MARK: - DayDetail popover

private struct DayDetail: View {
    let cell: DayCell
    let sampleIntervalSec: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cell.date.formatted(date: .complete, time: .omitted))
                .font(.headline)
            Divider()
            row(L("Above 70°C"), formatHeatmapDuration(cell.duration?.secondsAbove70 ?? 0))
            row(L("Above 75°C"), formatHeatmapDuration(cell.duration?.secondsAbove75 ?? 0))
            row(L("Sample coverage"), formatHeatmapPercent(cell.coverageFraction(sampleIntervalSec: sampleIntervalSec)))
            Divider()
            if let stats = cell.stats {
                row(L("Samples"), String(stats.sampleCount))
                row(L("CPU peak"), stats.cpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—")
                row(L("CPU avg"),  stats.cpuTempAvg.map  { String(format: "%.1f°C", $0) } ?? "—")
                row(L("CPU min"),  stats.cpuTempMin.map  { String(format: "%.1f°C", $0) } ?? "—")
                row(L("GPU peak"), stats.gpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—")
                row(L("Fan peak"), stats.fanRpmPeak.map  { "\($0) RPM" } ?? "—")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - Palettes

private enum DurationHeatPalette {
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.65, blue: 0.42),
        Color(red: 0.78, green: 0.82, blue: 0.36),
        Color(red: 0.96, green: 0.65, blue: 0.14),
        Color(red: 0.91, green: 0.34, blue: 0.18),
        Color(red: 0.78, green: 0.13, blue: 0.18),
    ]

    static func color(forSeconds seconds: Int) -> Color {
        let minutes = seconds / 60
        switch minutes {
        case 0: return colors[0]
        case 1..<15: return colors[1]
        case 15..<60: return colors[2]
        case 60..<180: return colors[3]
        default: return colors[4]
        }
    }
}

private enum PeakHeatPalette {
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.65, blue: 0.42),
        Color(red: 0.78, green: 0.82, blue: 0.36),
        Color(red: 0.96, green: 0.65, blue: 0.14),
        Color(red: 0.91, green: 0.34, blue: 0.18),
        Color(red: 0.78, green: 0.13, blue: 0.18),
    ]

    static func color(forPeak temp: Double?) -> Color {
        guard let temp else { return Color.gray.opacity(0.1) }
        switch temp {
        case ..<40: return colors[0]
        case 40..<55: return colors[1]
        case 55..<70: return colors[2]
        case 70..<85: return colors[3]
        default: return colors[4]
        }
    }
}

// MARK: - Formatting

private func formatHeatmapDuration(_ seconds: Int) -> String {
    guard seconds > 0 else { return L("0 min") }
    if seconds < 60 { return L("<1 min") }
    let minutes = Int((Double(seconds) / 60.0).rounded())
    if minutes < 60 {
        return L("%d min", minutes)
    }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if remainingMinutes == 0 {
        return L("%d h", hours)
    }
    return L("%d h %d min", hours, remainingMinutes)
}

private func formatHeatmapPercent(_ fraction: Double) -> String {
    String(format: "%.0f%%", min(1, max(0, fraction)) * 100)
}
