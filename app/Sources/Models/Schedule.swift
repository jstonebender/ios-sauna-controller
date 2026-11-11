import Foundation
import Observation

/// One scheduled sauna event: at a time, on chosen weekdays (or once on a date),
/// turn the sauna on (optionally setting target/light/timer) or off.
/// Persisted locally for now; designed to later sync to saunad, which fires them.
struct SaunaSchedule: Identifiable, Codable, Equatable {
    var id = UUID()
    var enabled = true
    var hour = 6
    var minute = 30
    /// Weekdays this repeats on, 1...7 (1 = Sunday, Calendar convention).
    /// Empty means a one-time schedule — see `onceDate`.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]   // Mon–Fri
    /// For one-time schedules (weekdays empty): the day to fire on.
    var onceDate: Date? = nil
    /// true = turn on (apply the set fields); false = turn off.
    var turnOn = true
    /// When true, `hour:minute` is when the target should be *reached*; heating
    /// starts `preheatLeadMin` earlier. When false, it's when heating *starts*.
    var readyBy = false
    /// When true, the preheat lead is learned (HeatingModel); when false, uses the
    /// manual `preheatLeadMin`.
    var autoPreheat = true
    /// Minutes of preheat lead (manual, or the last auto estimate stored for display).
    var preheatLeadMin = 45
    /// Fields applied when turning on; nil means "leave as is".
    var targetTempF: Int? = 150
    var chromoColor: String? = "White"
    var timerMin: Int? = nil

    var isOneTime: Bool { weekdays.isEmpty }

    private func string(h: Int, m: Int) -> String {
        var c = DateComponents(); c.hour = h; c.minute = m
        let date = Calendar.current.date(from: c) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// The anchor time — start time, or (when readyBy) the target-reached time.
    var timeString: String { string(h: hour, m: minute) }

    /// When readyBy, the time heating actually starts (anchor − lead).
    var startTimeString: String {
        let total = (hour * 60 + minute - preheatLeadMin + 1440) % 1440
        return string(h: total / 60, m: total % 60)
    }

    /// e.g. "Mon–Fri", "Every day", "Weekends", "Once · Nov 12".
    var repeatSummary: String {
        if isOneTime {
            guard let d = onceDate else { return "Once" }
            return "Once · " + d.formatted(.dateTime.month(.abbreviated).day())
        }
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [1, 7] { return "Weekends" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        let symbols = Calendar.current.shortWeekdaySymbols      // ["Sun",...]
        return weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
    }

    /// e.g. "On · 165° · Red", "Off".
    var actionSummary: String {
        guard turnOn else { return "Off" }
        var parts = ["On"]
        if let t = targetTempF { parts.append("\(t)°") }
        if let c = chromoColor, c != "Off" { parts.append(c) }
        if let m = timerMin { parts.append("\(m)m") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class SchedulesStore {
    var schedules: [SaunaSchedule] {
        didSet { persist() }
    }

    private static let key = "saunad.schedules"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SaunaSchedule].self, from: data) {
            schedules = decoded
        } else {
            schedules = []
        }
    }

    /// Insert or replace by id, then keep sorted by time of day.
    func upsert(_ s: SaunaSchedule) {
        if let i = schedules.firstIndex(where: { $0.id == s.id }) {
            schedules[i] = s
        } else {
            schedules.append(s)
        }
        schedules.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    func delete(_ s: SaunaSchedule) {
        schedules.removeAll { $0.id == s.id }
    }

    func toggle(_ s: SaunaSchedule) {
        if let i = schedules.firstIndex(where: { $0.id == s.id }) {
            schedules[i].enabled.toggle()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Learns how fast the sauna heats (°F per minute) by watching real sessions, so
/// "ready by" schedules can start heating just early enough. Starts from a default
/// rate and refines with each observed climb to target. Persisted locally.
@MainActor
@Observable
final class HeatingModel {
    private(set) var ratePerMin: Double
    private(set) var sampleCount: Int

    /// Assumed cold-start temperature used to estimate a lead for a future schedule.
    static let assumedAmbientF = 70

    private static let kRate = "saunad.heatRatePerMin"
    private static let kCount = "saunad.heatSamples"
    private static let defaultRate = 2.5   // °F/min, a reasonable IR-sauna starting guess

    private var climbStartTemp: Int?
    private var climbStartAt: Date?

    init() {
        let r = UserDefaults.standard.double(forKey: Self.kRate)
        ratePerMin = r > 0 ? r : Self.defaultRate
        sampleCount = UserDefaults.standard.integer(forKey: Self.kCount)
    }

    /// Estimated minutes to climb from `current` to `target`, clamped to something sane.
    func leadMinutes(from current: Int, to target: Int) -> Int {
        let delta = max(0, target - current)
        let mins = Double(delta) / max(0.5, ratePerMin)
        return max(5, min(180, Int(mins.rounded())))
    }

    /// Lead estimate for a future schedule (assumes a cold, room-temp start).
    func estimatedLead(toTarget target: Int) -> Int {
        leadMinutes(from: Self.assumedAmbientF, to: target)
    }

    /// Feed each live poll; records a rate sample when a heat-up reaches target.
    func observe(_ s: SaunaState) {
        guard s.power, s.heater, let cur = s.currentTempF, let tgt = s.targetTempF else {
            climbStartAt = nil; climbStartTemp = nil; return
        }
        if climbStartAt == nil {
            climbStartAt = Date(); climbStartTemp = cur; return
        }
        if cur >= tgt, let start = climbStartAt, let t0 = climbStartTemp {
            record(deltaF: Double(cur - t0), minutes: Date().timeIntervalSince(start) / 60)
            climbStartAt = nil; climbStartTemp = nil   // wait for the next cold heat-up
        }
    }

    private func record(deltaF: Double, minutes: Double) {
        guard deltaF > 5, minutes > 1 else { return }          // ignore tiny/noisy climbs
        let observed = deltaF / minutes
        guard observed > 0.2, observed < 20 else { return }    // sanity clamp
        let w = 0.3                                            // exponential weighting
        ratePerMin = sampleCount == 0 ? observed : ratePerMin * (1 - w) + observed * w
        sampleCount += 1
        UserDefaults.standard.set(ratePerMin, forKey: Self.kRate)
        UserDefaults.standard.set(sampleCount, forKey: Self.kCount)
    }
}

/// Decides when a schedule should fire and what it does. Pure, testable logic —
/// the app uses it for live previews now, and saunad will use the same rules to
/// actually fire schedules once it runs the loop. The key point: for a "ready by"
/// schedule it recomputes the preheat lead from the *live* temperature at decision
/// time, so a warm cabin starts late and a cold one starts early.
@MainActor
enum ScheduleEngine {
    /// The control to apply when the schedule fires.
    static func action(for s: SaunaSchedule) -> ControlRequest {
        guard s.turnOn else { return ControlRequest(power: false, heater: false) }
        return ControlRequest(power: true, heater: true,
                              targetTempF: s.targetTempF,
                              timerMin: s.timerMin,
                              chromoColor: s.chromoColor)
    }

    /// Preheat lead to use right now for a "ready by" schedule: from the live temp and
    /// learned rate when auto; the stored manual lead otherwise; 0 when not "ready by".
    /// Falls back to a cold-start estimate when the current temp is unknown.
    static func leadMinutes(for s: SaunaSchedule, currentTempF: Int?, heating: HeatingModel) -> Int {
        guard s.readyBy, s.turnOn else { return 0 }
        let target = s.targetTempF ?? 150
        guard s.autoPreheat else { return s.preheatLeadMin }
        if let cur = currentTempF { return heating.leadMinutes(from: cur, to: target) }
        return heating.estimatedLead(toTarget: target)
    }

    /// The moment heating should start for the given calendar `day`, or nil if the
    /// schedule doesn't apply that day / is disabled. For "ready by" this is the
    /// target time minus the live-recomputed lead.
    static func startDate(for s: SaunaSchedule, on day: Date, currentTempF: Int?,
                          heating: HeatingModel, calendar: Calendar = .current) -> Date? {
        guard s.enabled else { return nil }
        if s.isOneTime {
            guard let once = s.onceDate, calendar.isDate(once, inSameDayAs: day) else { return nil }
        } else {
            guard s.weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        }
        guard let anchor = calendar.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day)
        else { return nil }
        let lead = leadMinutes(for: s, currentTempF: currentTempF, heating: heating)
        return lead == 0 ? anchor : calendar.date(byAdding: .minute, value: -lead, to: anchor)
    }

    /// Whether a tick at `now` should fire this schedule (start moment within [now-window, now]).
    static func shouldFire(_ s: SaunaSchedule, now: Date, currentTempF: Int?, heating: HeatingModel,
                           window: TimeInterval = 60, calendar: Calendar = .current) -> Bool {
        guard let start = startDate(for: s, on: now, currentTempF: currentTempF,
                                    heating: heating, calendar: calendar) else { return false }
        return now >= start && now < start.addingTimeInterval(window)
    }
}
