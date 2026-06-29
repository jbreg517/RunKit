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
    @State private var showClear = false

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
                    Text("GPS maps your route and measures distance for runs and rides — only while a session is running, and routes stay on your device. Voice announces each \(unitRaw == UnitSystem.imperial.rawValue ? "mile" : "kilometer"), goals, and a finish recap. For richer voices, download an enhanced voice in iOS Settings ▸ Accessibility ▸ Spoken Content ▸ Voices.")
                }

                Section("Data") {
                    Button(role: .destructive) { showClear = true } label: {
                        Text("Clear All Data")
                    }
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
        }
    }

    private func clearAll() {
        try? context.delete(model: ActivitySession.self)
        try? context.delete(model: RoutePoint.self)
        try? context.save()
    }
}
