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
    var isLoading: Bool = false

    private init() {}

    // MARK: - Prompt

    /// One system prompt covers both the weather rules and the palette rules, so a single
    /// network round-trip drives the whole scene.
    private static let systemPrompt = """
    You are an environmental parameter generator for a procedural weather atmosphere app.
    Given an emotion or feeling, output precise numeric values that create the matching atmosphere,
    plus a matching 5-colour palette.

    CRITICAL: Do NOT think out loud in the content. Output ONLY the JSON object, starting immediately with "{", exactly this shape:
    {
      "weather": {
        "sceneTitle": "two evocative words",
        "atmosphereDescription": "one minimalist sentence, 10-15 words, no metaphors",
        "precipitation": 0.0, "windSpeed": 0.0, "fogDensity": 0.0,
        "snowIntensity": 0.0, "clearness": 0.0, "lightningFrequency": 0.0,
        "colorTemperature": "one of: warm, cool, neutral, melancholy, golden, crimson, dusk, arctic, ember, ash"
      },
      "palette": {
        "title": "short evocative palette title",
        "colors": [
          {"name": "background ...", "hex": "#RRGGBB"},
          {"name": "surface ...",    "hex": "#RRGGBB"},
          {"name": "text ...",       "hex": "#RRGGBB"},
          {"name": "accent ...",     "hex": "#RRGGBB"},
          {"name": "secondary ...",  "hex": "#RRGGBB"}
        ]
      }
    }

    STRICT WEATHER RULES — violating these will break the experience:
    1. Rain (precipitation) and snow (snowIntensity) are mutually exclusive. Set exactly ONE to a non-zero value, never both.
    2. clearness must be 0.0 whenever precipitation > 0.2, snowIntensity > 0.2, or fogDensity > 0.3.
    3. lightningFrequency must be 0.0 unless precipitation >= 0.3.
    4. colorTemperature MUST contrast with the active weather:
       - snowing        → 'cool', 'arctic', or 'dusk' (particles need a non-white background)
       - heavy rain     → 'cool', 'melancholy', or 'dusk'
       - storm/rage     → 'melancholy', 'crimson', or 'dusk'
       - sunny/warm clear → 'golden' or 'warm'
       - cold clear sky → 'arctic'
       - foggy/overcast → 'neutral', 'ash', or 'cool'
       - smoldering/ember → 'ember'
       - twilight/mystery → 'dusk'
       - passion/wound  → 'crimson'
       - Never use 'golden' unless clearness > 0.5
       - Never use 'warm', 'golden', 'neutral', or 'arctic' for heavy snow or storm
    5. All numeric values are between 0.0 and 0.8. Use the range — do not cluster near 0.
    6. Choose the dominant weather type and set all competing types to 0. Focused scenes are more immersive.

    STRICT PALETTE RULES — you are a colour theorist for atmospheric, emotional UI palettes.
    Return exactly 5 colours in this fixed order: [0] background (dominant sky/atmosphere tone),
    [1] surface (subtle lighter or darker overlay of the background), [2] text (clearly readable on the
    background: dark on light, light on dark), [3] accent (emotionally evocative highlight matching the
    dominant weather), [4] secondary (softer accent or particle/mote tint).
    Every colour must belong to exactly one family, chosen from colorTemperature and the weather:
    • PASTEL — lightness 75–90, saturation 15–40. Soft, airy. For warm, golden, light clear scenes.
              Arctic scenes: lightness 75–92, saturation 4–18, cold blue-grey undertones.
    • SOFT   — lightness 45–75, saturation 10–30. Muted, painterly. For neutral, cool, misty, foggy, light snow.
              Ash scenes: lightness 45–65, saturation 4–15.
    • DARK   — lightness 8–40, saturation 10–35. Moody, deep, brooding. For melancholy, crimson, dusk, ember,
              storm, heavy rain, night scenes.
    FORBIDDEN: vivid primaries, neon tones, saturation above 45, pure black (#000000), pure white (#ffffff).
    Every hex is exactly 7 characters including the # prefix.
    The palette must visibly reflect the active conditions (heavy rain → wet, deep tones; fog → flattened,
    grey-washed; bright clear sky → warm luminous highlights; storm → high contrast).
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
            currentWeatherState = payload.weather.sanitized()
            currentPalette = Self.validated(payload.palette)
        } catch {
            // If the task was cancelled (user tapped back), discard silently.
            if Task.isCancelled || error is CancellationError { return }
            // Never log the user's text or the API key; the error description contains neither.
            print("Error generating weather state: \(error)")
            currentWeatherState = Self.errorFallback
            currentPalette = nil
        }
    }

    // MARK: - Helpers

    /// A palette is only used when it has 5 colours with well-formed hex values.
    private static func validated(_ palette: ColorPalette?) -> ColorPalette? {
        guard let palette, palette.colors.count == 5,
              palette.colors.allSatisfy({ $0.validColor != nil }) else { return nil }
        return palette
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
