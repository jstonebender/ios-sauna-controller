import Foundation

/// What saunad does when the heat timer reaches 0, as a single sequence:
///   1. cut the **heater** (always — the timer governs heating, DP101, not power, DP102)
///   2. optionally **change the light** to a chosen color (a "done" cue), power still on
///   3. **hold power** for `powerOffDelayMin` minutes (lights stay on — you're not left
///      in the dark mid-session)
///   4. **power off**
///
/// Wire format (sent in the `/control` body as `timerEndAction`):
///   { "changeLight": true, "color": "Blue", "powerOffDelayMin": 10 }
/// `color` matters only when `changeLight`; `powerOffDelayMin == 0` powers off immediately.
struct TimerEndAction: Codable, Equatable {
    /// Change the light at timer end (e.g. to signal the session is done).
    var changeLight: Bool = false
    /// Color to switch to at timer end (a ChromaPalette solid), used when `changeLight`.
    var color: String = "Blue"
    /// Minutes to stay powered (lights on) after the timer ends, then power off.
    /// 0 = power off immediately at timer end.
    var powerOffDelayMin: Int = 0

    static let `default` = TimerEndAction()

    /// The plain device default: no light change, power off immediately.
    var isDefault: Bool { !changeLight && powerOffDelayMin == 0 }

    /// Short label for the Timer card / summaries, e.g. "Blue · off in 10m", "off in 10m", "off".
    var summary: String {
        var parts: [String] = []
        if changeLight { parts.append(color) }
        parts.append(powerOffDelayMin > 0 ? "off in \(powerOffDelayMin)m" : "off")
        return parts.joined(separator: " · ")
    }
}
