import Foundation

/// The AI-generated weather state driving the audio and visual engines.
/// All output layers are driven exclusively by these properties.
/// Post-generation rules enforced by sanitized(): rain/snow are mutually exclusive,
/// clearness opposes precipitation/fog/snow, colorTemperature must contrast with dominant weather.
///
/// Decoded from the JSON returned by Nemotron on Nebius Token Factory. The numeric ranges and
/// the allowed `colorTemperature` values that used to be `@Guide` constraints are now part of
/// the JSON schema / prompt in `WeatherPayload` and are re-enforced by `sanitized()`.
struct WeatherState: Codable, Sendable {
    /// A poetic, minimalist two-word title reflecting the user's emotion.
    var sceneTitle: String

    /// A single minimalist sentence (10–15 words) describing why this weather fits the emotion. No metaphors.
    var atmosphereDescription: String

    /// Rain intensity. 0 = none, 1 = heavy downpour. Zero when snow is active. (model range 0...0.8)
    var precipitation: Double

    /// Wind speed. 0 = still, 1 = gale force. (model range 0...0.8)
    var windSpeed: Double

    /// Fog or mist density. 0 = clear, 1 = dense fog. Zero when clearness > 0.5. (model range 0...0.8)
    var fogDensity: Double

    /// Snowfall intensity. 0 = none, 1 = blizzard. Zero when rain is active. (model range 0...0.8)
    var snowIntensity: Double

    /// Sky clearness. 0 = fully overcast, 1 = golden sunlight. Zero when precipitation or snow is active. (model range 0...0.8)
    var clearness: Double

    /// Lightning frequency. 0 = silent, 1 = intense storm. Only non-zero when precipitation > 0.3. (model range 0...0.8)
    var lightningFrequency: Double

    /// Background tone. Maps emotion and dominant weather to a background colour family.
    /// snow/blizzard       → 'cool', 'arctic', 'dusk'
    /// storm/rage/passion  → 'melancholy', 'crimson', 'dusk'
    /// sunny/warm clear    → 'golden', 'warm'
    /// cold clear          → 'arctic'
    /// foggy/overcast      → 'neutral', 'ash', 'cool'
    /// embers/smoldering   → 'ember'
    /// twilight/nostalgia  → 'dusk'
    /// Allowed values: see `WeatherState.allowedColorTemperatures`.
    var colorTemperature: String

    /// The only values `colorTemperature` may take (formerly `@Guide(.anyOf(...))`).
    static let allowedColorTemperatures: [String] = [
        "warm", "cool", "neutral", "melancholy", "golden",
        "crimson", "dusk", "arctic", "ember", "ash"
    ]

    enum CodingKeys: String, CodingKey {
        case sceneTitle, atmosphereDescription, precipitation, windSpeed, fogDensity
        case snowIntensity, clearness, lightningFrequency, colorTemperature
    }

    init(
        sceneTitle: String,
        atmosphereDescription: String,
        precipitation: Double,
        windSpeed: Double,
        fogDensity: Double,
        snowIntensity: Double,
        clearness: Double,
        lightningFrequency: Double,
        colorTemperature: String
    ) {
        self.sceneTitle = sceneTitle
        self.atmosphereDescription = atmosphereDescription
        self.precipitation = precipitation
        self.windSpeed = windSpeed
        self.fogDensity = fogDensity
        self.snowIntensity = snowIntensity
        self.clearness = clearness
        self.lightningFrequency = lightningFrequency
        self.colorTemperature = colorTemperature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        sceneTitle = (try? container.decode(String.self, forKey: .sceneTitle)) ?? "Ambient Sky"
        atmosphereDescription = (try? container.decode(String.self, forKey: .atmosphereDescription)) ?? "A quiet atmosphere settles gently over the landscape."

        func decodeDouble(_ key: CodingKeys, defaultVal: Double = 0.0) -> Double {
            if let d = try? container.decode(Double.self, forKey: key) { return d }
            if let i = try? container.decode(Int.self, forKey: key) { return Double(i) }
            if let s = try? container.decode(String.self, forKey: key), let d = Double(s) { return d }
            return defaultVal
        }

        precipitation = decodeDouble(.precipitation)
        windSpeed = decodeDouble(.windSpeed, defaultVal: 0.2)
        fogDensity = decodeDouble(.fogDensity)
        snowIntensity = decodeDouble(.snowIntensity)
        clearness = decodeDouble(.clearness, defaultVal: 0.5)
        lightningFrequency = decodeDouble(.lightningFrequency)

        let rawTemp = (try? container.decode(String.self, forKey: .colorTemperature))?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "neutral"
        if Self.allowedColorTemperatures.contains(rawTemp) {
            colorTemperature = rawTemp
        } else {
            colorTemperature = "neutral"
        }
    }
}

// MARK: - Sanitization

extension WeatherState {
    /// Deterministic post-processing that enforces all mutual-exclusion and contrast rules
    /// regardless of what the model generated. Called after every AI response.
    func sanitized() -> WeatherState {
        var s = self

        // 0. The model is no longer schema-constrained on-device, so reject unknown tones.
        s.colorTemperature = s.colorTemperature
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !WeatherState.allowedColorTemperatures.contains(s.colorTemperature) {
            s.colorTemperature = "neutral"
        }
        s.sceneTitle = s.sceneTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerTitle = s.sceneTitle
        if lowerTitle.isEmpty
            || lowerTitle.contains("evocative")
            || lowerTitle.contains("title")
            || lowerTitle.contains("word")
            || lowerTitle.contains("e.g.")
            || lowerTitle.contains("(")
            || lowerTitle.split(separator: " ").count > 4 {
            s.sceneTitle = "quiet sky"
        }
        if s.atmosphereDescription.localizedCaseInsensitiveContains("minimalist sentence")
            || s.atmosphereDescription.localizedCaseInsensitiveContains("without metaphors")
            || s.atmosphereDescription.localizedCaseInsensitiveContains("sensory sentence") {
            s.atmosphereDescription = "A gentle breeze and soft light move through the quiet atmosphere."
        }

        // 1. Clamp all doubles to valid range
        s.precipitation      = max(0, min(1, s.precipitation))
        s.windSpeed          = max(0, min(1, s.windSpeed))
        s.fogDensity         = max(0, min(1, s.fogDensity))
        s.snowIntensity      = max(0, min(1, s.snowIntensity))
        s.clearness          = max(0, min(1, s.clearness))
        s.lightningFrequency = max(0, min(1, s.lightningFrequency))

        // Ensure a living atmosphere if all values collapsed to zero
        let totalActivity = s.precipitation + s.windSpeed + s.fogDensity + s.snowIntensity + s.clearness
        if totalActivity < 0.05 {
            s.clearness = 0.65
            s.windSpeed = 0.25
        }

        // 2. Rain and snow are mutually exclusive — keep the dominant one
        if s.precipitation > 0 && s.snowIntensity > 0 {
            if s.precipitation >= s.snowIntensity {
                s.snowIntensity = 0
            } else {
                s.precipitation = 0
            }
        }

        // 3. Clearness opposes precipitation, snow, and heavy fog
        let obscuration = max(s.precipitation, s.snowIntensity, s.fogDensity)
        if obscuration > 0.2 {
            s.clearness = min(s.clearness, max(0, 1 - obscuration * 1.2))
        }

        // 4. Lightning requires rain
        if s.lightningFrequency > 0 && s.precipitation < 0.25 {
            if s.precipitation < 0.1 {
                // No rain at all — kill lightning
                s.lightningFrequency = 0
            } else {
                // Light rain — cap lightning
                s.lightningFrequency = min(s.lightningFrequency, 0.3)
            }
        }

        // 5. Contrast enforcement: colorTemperature must suit active weather
        let dominant = s.dominantWeather
        let darkTemps:  Set<String> = ["melancholy", "crimson", "dusk", "ember"]
        let lightTemps: Set<String> = ["warm", "golden", "neutral", "arctic"]
        switch dominant {
        case .snow:
            // Particles need a clearly non-white background.
            // Light/warm temps make snow invisible — redirect to arctic (thematic) or cool.
            if lightTemps.contains(s.colorTemperature) {
                s.colorTemperature = (s.colorTemperature == "neutral") ? "arctic" : "cool"
            }
        case .clear:
            // Clearness looks wrong on very dark backgrounds.
            if darkTemps.contains(s.colorTemperature) {
                s.colorTemperature = "golden"
            }
        case .storm:
            // Storms look wrong on light or icy backgrounds.
            if lightTemps.contains(s.colorTemperature) {
                s.colorTemperature = "melancholy"
            }
        case .fog:
            // Golden and fiery tones conflict with mist.
            if s.colorTemperature == "golden" || s.colorTemperature == "ember" || s.colorTemperature == "crimson" {
                s.colorTemperature = "ash"
            }
        default:
            break
        }

        // 6. Prevent golden colorTemperature when there's no clearness
        if s.colorTemperature == "golden" && s.clearness < 0.3 {
            s.colorTemperature = "warm"
        }
        // 7. Prevent ember/crimson on snow (particles blend into dark-red bg poorly)
        if s.snowIntensity > 0.15 && (s.colorTemperature == "ember" || s.colorTemperature == "crimson") {
            s.colorTemperature = "dusk"
        }

        return s
    }

    private enum WeatherDominant {
        case rain, snow, fog, clear, storm, calm
    }

    private var dominantWeather: WeatherDominant {
        if lightningFrequency > 0.2 || (precipitation > 0.5 && lightningFrequency > 0.05) { return .storm }
        if snowIntensity > 0.1 { return .snow }
        if precipitation > 0.1 { return .rain }
        if clearness > 0.4 { return .clear }
        if fogDensity > 0.2 { return .fog }
        return .calm
    }
}
