import SwiftUI

// MARK: - ConfigView
//
// Tab that lets the user tweak thresholds, sample interval, and
// notification settings. Also where the user toggles demo mode and
// generates synthetic historical data so they can see the UI
// without waiting for the SMC struct to be reverse-engineered.

struct ConfigView: View {
    @State private var cfg: Config = Sampler.shared.config
    @State private var savedAt: Date?

    @State private var demoCfg: SyntheticConfig = SyntheticConfig.load()
    @State private var generating: Bool = false
    @State private var genProgress: Double = 0
    @State private var genMessage: String = ""
    @State private var clearingData: Bool = false

    @State private var realCount: Int = 0
    @State private var syntheticCount: Int = 0
    @State private var refreshTick: Int = 0

    var body: some View {
        Form {
            Section("Sampling") {
                Stepper(value: $cfg.sampleIntervalSec, in: 10...600, step: 10) {
                    LabeledContent("Interval") {
                        Text("\(cfg.sampleIntervalSec) sec")
                            .monospacedDigit()
                    }
                }
            }

            Section("Thermal alert") {
                HStack {
                    Text("Temperature rise threshold")
                    Spacer()
                    TextField("°C", value: $cfg.tempThresholdC, format: .number.precision(.fractionLength(1)))
                        .frame(width: 60).multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                }
                Stepper(value: $cfg.fanThresholdRPM, in: 0...3000, step: 100) {
                    LabeledContent("Fan RPM rise") {
                        Text("\(cfg.fanThresholdRPM) RPM")
                            .monospacedDigit()
                    }
                }
            }

            Section("Comparison windows") {
                Stepper(value: $cfg.baselineDays, in: 7...180, step: 7) {
                    LabeledContent("Baseline") {
                        Text("\(cfg.baselineDays) days")
                            .monospacedDigit()
                    }
                }
                Stepper(value: $cfg.compareDays, in: 1...30, step: 1) {
                    LabeledContent("Recent") {
                        Text("\(cfg.compareDays) days")
                            .monospacedDigit()
                    }
                }
            }

            Section("Notifications") {
                Toggle("Enable system notifications", isOn: $cfg.notificationsEnabled)
            }

            demoSection

            dataSection

            Section {
                HStack {
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    if let savedAt = savedAt {
                        Text("Saved \(savedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("DB: \(Sampler.shared.databasePath)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .onAppear { refreshCounts() }
    }

    // MARK: - Demo data section
    //
    // Lets the user flip the app into "demo mode" so the charts and
    // alert logic work even when SMC reads are broken. Two pieces:
    //   1. Toggle: switches the live sampler to synthetic data.
    //   2. Generate: bulk-inserts N days of historical data so the
    //      heatmap and weekly trend have something to show.
    //
    // The button shows a progress bar because generating 30+ days
    // takes a few seconds (43,200 rows).

    private var demoSection: some View {
        Section {
            Toggle(isOn: $demoCfg.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.orange)
                        Text("Use synthetic data (demo mode)")
                            .fontWeight(.medium)
                    }
                    Text("Replaces SMC reads with a realistic generator. Useful when SMC isn't working on this macOS version, or to explore the app quickly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: demoCfg.enabled) { newValue in
                demoCfg.save()
                Sampler.shared.isDemoMode = newValue
            }

            if demoCfg.enabled {
                Stepper(value: $demoCfg.daysOfData, in: 1...180, step: 7) {
                    LabeledContent("Days of history to generate") {
                        Text("\(demoCfg.daysOfData) days")
                            .monospacedDigit()
                    }
                }
                .onChange(of: demoCfg.daysOfData) { _ in demoCfg.save() }

                HStack {
                    Stepper("Random seed", value: $demoCfg.seed, in: 0...9999)
                        .onChange(of: demoCfg.seed) { _ in demoCfg.save() }
                }

                HStack(spacing: 12) {
                    Button {
                        generateDemoData()
                    } label: {
                        if generating {
                            HStack { ProgressView().controlSize(.small); Text("Generating…") }
                        } else {
                            Label("Generate \(demoCfg.daysOfData)-day history", systemImage: "calendar.badge.plus")
                        }
                    }
                    .disabled(generating || clearingData)
                }

                if generating || !genMessage.isEmpty {
                    if generating {
                        ProgressView(value: genProgress) {
                            Text("Inserting synthetic samples…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(genMessage)
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
        } header: {
            Text("Demo data")
        } footer: {
            Text("Demo data is real, but synthesized. Once SMC reads work, toggle this off and the app will use actual sensor data.")
                .font(.caption2)
        }
    }

    // MARK: - Data section
    //
    // Lets the user see how much real vs synthetic data is in the
    // database, and clear each independently. Useful for keeping
    // curated synthetic data while accumulating real measurements,
    // or wiping the previous day/week of test data on demand.

    private var dataSection: some View {
        Section {
            // Live counts from the DB
            HStack(spacing: 24) {
                dataCount(label: "Real",      n: realCount,      tint: .green)
                dataCount(label: "Synthetic", n: syntheticCount, tint: .orange)
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Button {
                    clearSynthetic()
                } label: {
                    Label("Clear synthetic only", systemImage: "wand.and.stars.outline")
                }
                .disabled(syntheticCount == 0 || clearingData)

                Button {
                    clearBeforeToday()
                } label: {
                    Label("Clear data before today", systemImage: "calendar.badge.minus")
                }
                .disabled(clearingData)
            }

            Button(role: .destructive) {
                clearEverything()
            } label: {
                Label("Clear all data", systemImage: "trash")
            }
            .disabled(clearingData)
        } header: {
            Text("Data")
        } footer: {
            Text("Use \"Clear synthetic only\" to remove demo data while keeping real SMC samples. \"Clear data before today\" wipes test data from previous days. \"Clear all data\" removes everything.")
                .font(.caption2)
        }
    }

    private func dataCount(label: String, n: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(n) samples")
                .font(.system(.title3, design: .rounded)).fontWeight(.medium)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearSynthetic() {
        clearingData = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Sampler.shared.databaseHandle.clearSyntheticData()
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = "✓ Cleared synthetic data"
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = "✗ Clear failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func clearBeforeToday() {
        clearingData = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Sampler.shared.databaseHandle.clearBeforeToday()
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = "✓ Cleared data before today 00:00"
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = "✗ Clear failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func clearEverything() {
        clearingData = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Sampler.shared.databaseHandle.clearAllSamples()
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = "✓ All data cleared"
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = "✗ Clear failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func refreshCounts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let counts = (try? Sampler.shared.databaseHandle.sourceCounts())
                ?? (real: 0, synthetic: 0)
            DispatchQueue.main.async {
                self.realCount = counts.real
                self.syntheticCount = counts.synthetic
            }
        }
    }

    // MARK: - Save

    private func save() {
        do {
            try Sampler.shared.databaseHandle.saveConfig(cfg)
            Sampler.shared.config = cfg
            savedAt = Date()
        } catch {
            NSLog("ConfigView save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Demo actions

    private func generateDemoData() {
        generating = true
        genProgress = 0
        genMessage = ""
        let cfg = self.demoCfg
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SyntheticDataGenerator.generate(
                    database: Sampler.shared.databaseHandle,
                    days: cfg.daysOfData,
                    seed: cfg.seed,
                    progress: { p in
                        DispatchQueue.main.async { self.genProgress = p }
                    })
                DispatchQueue.main.async {
                    self.generating = false
                    let totalSamples = cfg.daysOfData * 24 * 60
                    self.genMessage = "✓ Generated \(totalSamples) synthetic samples"
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.generating = false
                    self.genMessage = "✗ Generation failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
