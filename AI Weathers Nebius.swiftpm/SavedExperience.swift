import Foundation
import SwiftData
import SwiftUI

// MARK: - Persistent model

/// One saved atmosphere — everything needed to fully restore a generated
/// experience without re-prompting the AI.
@Model
final class SavedExperience {
    var id: UUID
    var dateCreated: Date

    // ── WeatherState fields ────────────────────────────────────────────
    var sceneTitle: String
    var atmosphereDescription: String
    var precipitation: Double
    var windSpeed: Double
    var fogDensity: Double
    var snowIntensity: Double
    var clearness: Double
    var lightningFrequency: Double
    var colorTemperature: String

    // ── ColorPalette fields (5 hex + palette title) ────────────────────
    var paletteTitle: String
    var hex0: String   // [0] background
    var hex1: String   // [1] surface
    var hex2: String   // [2] text
    var hex3: String   // [3] accent
    var hex4: String   // [4] secondary

    // MARK: - Init from live generation

    init(weather: WeatherState, paletteTitle: String,
         hex0: String, hex1: String, hex2: String, hex3: String, hex4: String) {
        self.id = UUID()
        self.dateCreated = Date()
        self.sceneTitle = weather.sceneTitle
        self.atmosphereDescription = weather.atmosphereDescription
        self.precipitation = weather.precipitation
        self.windSpeed = weather.windSpeed
        self.fogDensity = weather.fogDensity
        self.snowIntensity = weather.snowIntensity
        self.clearness = weather.clearness
        self.lightningFrequency = weather.lightningFrequency
        self.colorTemperature = weather.colorTemperature
        self.paletteTitle = paletteTitle
        self.hex0 = hex0
        self.hex1 = hex1
        self.hex2 = hex2
        self.hex3 = hex3
        self.hex4 = hex4
    }

    // MARK: - Init for seeds

    init(seed title: String, atmosphereDescription: String,
         precipitation: Double, windSpeed: Double, fogDensity: Double,
         snowIntensity: Double, clearness: Double, lightningFrequency: Double,
         colorTemperature: String, paletteTitle: String,
         hex0: String, hex1: String, hex2: String, hex3: String, hex4: String,
         daysAgo: Double = 0) {
        self.id = UUID()
        self.dateCreated = Date().addingTimeInterval(-daysAgo * 86400)
        self.sceneTitle = title
        self.atmosphereDescription = atmosphereDescription
        self.precipitation = precipitation
        self.windSpeed = windSpeed
        self.fogDensity = fogDensity
        self.snowIntensity = snowIntensity
        self.clearness = clearness
        self.lightningFrequency = lightningFrequency
        self.colorTemperature = colorTemperature
        self.paletteTitle = paletteTitle
        self.hex0 = hex0; self.hex1 = hex1; self.hex2 = hex2
        self.hex3 = hex3; self.hex4 = hex4
    }

    // MARK: - Reconstruction helpers

    /// Reconstructed WeatherState (no AI call needed).
    var weatherState: WeatherState {
        WeatherState(
            sceneTitle:            sceneTitle,
            atmosphereDescription: atmosphereDescription,
            precipitation:         precipitation,
            windSpeed:             windSpeed,
            fogDensity:            fogDensity,
            snowIntensity:         snowIntensity,
            clearness:             clearness,
            lightningFrequency:    lightningFrequency,
            colorTemperature:      colorTemperature
        )
    }

    /// Reconstructed ColorPalette (no AI call needed).
    var colorPalette: ColorPalette {
        ColorPalette(
            title: paletteTitle,
            colors: [
                GeneratedColor(name: "background", hex: hex0),
                GeneratedColor(name: "surface",    hex: hex1),
                GeneratedColor(name: "text",       hex: hex2),
                GeneratedColor(name: "accent",     hex: hex3),
                GeneratedColor(name: "secondary",  hex: hex4),
            ]
        )
    }

    /// Background color from the saved palette.
    var backgroundColor: Color { Color(hex: hex0) }

    /// Title text color — same contrast check as ContentView's paletteText:
    /// use hex2 only if it clears a 3.5:1 ratio against hex0;
    /// otherwise fall back to Theme.textColor for the colorTemperature.
    var contrastTextColor: Color {
        let textGen = GeneratedColor(name: "text",       hex: hex2)
        let bgGen   = GeneratedColor(name: "background", hex: hex0)
        if textGen.contrastRatio(against: bgGen) >= 3.5,
           let c = textGen.validColor { return c }
        return Theme.textColor(for: colorTemperature)
    }
}

// MARK: - Seed data

extension SavedExperience {
    /// Five distinct example atmospheres inserted on first launch.
    static var seeds: [SavedExperience] {
        [
            SavedExperience(
                seed: "quiet storm",
                atmosphereDescription: "Rain settles in a steady rhythm over still grey water.",
                precipitation: 0.55, windSpeed: 0.3, fogDensity: 0.2,
                snowIntensity: 0, clearness: 0, lightningFrequency: 0,
                colorTemperature: "melancholy", paletteTitle: "rain on slate",
                hex0: "#2e3440", hex1: "#3b4252", hex2: "#d8dee9", hex3: "#81a1c1", hex4: "#5e81ac",
                daysAgo: 5
            ),
            SavedExperience(
                seed: "golden hour",
                atmosphereDescription: "Warm light spreads slow and amber across an open plain.",
                precipitation: 0, windSpeed: 0.1, fogDensity: 0,
                snowIntensity: 0, clearness: 0.75, lightningFrequency: 0,
                colorTemperature: "golden", paletteTitle: "afternoon gold",
                hex0: "#e8d5a3", hex1: "#f0e0b0", hex2: "#5c4a1e", hex3: "#c9920a", hex4: "#b5813a",
                daysAgo: 3
            ),
            SavedExperience(
                seed: "first snow",
                atmosphereDescription: "Snow falls without a sound, covering everything in white.",
                precipitation: 0, windSpeed: 0.15, fogDensity: 0.15,
                snowIntensity: 0.6, clearness: 0, lightningFrequency: 0,
                colorTemperature: "arctic", paletteTitle: "soft white quiet",
                hex0: "#d6e8f0", hex1: "#e4f0f7", hex2: "#2a4a5e", hex3: "#8ab4c8", hex4: "#a8cdd8",
                daysAgo: 2
            ),
            SavedExperience(
                seed: "fog at dawn",
                atmosphereDescription: "Mist hangs low and unhurried over the sleeping city.",
                precipitation: 0, windSpeed: 0.1, fogDensity: 0.65,
                snowIntensity: 0, clearness: 0, lightningFrequency: 0,
                colorTemperature: "ash", paletteTitle: "ash morning",
                hex0: "#c0c0bb", hex1: "#ccccc7", hex2: "#3a3a38", hex3: "#8a8a84", hex4: "#aaaaa4",
                daysAgo: 1
            ),
            SavedExperience(
                seed: "electric dusk",
                atmosphereDescription: "Thunder rolls through violet air just before the lights go out.",
                precipitation: 0.5, windSpeed: 0.5, fogDensity: 0,
                snowIntensity: 0, clearness: 0, lightningFrequency: 0.45,
                colorTemperature: "dusk", paletteTitle: "violet storm",
                hex0: "#2a1f3d", hex1: "#352a50", hex2: "#c8b8e8", hex3: "#9870c0", hex4: "#7050a0",
                daysAgo: 4
            ),
        ]
    }
}
