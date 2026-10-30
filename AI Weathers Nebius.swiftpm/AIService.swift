import Foundation
import SwiftUI

/// Generates a `WeatherState` (+ optional `ColorPalette`) from a user's emotion by calling
/// NVIDIA Nemotron on Nebius Token Factory (see `NebiusClient`).
///
/// Public surface is unchanged from the on-device version so `ContentView` needs no changes:
/// `shared`, `currentWeatherState`, `currentPalette`, `isLoading`, `generateWeather(for:)`.
@Observable
@MainActor
class AIService {
    static let shared = AIService()

    /// True when a Token Factory key + model ID are configured (see Secrets.swift).
    var isModelReady: Bool = NebiusConfig.isConfigured
    var currentWeatherState: WeatherState?
    var currentPalette: ColorPalette?
    var currentGrounding: String?
    var currentGroundingLocation: String?
    var isLoading: Bool = false

    private init() {}

    // MARK: - Prompt

    /// System instructions ported from the original Apple Intelligence @Generable sessions:
    /// combines the procedural weather parameter generator and the 5-colour atmospheric colour theorist.
    private static let systemPrompt = """
    You are an environmental parameter generator and atmospheric colour theorist for a procedural weather app.
    Given a human emotion or feeling (and optional real-world weather grounding), translate it into physical weather parameters and a 5-colour atmospheric palette.

    STRICT WEATHER & TITLE RULES:
    1. sceneTitle: MUST be a poetic, minimalist TWO-WORD lowercase title in the form [emotional/sensory modifier] + [atmospheric/weather noun].
       - The first word captures the emotional texture (for example: weary, hollow, velvet, drifting, quiet, amber, restless, faded).
       - The second word MUST be a weather, sky, wind, or light phenomenon (for example: dusk, winds, wind, mist, rain, drizzle, haze, fog, storm, sky, dawn, twilight, stillness, frost, snow, ember, breeze, squall, horizon).
       - NEVER output a single word, and NEVER copy literal everyday nouns from the user's sentence (never use words like "hackathon", "work", "office", "deadline", "presentation", "fatigue", "optimism"). Always translate the human situation into sky and weather.
    2. atmosphereDescription: One minimalist sensory sentence (10–15 words) describing the physical weather. No metaphors.
    3. Rain (precipitation) and snow (snowIntensity) are mutually exclusive. Set at most ONE to a non-zero value, never both.
    4. clearness must be 0.0 whenever precipitation > 0.2, snowIntensity > 0.2, or fogDensity > 0.3.
    5. lightningFrequency must be 0.0 unless precipitation >= 0.3.
    6. colorTemperature MUST contrast with the active weather and be one of:
       - snowing          -> cool, arctic, or dusk
       - heavy rain       -> cool, melancholy, or dusk
       - storm / rage     -> melancholy, crimson, or dusk
       - sunny / warm     -> golden or warm
       - cold clear sky   -> arctic
       - foggy / overcast -> neutral, ash, or cool
       - weary/exhausted  -> dusk, ash, or melancholy
       - smoldering       -> ember
       - twilight/mystery -> dusk
       - passion / wound  -> crimson
       - Never use golden unless clearness > 0.5.
       - Never use warm, golden, neutral, or arctic for heavy snow or storm.
    7. All numeric values must be between 0.0 and 0.8. Choose the dominant weather type and set competing types to 0.0.

    STRICT PALETTE STYLE RULES — return 5 harmonious hex colours (#RRGGBB) belonging to the matching family:
    • PASTEL (high lightness L 75–90, low saturation S 15–40): soft, airy, delicate. Use for warm, golden, arctic, light clear scenes.
    • SOFT   (medium lightness L 45–75, low saturation S 10–30): muted, painterly, subdued. Use for neutral, cool, misty, foggy, light snow scenes.
    • DARK   (low lightness L 8–40, medium saturation S 10–35): moody, deep, brooding. Use for melancholy, crimson, dusk, ember, storm, heavy rain scenes.
    FORBIDDEN: vivid primaries, neon tones, saturation > 45, pure black (#000000), pure white (#ffffff).
    Prefer watercolour washes, overcast skies, aged paper, or damp stone in exact semantic order:
    [0] background: dominant sky/atmosphere tone matching colorTemperature and conditions
    [1] surface: subtle lighter or darker overlay variant of the background
    [2] text: high-contrast readable on background (dark text on light background, light text on dark background)
    [3] accent: emotionally evocative highlight matching the dominant weather condition
    [4] secondary: softer secondary accent or particle/mote tint
    """

    private static let maxInputLength = 300

    // MARK: - Generation

    func generateWeather(for emotion: String) async {
        let cleaned = String(
            emotion.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxInputLength)
        )
        isModelReady = NebiusConfig.isConfigured

        guard isModelReady else {
            // Not configured (fresh clone without a key): friendly fallback instead of a crash.
            currentWeatherState = Self.notConfiguredFallback
            currentPalette = nil
            currentGrounding = nil
            currentGroundingLocation = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let payload = try await NebiusClient.shared.generate(
                system: Self.systemPrompt,
                user: "Emotion: \(cleaned)"
            )

            // Stop here if the user navigated back while the request was in flight.
            guard !Task.isCancelled else { return }

            // Deterministic safety net: enforces every rule regardless of what the model returned.
            let sanitizedWeather = payload.weather.sanitized()
            currentWeatherState = sanitizedWeather
            currentPalette = Self.validated(payload.palette) ?? Self.proceduralPalette(for: sanitizedWeather)
            currentGrounding = payload.grounding
            currentGroundingLocation = payload.groundingLocation
        } catch {
            // If the task was cancelled (user tapped back), discard silently.
            if Task.isCancelled || error is CancellationError { return }
            // Never log the user's text or the API key; the error description contains neither.
            print("Error generating weather state: \(error)")
            currentWeatherState = Self.errorFallback
            currentPalette = nil
            currentGrounding = nil
            currentGroundingLocation = nil
        }
    }

    // MARK: - Helpers

    /// A palette is only used when it has 5 colours with well-formed hex values and readable text contrast.
    private static func validated(_ palette: ColorPalette?) -> ColorPalette? {
        guard var palette, palette.colors.count == 5,
              palette.colors.allSatisfy({ $0.validColor != nil }) else { return nil }
        let bg = palette.colors[0]
        let txt = palette.colors[2]
        if bg.contrastRatio(against: txt) < 3.5 {
            let safeHex = bg.luminance > 0.42 ? "#242220" : "#F2EFE9"
            palette.colors[2] = GeneratedColor(name: "text readable", hex: safeHex)
        }
        return palette
    }

    /// Procedural 5-color palette matching the active weather conditions and temperature.
    private static func proceduralPalette(for weather: WeatherState) -> ColorPalette {
        let t = weather.colorTemperature
        let title = "\(weather.sceneTitle) Palette"
        let hexes: [String]
        switch t {
        case "melancholy":
            hexes = ["#2A2C2C", "#3A3C3C", "#F5F4EF", "#788C5D", "#B0AEA5"]
        case "golden":
            hexes = ["#F5EAD8", "#E8DCC6", "#2C2824", "#D97757", "#F5C97A"]
        case "warm":
            hexes = ["#ECE0D1", "#DFD2C1", "#28231D", "#D97757", "#C29B7F"]
        case "cool":
            hexes = ["#8FA8B8", "#7E97A7", "#FFFFFF", "#4A687A", "#B0C5D4"]
        case "arctic":
            hexes = ["#D6E8F0", "#C2D9E3", "#1B2A32", "#5B8FA8", "#EAF4F8"]
        case "crimson":
            hexes = ["#3D1515", "#4E1F1F", "#F7E8E8", "#C87070", "#8B3A3A"]
        case "dusk":
            hexes = ["#2A1F3D", "#382B52", "#F0EBF8", "#9080C0", "#68548C"]
        case "ember":
            hexes = ["#3D2010", "#502C17", "#FBEEF5", "#C87040", "#E08A50"]
        case "ash":
            hexes = ["#C0C0BB", "#B0B0AA", "#222220", "#686862", "#8C8C85"]
        default: // neutral
            hexes = ["#FAF9F5", "#EDECE6", "#141413", "#788C5D", "#B0AEA5"]
        }

        let roles = ["background", "surface", "text", "accent", "secondary"]
        let colors = zip(roles, hexes).map { role, hex in
            GeneratedColor(name: "\(role) \(t)", hex: hex)
        }
        return ColorPalette(title: title, colors: colors)
    }

    private static let notConfiguredFallback = WeatherState(
        sceneTitle: "Calm Breeze",
        atmosphereDescription: "A gentle wind moves through tall grass on a quiet afternoon.",
        precipitation: 0.1,
        windSpeed: 0.2,
        fogDensity: 0.0,
        snowIntensity: 0.0,
        clearness: 0.6,
        lightningFrequency: 0.0,
        colorTemperature: "neutral"
    )

    private static let errorFallback = WeatherState(
        sceneTitle: "Quiet Storm",
        atmosphereDescription: "Heavy rain falls steadily, muffling the world into a grey stillness.",
        precipitation: 0.7,
        windSpeed: 0.4,
        fogDensity: 0.2,
        snowIntensity: 0.0,
        clearness: 0.0,
        lightningFrequency: 0.1,
        colorTemperature: "melancholy"
    )
}
