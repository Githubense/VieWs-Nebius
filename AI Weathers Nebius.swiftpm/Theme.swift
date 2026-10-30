import SwiftUI

struct Theme {
    static let primaryDark = Color(hex: "#141413")
    static let primaryLight = Color(hex: "#faf9f5")
    static let midToneNeutral = Color(hex: "#b0aea5")
    /// Used for warm colorTemperature accents and hint text.
    static let primaryAccent = Color(hex: "#d97757")
    /// Used for cool colorTemperature accents and hint text.
    static let secondaryAccent = Color(hex: "#788c5d")
    /// Used for golden particles and the "golden" colorTemperature.
    static let goldenAccent = Color(hex: "#f5c97a")
    
    // Dynamic typography simulating Claude 2025 editorial mix
    static func titleFont() -> Font {
        // High-contrast serif
        return Font.system(size: 36, weight: .light, design: .serif)
    }
    
    static func subtitleFont() -> Font {
        return Font.system(size: 20, weight: .regular, design: .serif)
    }
    
    static func bodyFont() -> Font {
        // Clean sans-serif
        return Font.system(size: 16, weight: .regular, design: .default)
    }
    
    static func monoFont(size: CGFloat = 14) -> Font {
        return Font.system(size: size, weight: .medium, design: .monospaced)
    }
    
    static func backgroundColor(for temp: String?) -> Color {
        switch temp {
        case "warm":       return Color(hex: "#ece0d1")
        case "cool":       return Color(hex: "#8fa8b8")
        case "neutral":    return primaryLight
        case "melancholy": return Color(hex: "#2a2c2c")
        case "golden":     return Color(hex: "#f5ead8")
        case "crimson":    return Color(hex: "#3d1515")  // deep dark red
        case "dusk":       return Color(hex: "#2a1f3d")  // deep purple-indigo
        case "arctic":     return Color(hex: "#d6e8f0")  // icy pale blue
        case "ember":      return Color(hex: "#3d2010")  // deep dark orange-brown
        case "ash":        return Color(hex: "#c0c0bb")  // muted cool grey
        default:           return primaryLight
        }
    }

    static func textColor(for temp: String?) -> Color {
        switch temp {
        case "melancholy", "cool", "crimson", "dusk", "ember":
            return primaryLight
        default:  // warm, golden, neutral, arctic, ash
            return primaryDark
        }
    }

    static func hintColor(for temp: String?) -> Color {
        switch temp {
        case "warm":       return primaryAccent.opacity(0.7)
        case "cool":       return primaryLight.opacity(0.55)
        case "golden":     return goldenAccent.opacity(0.9)
        case "melancholy": return midToneNeutral.opacity(0.6)
        case "crimson":    return Color(hex: "#c87070").opacity(0.8)
        case "dusk":       return Color(hex: "#9080c0").opacity(0.75)
        case "arctic":     return Color(hex: "#7bafc8").opacity(0.85)
        case "ember":      return Color(hex: "#c87040").opacity(0.8)
        case "ash":        return midToneNeutral.opacity(0.65)
        default:           return midToneNeutral
        }
    }
}

// Helper extension for Hex colors
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
