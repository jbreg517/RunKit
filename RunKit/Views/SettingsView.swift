import SwiftUI
import UIKit
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("dailyStepGoal") private var goal = 8000
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("gpsEnabled") private var gpsEnabled = true
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage("voiceAnnouncements") private var voiceOn = true
    @AppStorage("autoPause") private var autoPauseOn = true
    @AppStorage("voiceAccent") private var voiceAccent = VoiceAccent.british.rawValue
    @AppStorage("voiceGender") private var voiceGender = VoiceGender.female.rawValue
    @AppStorage("coachStyle") private var coachStyle = CoachStyle.system.rawValue
    @AppStorage("weeklyActiveTarget") private var weeklyTarget = 3
    @AppStorage("maxHeartRate") private var maxHeartRate = 0.0
    @State private var showClear = false
    @State private var health = StoreHealth.shared

    @Query private var sessions: [ActivitySession]
    @State private var exporting = false
    @State private var exportURLs: [URL] = []
    @State private var showShare = false
    @State private var exportError: String?

    // Each section is its own property. Inlined, the Form grew past what the
    // SwiftUI type-checker will solve in reasonable time ("unable to type-check
    // this expression"), which is a hard build error rather than a warning.
    var body: some View {
        NavigationStack {
            Form {
                goalSection
                appearanceSection
                unitsSection
                trackingSection
                streakSection
                heartRateSection
                dataSection
                storageSection
                developerSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(RKColor.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .alert("Clear all data?", isPresented: $showClear) {
                Button("Delete", role: .destructive) { clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes all recorded activities. This can’t be undone.")
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: exportURLs)
            }
            .alert("Export failed", isPresented: .constant(exportError != nil)) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    // MARK: Sections

    private var goalSection: some View {
        Section("Daily Goal") {
            Stepper("Steps: \(goal)", value: $goal, in: 1000...30000, step: 500)
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        }
    }

    private var unitsSection: some View {
        Section("Units") {
            Picker("Measurement", selection: $unitRaw) {
                ForEach(UnitSystem.allCases) { u in
                    Text(u.label).tag(u.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var trackingSection: some View {
        Section {
            Toggle("Use GPS for sessions", isOn: $gpsEnabled)
                .tint(RKColor.accent)
            // Only meaningful with GPS: the pedometer can't tell "stopped at a
            // light" from "running slowly", and guessing wrong either drops real
            // minutes or inflates the average pace.
            if gpsEnabled {
                Toggle("Auto-pause", isOn: $autoPauseOn)
                    .tint(RKColor.accent)
            }
            Toggle("Voice coaching", isOn: $voiceOn)
                .tint(RKColor.accent)
            if voiceOn { voiceOptions }
        } header: {
            Text("Tracking")
        } footer: {
            Text(trackingFooter)
        }
    }

    @ViewBuilder
    private var voiceOptions: some View {
        Picker("Coach voice", selection: $coachStyle) {
            ForEach(CoachStyle.allCases) { c in Text(c.label).tag(c.rawValue) }
        }
        .pickerStyle(.segmented)
        if coachStyle == CoachStyle.system.rawValue {
            Picker("Accent", selection: $voiceAccent) {
                ForEach(VoiceAccent.allCases) { a in
                    Text("\(a.flag)  \(a.label)").tag(a.rawValue)
                }
            }
            Picker("Voice", selection: $voiceGender) {
                ForEach(VoiceGender.allCases) { g in
                    Text(g.label).tag(g.rawValue)
                }
            }
            .pickerStyle(.segmented)
            LabeledContent("Using", value: SpeechService.shared.resolvedVoiceDescription)
        }
        Button {
            SpeechService.shared.preview()
        } label: {
            Label("Preview voice", systemImage: "speaker.wave.2.fill")
                .foregroundColor(RKColor.accent)
        }
    }

    /// Built as a plain String — string interpolation this long inside a
    /// ViewBuilder is a large share of the type-checking cost.
    private var trackingFooter: String {
        let mark = unitRaw == UnitSystem.imperial.rawValue ? "mile" : "kilometer"
        return "Voice announces each \(mark), goals, and a finish recap — all on your device. \"Natural\" is a bundled human-sounding coach (it falls back to \"System\" until its voice pack ships). For \"System\", if \"Using\" shows \"compact\" — or not the accent/gender you picked — that voice isn't installed: add it free in iOS Settings ▸ Accessibility ▸ Spoken Content ▸ Voices ▸ English. GPS is used only while a session runs; routes stay on your device."
    }

    private var streakSection: some View {
        Section {
            Stepper("Active days a week: \(weeklyTarget)", value: $weeklyTarget, in: 1...7)
        } header: {
            Text("Weekly Streak")
        } footer: {
            Text("Streaks count weeks, not days, so rest days never break them.")
        }
    }

    private var heartRateSection: some View {
        Section {
            Stepper(maxHeartRate > 0 ? "Max heart rate: \(Int(maxHeartRate)) bpm" : "Max heart rate: automatic",
                    value: $maxHeartRate, in: 0...220, step: 1)
            if maxHeartRate > 0 {
                Button("Use automatic") { maxHeartRate = 0 }
                    .foregroundColor(RKColor.accent)
            }
        } header: {
            Text("Heart Rate")
        } footer: {
            Text("Sets your training zones. Automatic prefers the highest rate Apple Health has recorded for you, falling back to an age estimate — that formula is off by 10 bpm or more for many people, so set it here if you know your true max.")
        }
    }

    private var dataSection: some View {
        Section {
            Button { exportData() } label: { exportLabel }
                .disabled(exporting || sessions.isEmpty)
            Button(role: .destructive) { showClear = true } label: {
                Text("Clear All Data")
            }
        } header: {
            Text("Data")
        } footer: {
            Text(sessions.isEmpty
                 ? "Record an activity to enable export."
                 : "Exports every session as CSV plus a GPX track per recorded route — standard formats any other app can read. Generated on your device; nothing is uploaded.")
        }
    }

    @ViewBuilder
    private var exportLabel: some View {
        if exporting {
            HStack { Text("Preparing…"); Spacer(); ProgressView() }
        } else {
            Label("Export My Data", systemImage: "square.and.arrow.up")
        }
    }

    /// Where the store actually is and whether it's actually saving.
    ///
    /// Exists because the shared-store bug was invisible from inside the app: the
    /// container opened, saves succeeded, and rows disappeared afterwards when a
    /// sibling app migrated the same file. Seeing the store path and the file sizes
    /// next to each other is what identified it — so that readout stays shipped.
    private var storageSection: some View {
        Section {
            LabeledContent("Saving") {
                Text(health.isInMemory ? "No — temporary storage" : "Yes")
                    .foregroundColor(health.isInMemory ? RKColor.danger : RKColor.success)
            }
            LabeledContent("Store", value: storeName)
            if health.failedSaveCount > 0 {
                LabeledContent("Failed saves") {
                    Text("\(health.failedSaveCount)").foregroundColor(RKColor.danger)
                }
            }
            if let note = health.recoveryNote {
                Text(note).font(RKFont.caption).foregroundColor(RKColor.accent)
            }
            Button {
                UIPasteboard.general.string = health.diagnosticReport
            } label: {
                Label("Copy diagnostics", systemImage: "doc.on.doc")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text(health.isInMemory
                 ? "RunKit couldn’t open your saved history and is not saving anything. Copy the diagnostics and report this."
                 : "RunKit keeps its own database file, separate from LiftKit and FuelKit. Diagnostics list the store path and file sizes — useful if history ever goes missing.")
        }
    }

    /// Just the filename and its size; the full path goes in the diagnostics.
    private var storeName: String {
        guard let path = health.storePath else { return "—" }
        let name = (path as NSString).lastPathComponent
        let kb = health.storeBytes / 1024
        return kb > 0 ? "\(name) · \(kb) KB" : name
    }

    /// ⚠️ Development only — REMOVE before App Store submission. Kept out of
    /// `#if DEBUG` deliberately so it works in a TestFlight release build.
    private var developerSection: some View {
        Section {
            Button {
                SampleDataGenerator.generate(into: context)
            } label: {
                Label("Load 3 months of sample data", systemImage: "wand.and.stars")
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Generates a fake intermediate-runner history (about 20–30 miles a week) with routes and heart rate, so the screens can be reviewed. Remove this section before release.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: AppVersion.current)
        } header: {
            Text("About")
        } footer: {
            Text("RunKit keeps everything on your device. No accounts, no tracking, no social.")
        }
    }

    // MARK: Actions

    /// Writes CSV + GPX to the temp directory, then hands the URLs to the share
    /// sheet. Runs inline on the main actor: `ActivitySession` is a SwiftData
    /// `@Model` and isn't `Sendable`, so it can't cross to a detached task — and
    /// serialising even a few thousand sessions is only string building.
    private func exportData() {
        exporting = true
        do {
            exportURLs = try ExportService.exportAll(sessions)
            exporting = false
            showShare = true
        } catch {
            exportError = error.localizedDescription
            exporting = false
        }
    }

    private func clearAll() {
        try? context.delete(model: ActivitySession.self)
        try? context.delete(model: RoutePoint.self)
        Persist.save(context)
    }
}
