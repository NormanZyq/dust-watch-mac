import SwiftUI
import Charts

// MARK: - OverviewView
//
// The first thing the user sees when opening the dashboard. A
// at-a-glance summary of "how is my Mac doing today?" laid out as
// cards: today's peak temperatures, a 24-hour sparkline, a 7-day
// trend, and (if applicable) a status card for any active thermal
// alert.
//
// Data is loaded on appear and refreshed whenever a new sample is
// posted (so the numbers move in real time as the sampler runs).

struct OverviewView: View {
    @State private var todayStats: SummaryStats?
    @State private var yesterdayStats: SummaryStats?
    @State private var hourly: [HourlyStats] = []
    @State private var last7Days: [DailyStats] = []
    @State private var loading: Bool = false
    @State private var latestSample: Sample?
    @State private var finding: ThermalFinding?
    @ObservedObject private var samplerObserver = SamplerObserver()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if samplerObserver.isDemoMode { demoBanner }
                statusCard
                statCardGrid
                sparklineCard
                weeklyTrendCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(
            for: Sampler.newSampleNotification)) { note in
            if let s = note.userInfo?[Sampler.sampleKey] as? Sample {
                latestSample = s
                // Light refresh: only re-fetch the small "today" summary,
                // not the whole 7-day window. That keeps the live view
                // responsive at 1 sample/min.
                refreshTodayOnly()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Overview").font(.title2).fontWeight(.semibold)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if let sample = latestSample ?? Sampler.shared.latest {
                    Text("Updated " + relativeTime(sample.timestamp))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Live summary of CPU/GPU temperature, fan activity, and recent trends.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Status card
    //
    // Shows the latest thermal-degradation finding (if any). If the
    // user has been running the app for a while and a recent window
    // shows degradation, this card is the headline.

    // Banner shown when the user is in demo mode. Explains what
    // they're looking at and links to the toggle in Settings.
    private var demoBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            DemoModeBadge()
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo data is showing").font(.headline)
                Text("Temperatures and fan RPM are synthesized, not from the SMC. Open Settings to turn this off (once SMC reads are working).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.3)))
    }

    @ViewBuilder
    private var statusCard: some View {
        if let f = finding {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.red, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thermal degradation detected")
                            .font(.headline).foregroundStyle(.red)
                        Text("\(f.subsystem.rawValue) · load level \(f.cpuPState) · rise +\(String(format: "%.1f", f.riseDelta))°C vs baseline · p=\(String(format: "%.3f", f.pValue))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(f.ambientCorrected
                     ? "At the same workload, \(f.subsystem.rawValue) now runs hotter above its idle temperature than it used to — corrected for room-temperature changes. This often indicates dust buildup or aging thermal paste."
                     : "Recent median \(f.subsystem.rawValue) temperature is significantly higher than the long-term baseline at the same workload. (No idle reference was available to correct for room temperature.)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red.opacity(0.3)))
        } else if (todayStats?.sampleCount ?? 0) == 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.secondary)
                    Text("Collecting data…").font(.headline)
                }
                Text("The sampler is running. You'll see real numbers here within a minute, and trend information over the coming days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        } else {
            EmptyView()
        }
    }

    // MARK: - Stat cards grid
    //
    // 2x2 grid: today CPU peak, today GPU peak, today fan peak,
    // minutes above threshold. Each card shows a value, a sparkline
    // delta vs yesterday, and a small label.

    private var statCardGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard(
                title: "Today · CPU peak",
                value: todayStats?.cpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—",
                delta: deltaString(current: todayStats?.cpuTempPeak, previous: yesterdayStats?.cpuTempPeak),
                icon: "thermometer.medium",
                tint: .orange
            )
            statCard(
                title: "Today · GPU peak",
                value: todayStats?.gpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—",
                delta: deltaString(current: todayStats?.gpuTempPeak, previous: yesterdayStats?.gpuTempPeak),
                icon: "display",
                tint: .blue
            )
            statCard(
                title: "Today · Fan peak",
                value: todayStats?.fanRpmPeak.map { "\($0) RPM" } ?? "—",
                delta: deltaString(current: todayStats?.fanRpmAvg, previous: yesterdayStats?.fanRpmAvg, suffix: " RPM"),
                icon: "fan.fill",
                tint: .green
            )
            statCard(
                title: "Above 70°C today",
                value: "\(todayStats?.cpuMinutesAboveThreshold ?? 0) min",
                delta: nil,
                icon: "flame.fill",
                tint: .red
            )
        }
    }

    @ViewBuilder
    private func statCard(title: String, value: String, delta: String?, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(.title, design: .rounded))
                .fontWeight(.medium)
                .monospacedDigit()
            if let delta = delta {
                Text(delta)
                    .font(.caption2)
                    .foregroundStyle(deltaColor(delta))
            } else {
                Text(" ").font(.caption2)  // placeholder for layout stability
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 24h sparkline
    //
    // Compact hourly chart for "what did today look like?". Uses a
    // 24-hour range. CPU and GPU as separate lines.

    private var sparklineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 24 hours")
                    .font(.headline)
                Spacer()
                LegendDot(color: .orange, label: "CPU")
                LegendDot(color: .blue,   label: "GPU")
            }
            if hourly.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No hourly data yet",
                    systemImage: "chart.xyaxis.line",
                    description: "Data is rolled up to hourly buckets after a few hours of running."
                )
                .frame(height: 140)
            } else {
                Chart {
                    ForEach(hourly) { h in
                        if let v = h.cpuTempAvg {
                            LineMark(
                                x: .value("Hour", h.hour),
                                y: .value("°C", v),
                                series: .value("Series", "CPU")
                            )
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)
                        }
                        if let v = h.gpuTempAvg {
                            LineMark(
                                x: .value("Hour", h.hour),
                                y: .value("°C", v),
                                series: .value("Series", "GPU")
                            )
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                        }
                    }
                    // Subtle threshold line for visual reference.
                    RuleMark(y: .value("Warning", 75))
                        .foregroundStyle(.red.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 160)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 7-day trend
    //
    // One bar per day, height = peak CPU temperature. Quick visual
    // answer to "is the trend going up?".

    private var weeklyTrendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 7 days · daily peak CPU")
                    .font(.headline)
                Spacer()
                Text("click a bar for details")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if last7Days.isEmpty {
                ContentUnavailableViewCompat(
                    title: "Not enough data yet",
                    systemImage: "calendar",
                    description: "After a week of running, you'll see a daily trend here."
                )
                .frame(height: 140)
            } else {
                Chart {
                    ForEach(last7Days) { d in
                        if let v = d.cpuTempPeak {
                            BarMark(
                                x: .value("Day", d.date, unit: .day),
                                y: .value("°C", v)
                            )
                            .foregroundStyle(barColor(for: v))
                            .cornerRadius(3)
                        }
                    }
                    RuleMark(y: .value("Warning", 75))
                        .foregroundStyle(.red.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 160)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Data loading

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cal = Calendar.current
            let now = Date()
            let startOfToday = cal.startOfDay(for: now)
            let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
            let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: startOfToday)!

            let db = Sampler.shared.databaseHandle
            let today = (try? db.fetchSummaryStats(
                from: Int64(startOfToday.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? nil
            let yesterday = (try? db.fetchSummaryStats(
                from: Int64(startOfYesterday.timeIntervalSince1970),
                to:   Int64(startOfToday.timeIntervalSince1970))) ?? nil
            let hourly = (try? db.fetchHourlyStats(
                from: Int64(cal.date(byAdding: .day, value: -1, to: now)!.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? []
            let daily = (try? db.fetchDailyStats(
                from: Int64(sevenDaysAgo.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? []
            let cfg = (try? db.loadConfig()) ?? Config()
            let finding = (try? BaselineComparator.run(database: db, config: cfg))

            DispatchQueue.main.async {
                self.todayStats = today
                self.yesterdayStats = yesterday
                self.hourly = hourly
                self.last7Days = daily
                self.finding = finding
                self.loading = false
            }
        }
    }

    /// Lightweight re-fetch that only updates the "today" summary and
    /// the latest sample timestamp. The hourly chart and weekly bars
    /// don't need to redraw on every 1-minute sample.
    private func refreshTodayOnly() {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        DispatchQueue.global(qos: .utility).async {
            let db = Sampler.shared.databaseHandle
            let today = try? db.fetchSummaryStats(
                from: Int64(startOfToday.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))
            DispatchQueue.main.async {
                if let today = today { self.todayStats = today }
            }
        }
    }

    // MARK: - Formatting helpers

    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func deltaString(current: Double?, previous: Double?, suffix: String = "°C") -> String? {
        guard let c = current, let p = previous, p != 0 else { return nil }
        let delta = c - p
        let arrow = delta > 0.1 ? "▲" : (delta < -0.1 ? "▼" : "•")
        return "\(arrow) \(String(format: "%+.1f", delta))\(suffix) vs yesterday"
    }

    private func deltaColor(_ s: String) -> Color {
        if s.contains("▲") { return .red }
        if s.contains("▼") { return .green }
        return .secondary
    }

    private func barColor(for temp: Double) -> Color {
        // Heatmap-style: cool to hot.
        switch temp {
        case ..<45:  return .green
        case 45..<60: return .yellow
        case 60..<75: return .orange
        default:      return .red
        }
    }
}

// MARK: - Legend dot
//
// A small colored dot + label, used in chart headers.

struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
