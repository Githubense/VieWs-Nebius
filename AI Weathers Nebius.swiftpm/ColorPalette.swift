import SwiftUI

// MARK: - Generated colour model

/// A single colour with a semantic role name and hex code, decoded from the model's JSON.
/// `name`: the semantic role plus a short descriptor, e.g. 'background midnight indigo'.
/// `hex`: CSS hex colour including the # prefix, exactly 7 characters, e.g. '#3A7BD5'.
struct GeneratedColor: Codable, Sendable {
    var name: String

    var hex: String

    /// Returns the colour if the hex string is well-formed, nil otherwise.
    /// Used by ContentView palette helpers to detect invalid/empty model output.
    var validColor: Color? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, UInt64(cleaned, radix: 16) != nil else { return nil }
        return Color(hex: hex)
    }

    /// WCAG 2.1 relative luminance (0 = black, 1 = white).
    var luminance: Double {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return 0 }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio against another GeneratedColor (1–21).
    func contrastRatio(against other: GeneratedColor) -> Double {
        let l1 = max(self.luminance, other.luminance)
        let l2 = min(self.luminance, other.luminance)
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

// MARK: - Palette model

/// A 5-colour atmospheric palette generated alongside every WeatherState.
/// Indices have fixed semantic roles:
///   [0] background  — dominant atmosphere/sky tone
///   [1] surface     — subtle overlay variant of the background
///   [2] text        — high-contrast colour readable on the background
///   [3] accent      — emotionally evocative highlight / particle tint
///   [4] secondary   — softer secondary accent or mote tint
struct ColorPalette: Codable, Sendable {
    /// A short evocative title for this palette matching the scene mood.
    var title: String

    /// Exactly 5 colours in fixed semantic order: [0] background — dominant sky/atmosphere tone,
    /// [1] surface — subtle overlay variant, [2] text — high-contrast readable on background,
    /// [3] accent — emotionally evocative highlight, [4] secondary — softer secondary accent or mote tint.
    var colors: [GeneratedColor]
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
