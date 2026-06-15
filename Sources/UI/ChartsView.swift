import SwiftUI
import Charts

// MARK: - ChartsView
//
// A detail view for exploring a specific time range in depth. Three
// modes:
//
//   .live     — last 24h, raw samples
//   .compare  — baseline vs recent (Mann-Whitney finding)
//   .history  — full date range the user has data for, with date
//               range picker, aggregation toggle, and export button
//
// This is the "I want to dig into the data" view. The Overview tab
// gives the at-a-glance summary; this one is for forensics.

struct ChartsView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live"
        case compare = "Compare"
        case history = "History"
        var id: String { rawValue }
    }

    enum Aggregation: String, CaseIterable, Identifiable {
        case raw    = "Raw"
        case hourly = "Hourly"
        case daily  = "Daily"
        var id: String { rawValue }
    }

    enum Range: String, CaseIterable, Identifiable {
        case last24h = "24h"
        case last7d  = "7d"
        case last30d = "30d"
        case last90d = "90d"
        case all     = "All"
        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .last24h: return 24 * 3600
            case .last7d:  return 7 * 86400
            case .last30d: return 30 * 86400
            case .last90d: return 90 * 86400
            case .all:     return 365 * 5 * 86400  // ~5 years
            }
        }
    }

    let mode: Mode

    @State private var samples: [Sample] = []
    @State private var hourly: [HourlyStats] = []
    @State private var daily:  [DailyStats]  = []
    @State private var finding: ThermalFinding?
    @State private var loading: Bool = false

    // History-mode controls
    @State private var range: Range = .last7d
    @State private var aggregation: Aggregation = .raw
    @State private var exportError: String?
    @State private var exportedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controlsCard
            chartCard
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: range)        { _ in load() }
        .onChange(of: aggregation)  { _ in load() }
        .alert("Export failed",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2).fontWeight(.semibold)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch mode {
        case .live:    return "Live (last 24 hours)"
        case .compare: return "Baseline vs recent"
        case .history: return "History"
        }
    }
    private var subtitle: String {
        switch mode {
        case .live:
            return "Raw 1-minute samples from the last 24 hours."
        case .compare:
            return "Median CPU temperature at the most-degraded P-State, recent vs baseline."
        case .history:
            return "Explore the full range of recorded data. Pick a time range, an aggregation level, and click a point for details."
        }
    }

    // MARK: - Controls
    //
    // Only shown in history mode. Live/compare have no controls.

    @ViewBuilder
    private var controlsCard: some View {
        if mode == .history {
            HStack(spacing: 14) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Picker("Aggregation", selection: $aggregation) {
                    ForEach(Aggregation.allCases) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .help("Export the current view as a CSV file")
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        } else {
            EmptyView()
        }
    }

    // MARK: - Chart card
    //
    // The actual chart area. Switches between raw line chart, hourly
    // bars, and daily bars based on the mode and aggregation choice.

    @ViewBuilder
    private var chartCard: some View {
        Group {
            if loading && samples.isEmpty && hourly.isEmpty && daily.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty {
                ContentUnavailableViewCompat(
                    title: "No data in this range",
                    systemImage: "tray",
                    description: "Pick a wider time range, or wait for the sampler to collect more."
                )
            } else {
                switch mode {
                case .live:    liveChart
                case .compare: compareChart
                case .history: historyChart
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var isEmpty: Bool {
        switch (mode, aggregation) {
        case (.live, _):             return samples.isEmpty
        case (.compare, _):          return finding == nil
        case (.history, .raw):       return samples.isEmpty
        case (.history, .hourly):    return hourly.isEmpty
        case (.history, .daily):     return daily.isEmpty
        }
    }

    // MARK: - Live chart (24h raw samples)

    private var liveChart: some View {
        let cpuSeries: [ChartPoint] = samples.compactMap { s in
            guard let v = s.cpuTempC else { return nil }
            return ChartPoint(time: s.timestamp, value: v, series: "CPU")
        }
        let gpuSeries: [ChartPoint] = samples.compactMap { s in
            guard let v = s.gpuTempC else { return nil }
            return ChartPoint(time: s.timestamp, value: v, series: "GPU")
        }
        return Chart {
            ForEach(cpuSeries) { p in
                LineMark(x: .value("Time", p.time), y: .value("°C", p.value), series: .value("Series", p.series))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
            ForEach(gpuSeries) { p in
                LineMark(x: .value("Time", p.time), y: .value("°C", p.value), series: .value("Series", p.series))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Warning", 75))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("75°C").font(.caption2).foregroundStyle(.red)
                }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartLegend(position: .top, alignment: .leading)
        .padding(12)
    }

    // MARK: - Compare chart
    //
    // Bar chart of baseline vs recent median at the worst P-State.

    private var compareChart: some View {
        let f = finding
        return Chart {
            BarMark(
                x: .value("Window", "Baseline"),
                y: .value("Median °C", f?.baselineMedian ?? 0)
            )
            .foregroundStyle(.green)
            .annotation(position: .top) {
                Text(String(format: "%.1f°C", f?.baselineMedian ?? 0))
                    .font(.caption2)
            }
            BarMark(
                x: .value("Window", "Recent"),
                y: .value("Median °C", f?.recentMedian ?? 0)
            )
            .foregroundStyle((f?.tempDelta ?? 0) > 0 ? .red : .blue)
            .annotation(position: .top) {
                Text(String(format: "%.1f°C", f?.recentMedian ?? 0))
                    .font(.caption2)
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .padding(12)
        .overlay(alignment: .bottom) {
            if let f = f {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Δ = %+.1f°C · p = %.3f · n=%d vs %d",
                                f.tempDelta, f.pValue, f.recentCount, f.baselineCount))
                        .font(.caption).foregroundStyle(.secondary)
                    if f.fanDelta > 0 {
                        Text(String(format: "Fan RPM: %.0f → %.0f (+%.0f)",
                                    f.fanBaselineMean, f.fanRecentMean, f.fanDelta))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            } else {
                Text("No significant degradation detected in the current window.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    // MARK: - History chart
    //
    // Switches between raw line, hourly line, and daily bar chart
    // based on the user's aggregation choice.

    @ViewBuilder
    private var historyChart: some View {
        switch aggregation {
        case .raw:    historyRawChart
        case .hourly: historyHourlyChart
        case .daily:  historyDailyChart
        }
    }

    private var historyRawChart: some View {
        let cpuSeries: [ChartPoint] = samples.compactMap { s in
            guard let v = s.cpuTempC else { return nil }
            return ChartPoint(time: s.timestamp, value: v, series: "CPU")
        }
        let gpuSeries: [ChartPoint] = samples.compactMap { s in
            guard let v = s.gpuTempC else { return nil }
            return ChartPoint(time: s.timestamp, value: v, series: "GPU")
        }
        return Chart {
            ForEach(cpuSeries) { p in
                LineMark(x: .value("Time", p.time), y: .value("°C", p.value), series: .value("Series", p.series))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
            ForEach(gpuSeries) { p in
                LineMark(x: .value("Time", p.time), y: .value("°C", p.value), series: .value("Series", p.series))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Warning", 75))
                .foregroundStyle(.red.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartLegend(position: .top, alignment: .leading)
        .padding(12)
    }

    private var historyHourlyChart: some View {
        Chart {
            ForEach(hourly) { h in
                if let v = h.cpuTempAvg {
                    LineMark(x: .value("Hour", h.hour), y: .value("°C", v), series: .value("Series", "CPU avg"))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                }
                if let v = h.gpuTempAvg {
                    LineMark(x: .value("Hour", h.hour), y: .value("°C", v), series: .value("Series", "GPU avg"))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                }
            }
            RuleMark(y: .value("Warning", 75))
                .foregroundStyle(.red.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartLegend(position: .top, alignment: .leading)
        .padding(12)
    }

    private var historyDailyChart: some View {
        Chart {
            ForEach(daily) { d in
                if let v = d.cpuTempPeak {
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("°C", v))
                        .foregroundStyle(HeatPalette.color(forPeak: v))
                        .cornerRadius(2)
                }
            }
            RuleMark(y: .value("Warning", 75))
                .foregroundStyle(.red.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .padding(12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(sampleCount) data points")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let url = exportedURL {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .font(.caption)
            }
        }
    }

    private var sampleCount: Int {
        switch aggregation {
        case .raw:    return samples.count
        case .hourly: return hourly.count
        case .daily:  return daily.count
        }
    }

    // MARK: - Data loading

    private func load() {
        loading = true
        let from: Date
        let to = Date()
        switch mode {
        case .live, .compare:
            from = Calendar.current.date(byAdding: .hour, value: -24, to: to)!
        case .history:
            from = Date(timeIntervalSinceNow: -range.seconds)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let db = Sampler.shared.databaseHandle
            let samples = (try? db.fetchSamples(
                from: Int64(from.timeIntervalSince1970),
                to:   Int64(to.timeIntervalSince1970))) ?? []
            let hourly = (try? db.fetchHourlyStats(
                from: Int64(from.timeIntervalSince1970),
                to:   Int64(to.timeIntervalSince1970))) ?? []
            let daily = (try? db.fetchDailyStats(
                from: Int64(from.timeIntervalSince1970),
                to:   Int64(to.timeIntervalSince1970))) ?? []
            let cfg = (try? db.loadConfig()) ?? Config()
            let finding = (try? BaselineComparator.run(database: db, config: cfg))

            DispatchQueue.main.async {
                self.samples = samples
                self.hourly = hourly
                self.daily = daily
                self.finding = finding
                self.loading = false
            }
        }
    }

    // MARK: - Export

    private func exportCSV() {
        let from: Date
        let to = Date()
        switch mode {
        case .live, .compare:
            from = Calendar.current.date(byAdding: .hour, value: -24, to: to)!
        case .history:
            from = Date(timeIntervalSinceNow: -range.seconds)
        }
        do {
            let url = try CSVExporter.exportSamples(from: from, to: to)
            exportedURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - ChartPoint
//
// Identifiable point for SwiftUI Charts ForEach.

struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
    let series: String
}

// MARK: - ContentUnavailableViewCompat
//
// `ContentUnavailableView` is iOS 17+ / macOS 14+. For macOS 13 we
// substitute a custom layout.

struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
