import SwiftUI

struct ControlView: View {
    @Environment(SaunaStore.self) private var store
    private var s: SaunaState { store.state }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ConnectionBar()
                HeroGauge(state: s)
                StartStopButton()
                SessionButton()
                ControlFeedback()
                TargetCard(state: s)
                HStack(alignment: .top, spacing: 12) {
                    TimerCard(state: s)
                    LightsCard(state: s)
                }
                StatusCard(state: s)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .animation(.snappy(duration: 0.35), value: VisualKey(s))
    }
}

/// The fields whose *changes* should animate. Deliberately excludes `updatedAt`
/// (bumped by every poll — animating on the whole state re-ran a 0.35s transaction
/// across the screen every 2s) and `timerRemainingMin` (the countdown self-ticks).
private struct VisualKey: Equatable {
    let power: Bool, heater: Bool
    let currentTempF: Int?, targetTempF: Int?, timerSetMin: Int?
    let chromoColor: String?
    init(_ s: SaunaState) {
        power = s.power; heater = s.heater
        currentTempF = s.currentTempF; targetTempF = s.targetTempF
        timerSetMin = s.timerSetMin; chromoColor = s.chromoColor
    }
}

// MARK: - Connection / status

private struct ConnectionBar: View {
    @Environment(SaunaStore.self) private var store
    var body: some View {
        HStack(spacing: 8) {
            statusPill
            // live countdown next to the status label; hidden when no timer is running
            if let deadline = store.timerDeadline, deadline > .now {
                HStack(spacing: 4) {
                    Image(systemName: "hourglass").font(.caption2)
                    Text(timerInterval: Date.now...deadline, countsDown: true).monospacedDigit()
                }
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.amber)
            }
            Spacer()
            if !store.reachable {
                Pill(text: "Offline", color: Theme.emberHot)
            } else if store.stale {
                Pill(text: "Stale", color: .yellow)
            }
        }
        .padding(.top, 4)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch store.state.status {
            case .off: return ("Off", Theme.textSecondary)
            case .preheating: return ("Preheating", Theme.amber)
            case .ready: return ("Ready", Theme.ember)
            case .heating: return ("Heating", Theme.ember)
            case .idleWarm: return ("On", Theme.amber)
            }
        }()
        return Pill(text: text, color: color, filled: store.state.status == .ready)
    }
}

// MARK: - Hero gauge

private struct HeroGauge: View {
    let state: SaunaState
    private let sweep = 0.75            // 270°
    private let floorF = 75.0, ceilF = 170.0   // FD-5 max setpoint

    private func frac(_ f: Int?) -> Double {
        guard let f else { return 0 }
        return max(0, min(1, (Double(f) - floorF) / (ceilF - floorF)))
    }

    var body: some View {
        let curFrac = frac(state.currentTempF)
        let heat = Theme.heatColor(state.heatRatio)
        ZStack {
            // track
            Circle().trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.07), style: .init(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
            // fill — hue tracks actual heat (cool when cold → ember when hot)
            Circle().trim(from: 0, to: sweep * curFrac)
                .stroke(LinearGradient(colors: [heat.mix(Theme.amber, 0.35), heat],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: .init(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
                .emberGlow(heat, radius: 24, active: curFrac > 0.05)
            // target marker
            TargetTick(progress: sweep * frac(state.targetTempF))
                .rotationEffect(.degrees(135))

            VStack(spacing: 2) {
                Image(systemName: state.heater ? "flame.fill" : "thermometer.medium")
                    .font(.title2)
                    .foregroundStyle(state.heater ? AnyShapeStyle(Theme.emberGradient) : AnyShapeStyle(Theme.textTertiary))
                    .emberGlow(Theme.ember, radius: 10, active: state.heater)
                Text(state.currentTempF.map { "\($0)" } ?? "—")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText(value: Double(state.currentTempF ?? 0)))
                    .monospacedDigit()
                Text("°F").font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.textSecondary).offset(y: -8)
                Text("target \(state.targetTempF ?? 0)°")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(height: 176)
        .padding(.horizontal, 8)
    }
}

private struct TargetTick: Shape {
    let progress: Double  // 0…0.75 around the circle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) / 2 - 9
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angle = Angle.degrees(progress * 360).radians
        let a = CGPoint(x: center.x + cos(angle) * (r - 12), y: center.y + sin(angle) * (r - 12))
        let b = CGPoint(x: center.x + cos(angle) * (r + 12), y: center.y + sin(angle) * (r + 12))
        p.move(to: a); p.addLine(to: b)
        return p.strokedPath(.init(lineWidth: 3, lineCap: .round))
    }
}

// MARK: - Start / Stop

private struct StartStopButton: View {
    @Environment(SaunaStore.self) private var store
    var body: some View {
        let heating = store.state.heater
        Button {
            Task { heating ? await store.stop() : await store.start() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: heating ? "stop.circle.fill" : "flame.fill")
                    .font(.title3.weight(.bold))
                if heating {
                    VStack(spacing: 0) {
                        Text("Heating").font(.system(.title3, design: .rounded, weight: .bold))
                        Text("Tap to turn off")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("Start Heating").font(.system(.title3, design: .rounded, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .foregroundStyle(heating ? Theme.ember : Theme.bg0)
            .background {
                if heating {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.ember.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.ember.opacity(0.55), lineWidth: 1.5))
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.emberGradient)
                }
            }
            .emberGlow(Theme.ember, radius: 18, active: !heating)
        }
        .buttonStyle(.plain)
        .disabled(store.busy)
        .opacity(store.busy ? 0.7 : 1)
    }
}

/// Live feedback for slow/failed controls — a stubborn sauna module must never
/// fail silently again (a Start once spent 45s recovering with zero on-screen signal).
private struct ControlFeedback: View {
    @Environment(SaunaStore.self) private var store
    var body: some View {
        if store.state.heatInterrupted, !store.busy {
            // the FD-5 panel can switch heat off when woken after a remote start
            HStack(spacing: 10) {
                Label("Heat was switched off — maybe a panel tap", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.emberHot)
                Spacer(minLength: 4)
                Button("Resume heat") { Task { await store.start() } }
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .buttonStyle(.borderedProminent).tint(Theme.ember)
            }
        } else if let notice = store.controlNotice {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(notice)
            }
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(Theme.amber)
        } else if let error = store.controlError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.emberHot)
        }
    }
}

// MARK: - Target temperature

private struct TargetCard: View {
    @Environment(SaunaStore.self) private var store
    let state: SaunaState
    @State private var text = ""
    @FocusState private var editing: Bool

    private var displayed: Int { state.targetTempF ?? 150 }

    var body: some View {
        HStack {
            Label("Target", systemImage: "target").foregroundStyle(Theme.textSecondary)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            Spacer()
            stepButton("minus") { editing = false; Task { await store.nudgeTarget(-1) } }
            // Tap to type a setpoint directly; +/- still nudge by 1°.
            HStack(spacing: 1) {
                TextField("", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .focused($editing)
                    .fixedSize()
                    .frame(minWidth: 52)
                Text("°")
            }
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textPrimary).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(editing ? Theme.ember.opacity(0.16) : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            stepButton("plus") { editing = false; Task { await store.nudgeTarget(1) } }
        }
        .glassCard(14)
        .onAppear { text = String(displayed) }
        .onChange(of: state.targetTempF) { _, new in
            if !editing { text = String(new ?? 150) }   // live poll updates the field only when not typing
        }
        .onChange(of: editing) { _, focused in
            if focused { text = String(displayed) } else { commit() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
    }

    /// Parse the typed digits, clamp to the FD-5 setpoint range, and write once.
    private func commit() {
        let digits = text.filter(\.isNumber)
        guard let raw = Int(digits) else { text = String(displayed); return }
        let clamped = max(86, min(170, raw))
        text = String(clamped)
        if clamped != state.targetTempF { Task { await store.setTarget(clamped) } }
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.bold)).foregroundStyle(Theme.ember)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.ember.opacity(0.14)))
        }.buttonStyle(.plain)
    }
}

// MARK: - Timer

private struct TimerCard: View {
    @Environment(SaunaStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let state: SaunaState

    private var valueText: String { state.timerSetMin.map { "\($0) min" } ?? "Off" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Timer", systemImage: "timer").foregroundStyle(Theme.textSecondary)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            Menu {
                Button("Off") { Task { await store.setTimer(0) } }
                ForEach(settings.timerPresets, id: \.self) { m in
                    Button("\(m) min") { Task { await store.setTimer(m) } }
                }
            } label: {
                DropdownPill(text: valueText)
            }
            .disabled(!state.power)   // device resets the timer on power-on; set it after turning on
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(state.power ? 1 : 0.6)
        .glassCard(14)
    }
}

// MARK: - Lights

private struct LightsCard: View {
    @Environment(SaunaStore.self) private var store
    let state: SaunaState

    private var swatch: Color? {
        guard state.power, !state.lightsScrolling else { return nil }
        return ChromaPalette.color(for: state.chromoColor)
    }
    private var valueText: String {
        guard state.power else { return "Off" }
        if state.lightsScrolling { return "Cycle" }
        if state.lightsOn {
            return ChromaPalette.solids.first { $0.value == state.chromoColor }?.name ?? "On"
        }
        return "Off"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Lighting", systemImage: "lightbulb.led").foregroundStyle(Theme.textSecondary)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            Menu {
                // the FD-5 ignores light changes while powered off
                Button("Off") { Task { await store.setChromo(ChromaPalette.off) } }
                ForEach(ChromaPalette.solids, id: \.value) { c in
                    Button(c.name) { Task { await store.setChromo(c.value) } }
                }
                Button("Cycle") { Task { await store.setChromo(ChromaPalette.scroll) } }
            } label: {
                DropdownPill(text: valueText, swatch: swatch, scrolling: state.lightsScrolling)
            }
            .disabled(!state.power)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(state.power ? 1 : 0.6)
        .glassCard(14)
    }
}

/// Compact dropdown trigger shared by the Timer and Lighting cards.
private struct DropdownPill: View {
    let text: String
    var swatch: Color? = nil
    var scrolling: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            if scrolling {
                Image(systemName: "sparkles").font(.subheadline).foregroundStyle(Theme.amber)
            } else if let swatch {
                Circle().fill(swatch).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25)))
            }
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12).frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// (Removed: SonosCard — the FD-5's audio is Bluetooth, controlled by the phone/pad,
// not over the Tuya API. See the "sauna-audio-is-local-bluetooth" note.)

// MARK: - Status (preheat ETA / next schedule)

/// Adaptive card: while preheating shows the ETA to target (from the learned heat
/// rate) with a progress bar; otherwise shows the next upcoming schedule.
private struct StatusCard: View {
    @Environment(SaunaStore.self) private var store
    @Environment(HeatingModel.self) private var heating
    @Environment(SchedulesStore.self) private var schedules
    let state: SaunaState
    @State private var showSchedules = false

    var body: some View {
        // Show both when applicable: the ETA while preheating, and always the next
        // scheduled event so "what's next" stays visible even mid-session.
        if preheatETA != nil || nextSchedule != nil {
            VStack(spacing: 12) {
                if let eta = preheatETA { preheatView(eta) }
                if let next = nextSchedule { nextView(next.schedule) }
            }
        }
    }

    // MARK: preheat

    /// Minutes to reach target from the current temp (nil unless actively climbing).
    private var preheatETA: Int? {
        guard state.heater, let cur = state.currentTempF, let tgt = state.targetTempF, cur < tgt - 1
        else { return nil }
        return heating.leadMinutes(from: cur, to: tgt)
    }

    private func preheatView(_ eta: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Preheating", systemImage: "flame.fill")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.ember)
                Spacer()
                Text("ready in ~\(eta) min")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            }
            ProgressView(value: state.preheatProgress).tint(Theme.ember)
            HStack {
                Text("\(state.currentTempF ?? 0)°")
                Spacer()
                Text("target \(state.targetTempF ?? 0)°")
            }
            .font(.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
        }
        .glassCard(14)
    }

    // MARK: next schedule

    private func nextView(_ s: SaunaSchedule) -> some View {
        Button { showSchedules = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.title3).foregroundStyle(Theme.amber).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next · \(nextDayLabel)")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        Text(s.timeString)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if s.readyBy && s.turnOn {
                            Text("READY BY")
                                .font(.system(.caption2, design: .rounded, weight: .bold))
                                .foregroundStyle(Theme.amber)
                        }
                    }
                    Text("\(s.repeatSummary) · \(s.actionSummary)")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .glassCard(14)
        .sheet(isPresented: $showSchedules) { SchedulesView() }
    }

    /// The soonest future firing across all enabled schedules (within a week).
    private var nextSchedule: (schedule: SaunaSchedule, fire: Date)? {
        let now = Date()
        let cal = Calendar.current
        var best: (SaunaSchedule, Date)?
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            for s in schedules.schedules where s.enabled {
                // currentTempF: nil → cold-start estimate (a future day, not "now")
                if let start = ScheduleEngine.startDate(for: s, on: day, currentTempF: nil,
                                                        heating: heating, calendar: cal),
                   start > now, best == nil || start < best!.1 {
                    best = (s, start)
                }
            }
        }
        return best.map { (schedule: $0.0, fire: $0.1) }
    }

    private var nextDayLabel: String {
        guard let fire = nextSchedule?.fire else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(fire) { return "Today" }
        if cal.isDateInTomorrow(fire) { return "Tomorrow" }
        return fire.formatted(.dateTime.weekday(.wide))
    }
}
