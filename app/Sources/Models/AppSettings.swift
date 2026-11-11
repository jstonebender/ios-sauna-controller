import Foundation
import Observation

/// User-editable connection config. A value entered in Settings persists in
/// UserDefaults and wins; otherwise the app falls back to the build-time default
/// injected from the gitignored Local.xcconfig (empty in a clean checkout — set it
/// in Settings instead). saunad's `/state` is open; control calls need the API key.
@MainActor
@Observable
final class AppSettings {
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.kURL) }
    }
    var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Self.kKey) }
    }
    /// Quick-pick minute durations shown in the Timer dropdown; editable in Settings.
    var timerPresets: [Int] {
        didSet { UserDefaults.standard.set(timerPresets, forKey: Self.kPresets) }
    }
    /// Applied when starting the sauna (Start Heating / Get In). 0 = don't set a timer.
    var defaultTimerMin: Int {
        didSet { UserDefaults.standard.set(defaultTimerMin, forKey: Self.kDefTimer) }
    }
    /// Light color applied when starting the sauna. "White" by default.
    var defaultLightColor: String {
        didSet { UserDefaults.standard.set(defaultLightColor, forKey: Self.kDefLight) }
    }

    static let defaultPresets = [25, 60, 75, 90]

    private static let kURL = "saunad.baseURL"
    private static let kKey = "saunad.apiKey"
    private static let kPresets = "saunad.timerPresets"
    private static let kDefTimer = "saunad.defaultTimerMin"
    private static let kDefLight = "saunad.defaultLightColor"

    init() {
        baseURL = UserDefaults.standard.string(forKey: Self.kURL) ?? Self.buildDefault("SaunadDefaultURL")
        apiKey = UserDefaults.standard.string(forKey: Self.kKey) ?? Self.buildDefault("SaunadDefaultAPIKey")
        timerPresets = ((UserDefaults.standard.array(forKey: Self.kPresets) as? [Int]) ?? Self.defaultPresets).sorted()
        defaultTimerMin = (UserDefaults.standard.object(forKey: Self.kDefTimer) as? Int) ?? 60
        defaultLightColor = UserDefaults.standard.string(forKey: Self.kDefLight) ?? "White"
    }

    /// Default injected at build time from the gitignored Local.xcconfig (via Info.plist).
    /// Empty in a clean checkout; used only until a value is saved in Settings.
    private static func buildDefault(_ key: String) -> String {
        ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    var url: URL? { baseURL.isEmpty ? nil : URL(string: baseURL) }
    var hasKey: Bool { !apiKey.isEmpty }
}
