import SwiftUI

struct SchedulesView: View {
    @Environment(SchedulesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SaunaSchedule?

    var body: some View {
        NavigationStack {
            List {
                if store.schedules.isEmpty {
                    ContentUnavailableView {
                        Label("No schedules", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("Add a schedule to warm up or shut off automatically.")
                    }
                }
                ForEach(store.schedules) { s in
                    HStack(spacing: 8) {
                        // Left content edits; the toggle is a separate tap target so it
                        // doesn't trigger the editor.
                        Button { editing = s } label: { ScheduleRow(schedule: s) }
                            .buttonStyle(.plain)
                        Toggle("", isOn: Binding(get: { s.enabled },
                                                 set: { _ in store.toggle(s) }))
                            .labelsHidden()
                            .tint(Theme.ember)
                    }
                }
                .onDelete { idx in idx.map { store.schedules[$0] }.forEach(store.delete) }
            }
            .navigationTitle("Schedules")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("Schedules fire on saunad once it's set up. They're saved on this device for now.")
                    .font(.footnote).foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = SaunaSchedule() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { s in ScheduleEditorView(schedule: s) }
        }
    }
}

private struct ScheduleRow: View {
    let schedule: SaunaSchedule
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: schedule.turnOn ? "flame.fill" : "power")
                .foregroundStyle(schedule.turnOn ? Theme.ember : Theme.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(schedule.timeString)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(schedule.enabled ? Theme.textPrimary : Theme.textTertiary)
                    if schedule.readyBy && schedule.turnOn {
                        Text("READY BY")
                            .font(.system(.caption2, design: .rounded, weight: .bold)).tracking(0.5)
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.amber.opacity(0.15)))
                    }
                }
                Text("\(schedule.repeatSummary)  ·  \(schedule.actionSummary)")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                if schedule.readyBy && schedule.turnOn {
                    Text("heat starts ~\(schedule.startTimeString)")
                        .font(.caption2).foregroundStyle(Theme.amber)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .opacity(schedule.enabled ? 1 : 0.6)
    }
}

// MARK: - Editor

struct ScheduleEditorView: View {
    @Environment(SchedulesStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(HeatingModel.self) private var heating
    @Environment(SaunaStore.self) private var sauna
    @Environment(\.dismiss) private var dismiss

    @State var schedule: SaunaSchedule
    @State private var mode: Mode

    enum Mode: String, CaseIterable { case weekly = "Weekly", once = "Once" }

    private var isNew: Bool { !store.schedules.contains { $0.id == schedule.id } }

    init(schedule: SaunaSchedule) {
        _schedule = State(initialValue: schedule)
        _mode = State(initialValue: schedule.isOneTime ? .once : .weekly)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(schedule.readyBy ? "Ready by" : "Start at",
                               selection: timeBinding, displayedComponents: .hourAndMinute)
                    if schedule.turnOn {
                        Picker("This time is", selection: readyByBinding) {
                            Text("Start heating").tag(false)
                            Text("Target reached").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if schedule.readyBy {
                            Toggle("Auto preheat (learn timing)", isOn: autoBinding)
                            if !schedule.autoPreheat {
                                Stepper("Preheat lead \(schedule.preheatLeadMin) min",
                                        value: $schedule.preheatLeadMin, in: 5...180, step: 5)
                            }
                        }
                    }
                } header: { Text("Time") } footer: {
                    if schedule.readyBy && schedule.turnOn {
                        VStack(alignment: .leading, spacing: 3) {
                            if schedule.autoPreheat {
                                Text("Auto ≈ \(schedule.preheatLeadMin) min lead \(learnedNote). Heating starts about \(schedule.startTimeString).")
                            } else {
                                Text("Heating starts about \(schedule.startTimeString) so it reaches \(schedule.targetTempF ?? 150)°F by \(schedule.timeString).")
                            }
                            if let liveHint {
                                Text(liveHint).foregroundStyle(Theme.amber)
                            }
                        }
                    }
                }

                Section("Repeat") {
                    Picker("Repeat", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if mode == .weekly {
                        WeekdayPicker(weekdays: $schedule.weekdays)
                    } else {
                        DatePicker("Date", selection: onceBinding, in: Date()..., displayedComponents: .date)
                    }
                }

                Section("Action") {
                    Picker("When it fires", selection: $schedule.turnOn) {
                        Text("Turn on").tag(true)
                        Text("Turn off").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if schedule.turnOn {
                        if !schedule.readyBy {
                            Toggle("Set temperature", isOn: setBinding(\.targetTempF, default: 150))
                        }
                        if schedule.targetTempF != nil {
                            Stepper("Target \(schedule.targetTempF ?? 150)°F",
                                    value: intBinding(\.targetTempF, default: 150), in: 86...170)
                        }
                        Picker("Light", selection: colorBinding) {
                            Text("Leave as is").tag(Optional<String>.none)
                            ForEach(ChromaPalette.solids, id: \.value) { c in
                                Text(c.name).tag(Optional(c.value))
                            }
                            Text("Cycle").tag(Optional(ChromaPalette.scroll))
                        }
                        Picker("Timer", selection: timerBinding) {
                            Text("None").tag(Optional<Int>.none)
                            ForEach(settings.timerPresets, id: \.self) { m in
                                Text("\(m) min").tag(Optional(m))
                            }
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete schedule", role: .destructive) {
                            store.delete(schedule); dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(mode == .weekly && schedule.weekdays.isEmpty)
                }
            }
            .onAppear { refreshAutoLead() }
            .onChange(of: schedule.targetTempF) { _, _ in refreshAutoLead() }
            .onChange(of: schedule.readyBy) { _, _ in refreshAutoLead() }
            .onChange(of: mode) { _, m in
                if m == .once {
                    schedule.weekdays = []
                    if schedule.onceDate == nil { schedule.onceDate = Date().addingTimeInterval(86400) }
                } else {
                    schedule.onceDate = nil
                    if schedule.weekdays.isEmpty { schedule.weekdays = [2, 3, 4, 5, 6] }
                }
            }
        }
    }

    private func save() { store.upsert(schedule); dismiss() }

    /// Keep the stored lead in sync with the learned estimate while auto is on.
    private func refreshAutoLead() {
        guard schedule.readyBy, schedule.autoPreheat else { return }
        schedule.preheatLeadMin = heating.estimatedLead(toTarget: schedule.targetTempF ?? 150)
    }

    private var autoBinding: Binding<Bool> {
        Binding(get: { schedule.autoPreheat },
                set: { v in schedule.autoPreheat = v; if v { refreshAutoLead() } })
    }

    private var learnedNote: String {
        heating.sampleCount > 0
            ? "(learned from \(heating.sampleCount) session\(heating.sampleCount == 1 ? "" : "s"))"
            : "(default until it learns)"
    }

    /// When connected, what the lead would be using the *actual* temp right now —
    /// the same recompute saunad will do at fire time, previewed live.
    private var liveHint: String? {
        guard schedule.readyBy, schedule.turnOn, schedule.autoPreheat,
              sauna.reachable, let cur = sauna.state.currentTempF else { return nil }
        let lead = heating.leadMinutes(from: cur, to: schedule.targetTempF ?? 150)
        return "Right now (\(cur)°F) that'd be about \(lead) min."
    }

    // MARK: bindings

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents(); c.hour = schedule.hour; c.minute = schedule.minute
                return Calendar.current.date(from: c) ?? .now
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                schedule.hour = c.hour ?? 0; schedule.minute = c.minute ?? 0
            })
    }

    private var onceBinding: Binding<Date> {
        Binding(get: { schedule.onceDate ?? Date().addingTimeInterval(86400) },
                set: { schedule.onceDate = $0 })
    }

    /// Switching to "Target reached" needs a target to aim for.
    private var readyByBinding: Binding<Bool> {
        Binding(get: { schedule.readyBy },
                set: { v in
                    schedule.readyBy = v
                    if v && schedule.targetTempF == nil { schedule.targetTempF = 150 }
                })
    }

    private var colorBinding: Binding<String?> {
        Binding(get: { schedule.chromoColor }, set: { schedule.chromoColor = $0 })
    }

    private var timerBinding: Binding<Int?> {
        Binding(get: { schedule.timerMin }, set: { schedule.timerMin = $0 })
    }

    /// Toggle for an optional Int field: on = some(default), off = nil.
    private func setBinding(_ kp: WritableKeyPath<SaunaSchedule, Int?>, default def: Int) -> Binding<Bool> {
        Binding(get: { schedule[keyPath: kp] != nil },
                set: { schedule[keyPath: kp] = $0 ? (schedule[keyPath: kp] ?? def) : nil })
    }

    /// Non-optional view over an optional Int field (used while it's enabled).
    private func intBinding(_ kp: WritableKeyPath<SaunaSchedule, Int?>, default def: Int) -> Binding<Int> {
        Binding(get: { schedule[keyPath: kp] ?? def },
                set: { schedule[keyPath: kp] = $0 })
    }
}

private struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>
    // 1=Sun ... 7=Sat; display Mon-first for a week-at-a-glance feel.
    private let order = [2, 3, 4, 5, 6, 7, 1]
    private var letters: [String] { Calendar.current.veryShortWeekdaySymbols } // ["S","M",...]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { d in
                let on = weekdays.contains(d)
                Button {
                    if on { weekdays.remove(d) } else { weekdays.insert(d) }
                } label: {
                    Text(letters[d - 1])
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .foregroundStyle(on ? Theme.bg0 : Theme.textPrimary)
                        .background(Circle().fill(on ? AnyShapeStyle(Theme.ember) : AnyShapeStyle(Color.white.opacity(0.08))))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
