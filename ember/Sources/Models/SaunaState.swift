import Foundation

/// Mirrors emberd `GET /state`. Lenient decode so partial payloads never break the UI.
struct SaunaState: Codable, Equatable, Sendable {
    var power = false
    var heater = false
    var currentTempF: Int? = nil
    var targetTempF: Int? = nil
    var timerSetMin: Int? = nil
    var timerRemainingMin: Int? = nil
    var chromoColor: String? = nil
    var unit = "f"
    /// Set by emberd when the heater stopped without being asked (e.g. a panel tap); epoch seconds.
    var heaterInterruptedAt: Double? = nil
    var online = false
    var updatedAt: Double = 0

    init() {}

    enum K: String, CodingKey {
        case power, heater, currentTempF, targetTempF, timerSetMin, timerRemainingMin
        case chromoColor, unit, heaterInterruptedAt, online, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func bool(_ k: K) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? false }
        func int(_ k: K) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil }
        func str(_ k: K) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        power = bool(.power)
        heater = bool(.heater)
        currentTempF = int(.currentTempF)
        targetTempF = int(.targetTempF)
        timerSetMin = int(.timerSetMin)
        timerRemainingMin = int(.timerRemainingMin)
        chromoColor = str(.chromoColor)
        unit = str(.unit) ?? "f"
        heaterInterruptedAt = (try? c.decodeIfPresent(Double.self, forKey: .heaterInterruptedAt)) ?? nil
        online = bool(.online)
        updatedAt = ((try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil) ?? 0
    }

    // MARK: Derived

    /// Coarse status for the header.
    enum Status { case off, preheating, ready, heating, idleWarm }
    var status: Status {
        // Heater is the authoritative "on" signal — the power *status* DP (20) lags the
        // toggle by a beat, so keying off it would briefly flash "Off" mid-start.
        if heater {
            if let cur = currentTempF, let tgt = targetTempF {
                return cur >= tgt - 2 ? .ready : .preheating
            }
            return .heating
        }
        return power ? .idleWarm : .off   // powered but not heating = "On" (idle)
    }
    private var currentWarm: Bool { (currentTempF ?? 0) > 90 }

    /// FD-5 lights are one enum (DP111) where "Off" is a value; they only run while powered.
    var lightsOn: Bool { power && chromoColor != nil && chromoColor != ChromaPalette.off }
    var lightsScrolling: Bool { power && chromoColor == ChromaPalette.scroll }
    /// Heat stopped mid-session without the app asking — offer to resume.
    var heatInterrupted: Bool { heaterInterruptedAt != nil && !heater }

    /// 0…1 heat ratio for the gauge (75°F floor → target, capped at 170).
    var heatRatio: Double {
        guard let cur = currentTempF else { return 0 }
        let floorF = 75.0, ceilF = Double(max(targetTempF ?? 150, 150))
        return max(0, min(1, (Double(cur) - floorF) / (ceilF - floorF)))
    }

    /// 0…1 preheat progress toward target.
    var preheatProgress: Double {
        guard let cur = currentTempF, let tgt = targetTempF, tgt > 75 else { return 0 }
        return max(0, min(1, (Double(cur) - 75) / (Double(tgt) - 75)))
    }

    static var sample: SaunaState {
        var s = SaunaState()
        s.power = true; s.heater = true; s.currentTempF = 129; s.targetTempF = 150
        s.timerSetMin = 60; s.timerRemainingMin = 41; s.chromoColor = "White"
        s.online = true; s.updatedAt = Date().timeIntervalSince1970
        return s
    }
}

/// emberd `POST /control` body — only set fields are sent.
struct ControlRequest: Encodable {
    var power: Bool? = nil
    var heater: Bool? = nil
    var targetTempF: Int? = nil
    var timerMin: Int? = nil
    var chromoColor: String? = nil
}

struct SessionResult: Decodable, Sendable {
    var durationSec: Int?
    var peakTempF: Int?
}
