import SwiftUI

/// The FD-5's light palette (DP111), from the Tuya thing model and checked at the sauna
/// 2026-10-25. Besides these solids the enum has "Scroll" (color cycle) and "Off".
/// Lights only respond while the sauna is powered on. Shared so the app (LightsCard)
/// and the Live Activity accent agree.
enum ChromaPalette {
    static let solids: [(value: String, name: String, color: Color)] = [
        ("White",   "White",   Color(red: 1.00, green: 0.97, blue: 0.92)),
        ("Red",     "Red",     Color(red: 1.00, green: 0.23, blue: 0.19)),
        ("Orange",  "Orange",  Color(red: 1.00, green: 0.55, blue: 0.10)),
        ("Yellow",  "Yellow",  Color(red: 1.00, green: 0.83, blue: 0.10)),
        ("Green",   "Green",   Color(red: 0.20, green: 0.82, blue: 0.34)),
        ("Cyan",    "Cyan",    Color(red: 0.22, green: 0.85, blue: 0.90)),
        ("Blue",    "Blue",    Color(red: 0.10, green: 0.52, blue: 1.00)),
        ("Purple",  "Purple",  Color(red: 0.62, green: 0.35, blue: 1.00)),
        ("Magenta", "Magenta", Color(red: 1.00, green: 0.25, blue: 0.75)),
    ]
    static let scroll = "Scroll"
    static let off = "Off"

    /// Swatch color for a stored DP111 value (for the Live Activity accent); nil if not a solid.
    static func color(for value: String?) -> Color? {
        solids.first { $0.value == value }?.color
    }
}
