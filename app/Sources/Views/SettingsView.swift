import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SaunaStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Address") {
                        TextField("http://your-pi-ip:8765", text: $settings.baseURL)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().keyboardType(.URL)
                    }
                    LabeledContent("API key") {
                        SecureField("required for control", text: $settings.apiKey)
                            .multilineTextAlignment(.trailing)
                    }
                    Button { test() } label: {
                        HStack { Text("Test connection"); Spacer()
                            if testing { ProgressView() } }
                    }
                    if let r = testResult {
                        Text(r).font(.footnote).foregroundStyle(r.hasPrefix("✓") ? .green : Theme.emberHot)
                    }
                } header: { Text("saunad bridge") } footer: {
                    Text("Reads (temperature) are open; controlling the sauna needs the API key. Reach it away from home via Tailscale.")
                }

                Section("Now") {
                    LabeledContent("Connection", value: store.reachable ? "Connected" : "Offline")
                    if let t = store.state.currentTempF { LabeledContent("Current", value: "\(t)°F") }
                    LabeledContent("Power", value: store.state.power ? "On" : "Off")
                    LabeledContent("Heater", value: store.state.heater ? "On" : "Off")
                }

                Section {
                    Stepper("Target \(settings.defaultTargetF)°F", value: $settings.defaultTargetF, in: 86...170)
                    Picker("Timer", selection: $settings.defaultTimerMin) {
                        Text("None").tag(0)
                        ForEach(settings.timerPresets, id: \.self) { m in Text("\(m) min").tag(m) }
                    }
                    Picker("Light", selection: $settings.defaultLightColor) {
                        ForEach(ChromaPalette.solids, id: \.value) { c in Text(c.name).tag(c.value) }
                    }
                } header: { Text("Default when starting") } footer: {
                    Text("Target is applied when you Start Heating; timer and light also on Get In.")
                }

                Section {
                    NavigationLink {
                        TimerDurationsView()
                    } label: { Label("Timer durations", systemImage: "timer") }
                }

                Section {
                    NavigationLink {
                        LogView().navigationTitle("Log")
                    } label: { Label("Session log", systemImage: "list.bullet.rectangle.portrait") }
                    #if DEBUG
                    NavigationLink {
                        DebugView().navigationTitle("Debug").navigationBarTitleDisplayMode(.inline)
                    } label: { Label("Debug", systemImage: "ladybug.fill") }
                    #endif
                }

                Section { LabeledContent("Sauna Controller", value: "1.0") }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func test() {
        testing = true; testResult = nil
        Task {
            await store.refresh()
            testing = false
            testResult = store.reachable ? "✓ Connected" : "✗ \(store.lastError ?? "unreachable")"
        }
    }
}

/// Edit the quick-pick minute durations shown in the Timer dropdown.
struct TimerDurationsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newValue = 30

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                ForEach(settings.timerPresets, id: \.self) { m in
                    HStack {
                        Text("\(m) min")
                        Spacer()
                        Button(role: .destructive) {
                            settings.timerPresets.removeAll { $0 == m }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Theme.emberHot)
                                .imageScale(.large)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(m) minutes")
                    }
                }
                .onDelete { settings.timerPresets.remove(atOffsets: $0) }
                if settings.timerPresets.isEmpty {
                    Text("No durations — add one below.")
                        .foregroundStyle(Theme.textTertiary)
                }
            } header: { Text("Durations") } footer: {
                Text("Tap the minus to remove (or swipe). Kept in ascending order. Quick picks in the Timer dropdown — the FD-5 caps a running timer at 90 minutes.")
            }

            Section("Add a duration") {
                Stepper("\(newValue) min", value: $newValue, in: 1...90, step: 5)
                Button("Add") {
                    guard !settings.timerPresets.contains(newValue) else { return }
                    settings.timerPresets = (settings.timerPresets + [newValue]).sorted()
                }
            }

            Section {
                Button("Reset to defaults") { settings.timerPresets = AppSettings.defaultPresets }
            }
        }
        .onAppear { settings.timerPresets = settings.timerPresets.sorted() }
        .navigationTitle("Timer durations")
        .navigationBarTitleDisplayMode(.inline)
    }
}
