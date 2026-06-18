import SwiftUI

// MARK: - HeatmapView
//
// A GitHub-contributions-style calendar. Each day is a small square
// colored by the day's peak CPU temperature. Click a day to see its
// details in a popover.
//
// Layout: weeks run top-to-bottom, days left-to-right within a week,
// like a wall calendar. We group daily stats by week, fill in empty
// days, and color them by peak temp.

struct HeatmapView: View {
    /// Number of weeks to display. Default 26 (half a year). User can
    /// change to 13 / 26 / 52 via a picker.
    @State private var weeks: Int = 26
    @State private var daily: [DailyStats] = []
    @State private var loading: Bool = false
    @State private var selected: DailyStats?

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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L("Daily heatmap")).font(.title2).fontWeight(.semibold)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Picker(L("Range"), selection: $weeks) {
                    Text(L("13 weeks")).tag(13)
                    Text(L("26 weeks")).tag(26)
                    Text(L("52 weeks")).tag(52)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .onChange(of: weeks) { _ in load() }
            }
            Text(L("Each square is one day, colored by peak CPU temperature. Hover or click for details."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 12) {
            Text(L("cool"))
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(HeatPalette.allCases) { p in
                RoundedRectangle(cornerRadius: 2)
                    .fill(p.color)
                    .frame(width: 14, height: 14)
            }
            Text(L("hot"))
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: L("%d of %d days have data"), daysWithData, totalDays))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Grid
    //
    // We build a 2D array of weeks × days. Each week is 7 cells
    // (Sun-Sat). Empty days (no samples) render as a subtle outlined
    // cell. Days with data use the heatmap color.

    private var weeks7: [[DayCell]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .weekOfYear, value: -(weeks - 1),
                                   to: cal.date(byAdding: .day,
                                                value: -cal.component(.weekday, from: today) + 1,
                                                to: today)!) else {
            return []
        }
        let statsByDay = Dictionary(uniqueKeysWithValues: daily.map { (cal.startOfDay(for: $0.date), $0) })
        var result: [[DayCell]] = []
        for w in 0..<weeks {
            var week: [DayCell] = []
            for d in 0..<7 {
                if let day = cal.date(byAdding: .day, value: w * 7 + d, to: start) {
                    let isFuture = day > today
                    let stats = statsByDay[day]
                    week.append(DayCell(
                        date: day,
                        isFuture: isFuture,
                        isToday: cal.isDateInToday(day),
                        stats: stats
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
                        ForEach(0..<7, id: \.self) { d in
                            let cell = week[d]
                            DaySquare(cell: cell)
                                .onTapGesture {
                                    if let s = cell.stats { selected = s }
                                }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
        .popover(item: $selected) { day in
            DayDetail(stats: day)
        }
    }

    // MARK: - Counts

    private var daysWithData: Int { daily.count }
    private var totalDays: Int { weeks * 7 }

    // MARK: - Loading

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: -weeks * 7, to: Date())!
            let daily = (try? Sampler.shared.databaseHandle.fetchDailyStats(
                from: Int64(start.timeIntervalSince1970),
                to:   Int64(Date().timeIntervalSince1970))) ?? []
            DispatchQueue.main.async {
                self.daily = daily
                self.loading = false
            }
        }
    }
}

// MARK: - DayCell model
//
// One day in the heatmap. Lightweight value type.

struct DayCell {
    let date: Date
    let isFuture: Bool
    let isToday: Bool
    let stats: DailyStats?
}

// MARK: - DaySquare
//
// Renders a single cell. Empty days get a subtle outline; future days
// are dim; today has a thicker border. Days with data use a heat color.

struct DaySquare: View {
    let cell: DayCell

    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fillColor)
            .frame(width: 16, height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(borderColor, lineWidth: cell.isToday ? 1.5 : 0.5)
            )
            .scaleEffect(hovering ? 1.4 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: hovering)
            .onHover { hovering = $0 }
            .help(tooltip)
    }

    private var fillColor: Color {
        if cell.isFuture { return Color.gray.opacity(0.05) }
        guard let s = cell.stats, let p = s.cpuTempPeak else {
            return Color.gray.opacity(0.1)
        }
        return HeatPalette.color(forPeak: p)
    }

    private var borderColor: Color {
        if cell.isToday { return .accentColor }
        if cell.isFuture { return .clear }
        return Color.gray.opacity(0.2)
    }

    private var tooltip: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd (EEE)"
        var line = df.string(from: cell.date)
        if let s = cell.stats {
            let cpu = s.cpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—"
            let gpu = s.gpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—"
            line += "\n" + String(format: L("CPU peak: %@  GPU peak: %@  (%@ samples)"),
                                 cpu, gpu, String(s.sampleCount))
        } else {
            line += "\n" + L("No data")
        }
        return line
    }
}

// MARK: - DayDetail popover
//
// When a day is clicked, show a small popover with the day's stats.

struct DayDetail: View {
    let stats: DailyStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stats.date.formatted(date: .complete, time: .omitted))
                .font(.headline)
            Divider()
            row(L("Samples"), String(stats.sampleCount))
            row(L("CPU peak"), stats.cpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—")
            row(L("CPU avg"),  stats.cpuTempAvg.map  { String(format: "%.1f°C", $0) } ?? "—")
            row(L("CPU min"),  stats.cpuTempMin.map  { String(format: "%.1f°C", $0) } ?? "—")
            row(L("GPU peak"), stats.gpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—")
            row(L("Fan peak"), stats.fanRpmPeak.map  { "\($0) RPM" }            ?? "—")
        }
        .padding(14)
        .frame(width: 260)
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

// MARK: - HeatPalette
//
// Maps a peak temperature to one of 5 colors. Tweak the bands here
// to retune the visual scale.

enum HeatPalette: String, CaseIterable, Identifiable {
    case cool, mild, warm, hot, veryHot
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .cool:    return Color(red: 0.30, green: 0.65, blue: 0.42)
        case .mild:    return Color(red: 0.78, green: 0.82, blue: 0.36)
        case .warm:    return Color(red: 0.96, green: 0.65, blue: 0.14)
        case .hot:     return Color(red: 0.91, green: 0.34, blue: 0.18)
        case .veryHot: return Color(red: 0.78, green: 0.13, blue: 0.18)
        }
    }

    static func color(forPeak temp: Double) -> Color {
        switch temp {
        case ..<40:  return HeatPalette.cool.color
        case 40..<55: return HeatPalette.mild.color
        case 55..<70: return HeatPalette.warm.color
        case 70..<85: return HeatPalette.hot.color
        default:      return HeatPalette.veryHot.color
        }
    }
}
