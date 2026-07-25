import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("dailyStepGoal") private var goal = 8000
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("gpsEnabled") private var gpsEnabled = true
    @AppStorage("unitSystem") private var unitRaw = UnitSystem.metric.rawValue
    @AppStorage("voiceAnnouncements") private var voiceOn = true
    @AppStorage("voiceAccent") private var voiceAccent = VoiceAccent.british.rawValue
    @AppStorage("voiceGender") private var voiceGender = VoiceGender.female.rawValue
    @AppStorage("coachStyle") private var coachStyle = CoachStyle.system.rawValue
    @AppStorage("weeklyActiveTarget") private var weeklyTarget = 3
    @State private var showClear = false

    @Query private var sessions: [ActivitySession]
    @State private var exporting = false
    @State private var exportURLs: [URL] = []
    @State private var showShare = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Daily Goal") {
                    Stepper("Steps: \(goal)", value: $goal, in: 1000...30000, step: 500)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Units") {
                    Picker("Measurement", selection: $unitRaw) {
                        ForEach(UnitSystem.allCases) { u in
                            Text(u.label).tag(u.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Use GPS for sessions", isOn: $gpsEnabled)
                        .tint(RKColor.accent)
                    Toggle("Voice coaching", isOn: $voiceOn)
                        .tint(RKColor.accent)
                    if voiceOn {
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
                } header: {
                    Text("Tracking")
                } footer: {
                    Text("Voice announces each \(unitRaw == UnitSystem.imperial.rawValue ? "mile" : "kilometer"), goals, and a finish recap — all on your device. \"Natural\" is a bundled human-sounding coach (it falls back to \"System\" until its voice pack ships). For \"System\", if \"Using\" shows \"compact\" — or not the accent/gender you picked — that voice isn't installed: add it free in iOS Settings ▸ Accessibility ▸ Spoken Content ▸ Voices ▸ English. GPS is used only while a session runs; routes stay on your device.")
                }

                Section("Weekly Streak") {
                    Stepper("Active days a week: \(weeklyTarget)",
                            value: $weeklyTarget, in: 1...7)
                } footer: {
                    Text("Streaks count weeks, not days, so rest days never break them.")
                }

                Section {
                    Button {
                        exportData()
                    } label: {
                        if exporting {
                            HStack { Text("Preparing…"); Spacer(); ProgressView() }
                        } else {
                            Label("Export My Data", systemImage: "square.and.arrow.up")
                        }
                    }
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

                Section {
                    LabeledContent("Version", value: AppVersion.current)
                } header: {
                    Text("About")
                } footer: {
                    Text("RunKit keeps everything on your device. No accounts, no tracking, no social.")
                }
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
        try? context.save()
    }
}
