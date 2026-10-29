import Foundation

// MARK: - Configuration

/// Resolves Nebius Token Factory settings. Never logs the key.
enum NebiusConfig {
    static var apiKey: String {
        if let env = ProcessInfo.processInfo.environment["NEBIUS_API_KEY"], !env.isEmpty { return env }
        if let stored = UserDefaults.standard.string(forKey: "nebius_api_key"), !stored.isEmpty { return stored }
        return Secrets.nebiusAPIKey
    }

    static var model: String { Secrets.nebiusModel }

    static var baseURL: URL? { URL(string: Secrets.nebiusBaseURL) }

    static var proxyURL: URL? {
        if let env = ProcessInfo.processInfo.environment["NEBIUS_PROXY_URL"], let url = URL(string: env), !env.isEmpty { return url }
        if let stored = UserDefaults.standard.string(forKey: "nebius_proxy_url"), let url = URL(string: stored), !stored.isEmpty { return url }
        if !Secrets.nebiusProxyURL.isEmpty, let url = URL(string: Secrets.nebiusProxyURL) { return url }
        return nil
    }

    static var useProxy: Bool { proxyURL != nil }

    /// True when either a proxy URL is configured or a direct real key and model ID have been provided.
    static var isConfigured: Bool {
        if useProxy { return true }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && !key.hasPrefix("YOUR_")
            && !model.isEmpty && !model.hasPrefix("PASTE_")
            && baseURL != nil
    }
}

// MARK: - Errors

enum NebiusError: Error, CustomStringConvertible {
    case notConfigured
    case http(status: Int, body: String)
    case emptyResponse
    case invalidJSON(String)

    var description: String {
        switch self {
        case .notConfigured:        return "Nebius is not configured (see Secrets.swift)."
        case .http(let s, let b):   return "Nebius HTTP \(s): \(b.prefix(300))"
        case .emptyResponse:        return "Nebius returned an empty response."
        case .invalidJSON(let m):   return "Could not read model JSON: \(m)"
        }
    }
}

// MARK: - Payload returned by the model

/// One model response carries either a direct `WeatherState` (matching original guided generation)
/// or a wrapped payload containing both `weather` and `palette`.
struct WeatherPayload: Decodable, Sendable {
    var weather: WeatherState
    var palette: ColorPalette?
    var grounding: String?
    var groundingLocation: String?

    private enum CodingKeys: String, CodingKey { case weather, palette, grounding, groundingLocation }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.weather) {
            weather = try c.decode(WeatherState.self, forKey: .weather)
            palette = try? c.decodeIfPresent(ColorPalette.self, forKey: .palette)
            grounding = try? c.decodeIfPresent(String.self, forKey: .grounding)
            groundingLocation = try? c.decodeIfPresent(String.self, forKey: .groundingLocation)
        } else {
            // Direct root WeatherState
            weather = try WeatherState(from: decoder)
            palette = nil
            grounding = nil
            groundingLocation = nil
        }
    }

    init(weather: WeatherState, palette: ColorPalette?, grounding: String? = nil, groundingLocation: String? = nil) {
        self.weather = weather
        self.palette = palette
        self.grounding = grounding
        self.groundingLocation = groundingLocation
    }
}

// MARK: - Client

/// Minimal OpenAI-compatible chat-completions client for Nebius Token Factory.
actor NebiusClient {
    static let shared = NebiusClient()

    private enum Mode: String { case jsonSchema = "json_schema", jsonObject = "json_object", none }
    private var mode: Mode = Mode(rawValue: Secrets.responseMode) ?? .none

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 90
        return URLSession(configuration: cfg)
    }()

    /// Requests one weather scene. Routes through Nebius Serverless Endpoints proxy if configured;
    /// otherwise enriches natural language emotions with Tavily AI grounding and calls Token Factory directly.
    func generate(system: String, user: String) async throws -> WeatherPayload {
        if let proxy = NebiusConfig.proxyURL {
            return try await sendToProxy(proxyURL: proxy, user: user)
        }

        guard NebiusConfig.isConfigured, let base = NebiusConfig.baseURL else { throw NebiusError.notConfigured }

        // Enforce natural language emotion grounding via Tavily AI web retrieval when a location is referenced
        var promptUser = user
        var liveGrounding: String? = nil
        var detectedLocation: String? = nil

        let cleanEmotion = user.replacingOccurrences(of: "Emotion: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let loc = Self.detectLocation(in: cleanEmotion) {
            detectedLocation = loc
            if let grounding = await fetchTavilyGrounding(forLocation: loc) {
                promptUser += "\nReal-world atmospheric grounding for \(loc) (via Tavily search): \(grounding)\nTranslate the emotional feeling into weather parameters informed by this sensory context."
                liveGrounding = grounding
            }
        }

        var attempt = 0
        while true {
            do {
                let text = try await send(system: system, user: promptUser, base: base)
                var payload = try Self.decodePayload(from: text)
                if payload.grounding == nil {
                    payload.grounding = liveGrounding
                }
                if payload.groundingLocation == nil {
                    payload.groundingLocation = detectedLocation
                }
                return payload
            } catch NebiusError.http(let status, let body) {
                attempt += 1
                if status == 400, let lower = downgraded(mode) {
                    mode = lower                       // model doesn't support this response_format
                    continue
                }
                if (status == 429 || status >= 500), attempt <= 1 {
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                throw NebiusError.http(status: status, body: body)
            }
        }
    }

    /// Asynchronously fetches real-world atmospheric grounding from Tavily AI Search for a detected location.
    private func fetchTavilyGrounding(forLocation location: String) async -> String? {
        let key = Secrets.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("YOUR_") else { return nil }
        guard let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3.5

        let query = "current weather in \(location) today conditions temperature sky"
        let body: [String: Any] = [
            "api_key": key,
            "query": query,
            "search_depth": "basic",
            "include_answer": true,
            "max_results": 5
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            struct TavilyResult: Decodable {
                let content: String?
            }
            struct TavilyResp: Decodable {
                let answer: String?
                let results: [TavilyResult]?
            }
            if let parsed = try? JSONDecoder().decode(TavilyResp.self, from: data) {
                if let answer = parsed.answer, !answer.isEmpty,
                   !answer.localizedCaseInsensitiveContains("do not provide"),
                   !answer.localizedCaseInsensitiveContains("could not find") {
                    print("[VieWs][Tavily] Grounding fetched: \(answer.prefix(90))...")
                    return answer
                }
                // Fallback to top result snippet if the AI answer synthesis missed
                if let snippet = parsed.results?.first(where: { ($0.content?.contains("°") ?? false) })?.content,
                   !snippet.isEmpty {
                    print("[VieWs][Tavily] Grounding snippet: \(snippet.prefix(90))...")
                    return snippet
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Fast, zero-network check to detect if the user input contains a location reference.
    /// If found, returns the clean location name (e.g. "Chiapas", "New York", "Paris").
    /// If it is purely an emotion or psychological state, returns nil (saving network/search quota).
    static func detectLocation(in text: String) -> String? {
        let clean = text.replacingOccurrences(of: "Emotion: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let lower = clean.lowercased()

        // 1. Common abbreviations
        let abbrevs: [String: String] = [
            "ny": "New York", "nyc": "New York", "la": "Los Angeles", "sf": "San Francisco",
            "cdmx": "Mexico City", "dc": "Washington D.C."
        ]
        for (abbr, full) in abbrevs {
            let p = #"\b"# + NSRegularExpression.escapedPattern(for: abbr) + #"\b"#
            if let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
               regex.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return full
            }
        }

        // 2. Known multi-word cities
        let multiWordCities = [
            "new york", "san francisco", "mexico city", "los angeles", "buenos aires",
            "rio de janeiro", "puerto rico", "costa rica", "hong kong", "san diego",
            "las vegas", "san cristobal", "san miguel", "puerto vallarta"
        ]
        for mwc in multiWordCities {
            let p = #"\b"# + NSRegularExpression.escapedPattern(for: mwc) + #"\b"#
            if let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
               regex.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return mwc.capitalized
            }
        }

        // 3. Known single-word global locations (cities, Mexican states/destinations, countries)
        let globalLocations: Set<String> = [
            // Mexico & Americas
            "chiapas", "oaxaca", "mexico", "cancun", "guadalajara", "monterrey", "puebla",
            "yucatan", "merida", "tijuana", "queretaro", "veracruz", "toluca", "acapulco",
            "chicago", "miami", "seattle", "austin", "boston", "denver", "portland",
            "toronto", "vancouver", "montreal", "bogota", "medellin", "lima", "santiago",
            "havana", "san juan", "patagonia",
            // Europe
            "paris", "london", "berlin", "madrid", "barcelona", "rome", "milan", "florence",
            "venice", "amsterdam", "vienna", "prague", "budapest", "zurich", "geneva",
            "dublin", "edinburgh", "copenhagen", "stockholm", "oslo", "helsinki", "reykjavik",
            "athens", "lisbon", "porto", "munich", "frankfurt", "brussels",
            // Asia, Oceania, Middle East, Africa
            "tokyo", "kyoto", "osaka", "seoul", "beijing", "shanghai", "taipei", "singapore",
            "bangkok", "bali", "mumbai", "delhi", "dubai", "doha", "hanoi", "sydney",
            "melbourne", "auckland", "cairo", "marrakech",
            // Countries
            "japan", "italy", "france", "spain", "germany", "greece", "norway", "sweden",
            "iceland", "switzerland", "ireland", "scotland", "brazil", "argentina", "chile",
            "colombia", "peru", "korea", "china", "india", "australia", "canada"
        ]
        for loc in globalLocations {
            let p = #"\b"# + NSRegularExpression.escapedPattern(for: loc) + #"\b"#
            if let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
               regex.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return loc.capitalized
            }
        }

        // Filter out non-location emotional / abstract words
        let nonLocations: Set<String> = [
            "love", "pain", "peace", "grief", "silence", "fear", "bed", "mind", "home",
            "work", "tears", "doubt", "a", "the", "my", "this", "that", "all", "darkness",
            "light", "hope", "despair", "chaos", "thought", "pieces", "shambles", "awe",
            "melancholy", "sad", "sadness", "happy", "happiness", "peaceful", "anxious",
            "anxiety", "exhausted", "exhaustion", "cozy", "nostalgic", "nostalgia",
            "dreamy", "serene", "lonely", "loneliness", "hopeful", "overwhelmed", "calm",
            "restless", "sleepy", "joy", "anger", "bored", "meditative", "quiet", "solitude",
            "stillness", "heartbroken", "tired", "stressed", "stress", "bliss", "gloomy",
            "depressed", "depression", "excited", "nervous", "empty", "emptiness", "lost",
            "today", "yesterday", "tomorrow", "day", "night", "morning", "evening", "moment"
        ]

        // 4. Preposition extraction: "in Banff", "miss Florence", "sunset over Aspen", "rain in Kyoto"
        let prepPattern = #"\b(?:in|at|from|to|near|around|visiting|miss|missing|of|over|through)\s+([A-Za-z]+)"#
        if let regex = try? NSRegularExpression(pattern: prepPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count)),
           let targetRange = Range(match.range(at: 1), in: clean) {
            let target = String(clean[targetRange]).lowercased()
            if !nonLocations.contains(target) && target.count > 2 {
                return String(clean[targetRange]).capitalized
            }
        }

        // 5. Standalone single-word query if not in nonLocations: e.g. "Banff", "Aspen", "Palenque"
        let words = clean.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if words.count == 1 {
            let single = words[0].lowercased()
            if !nonLocations.contains(single) && single.count > 2 {
                return words[0].capitalized
            }
        }

        return nil
    }

    /// Fast, zero-network check to verify if the user input contains a place or location reference.
    static func containsLocationReference(_ text: String) -> Bool {
        return detectLocation(in: text) != nil
    }

    private func sendToProxy(proxyURL: URL, user: String) async throws -> WeatherPayload {
        let endpoint: URL
        if proxyURL.path.isEmpty || proxyURL.path == "/" {
            endpoint = proxyURL.appendingPathComponent("v1/scene")
        } else {
            endpoint = proxyURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let emotionText = user.hasPrefix("Emotion: ") ? String(user.dropFirst("Emotion: ".count)) : user
        let body: [String: Any] = ["emotion": emotionText]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NebiusError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NebiusError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw NebiusError.emptyResponse
        }
        return try Self.decodePayload(from: text)
    }

    /// Diagnostic helper to inspect raw model text
    func testSend(system: String, user: String) async throws -> String {
        guard NebiusConfig.isConfigured, let base = NebiusConfig.baseURL else { throw NebiusError.notConfigured }
        return try await send(system: system, user: user, base: base)
    }

    private func downgraded(_ m: Mode) -> Mode? {
        switch m {
        case .jsonSchema: return .jsonObject
        case .jsonObject: return Mode.none
        case .none:       return nil
        }
    }

    // MARK: Request

    private func send(system: String, user: String, base: URL) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(NebiusConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": NebiusConfig.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ],
            "temperature": 0.4,
            "max_tokens": 3000,
            "stream": false
        ]
        switch mode {
        case .jsonSchema:
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "weather_scene", "strict": true, "schema": Self.schema]
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .none:
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NebiusError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NebiusError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct Chat: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable {
                    let content: String?
                    let reasoning: String?
                    let reasoning_content: String?
                }
                let message: Msg
            }
            let choices: [Choice]
        }
        let chat = try JSONDecoder().decode(Chat.self, from: data)
        guard let choice = chat.choices.first else { throw NebiusError.emptyResponse }
        if let content = choice.message.content, !content.isEmpty {
            return content
        }
        if let reasoning = choice.message.reasoning ?? choice.message.reasoning_content, !reasoning.isEmpty {
            return reasoning
        }
        throw NebiusError.emptyResponse
    }

    // MARK: Parsing (static so it can be unit-tested without the network)

    /// Strips reasoning blocks and code fences, then decodes the first JSON object found.
    static func decodePayload(from raw: String) throws -> WeatherPayload {
        let json = extractJSON(from: raw)
        guard let data = json.data(using: .utf8) else { throw NebiusError.invalidJSON("not UTF-8") }
        do {
            return try JSONDecoder().decode(WeatherPayload.self, from: data)
        } catch {
            throw NebiusError.invalidJSON("\(error)")
        }
    }

    static func extractJSON(from raw: String) -> String {
        var text = raw

        // 1. Remove <think>…</think> reasoning blocks some models emit.
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let open = text.range(of: "<think>") { text.removeSubrange(open.lowerBound..<text.endIndex) }

        var candidates: [String] = []

        // 2. Collect all fenced code blocks ```json ... ``` or ``` ... ```
        var fenceIndex = text.startIndex
        while fenceIndex < text.endIndex, let startFence = text[fenceIndex...].range(of: "```") {
            let afterStart = startFence.upperBound
            var codeStart = afterStart
            if text[afterStart...].hasPrefix("json") {
                codeStart = text.index(afterStart, offsetBy: 4)
            }
            if let endFence = text[codeStart...].range(of: "```") {
                let fenced = String(text[codeStart..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if (fenced.contains("\"sceneTitle\"") || fenced.contains("\"weather\"")),
                   let data = fenced.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    candidates.append(fenced)
                }
                fenceIndex = endFence.upperBound
            } else {
                break
            }
        }

        // 3. Scan for all balanced JSON objects containing weather keys
        var searchIndex = text.startIndex
        while searchIndex < text.endIndex, let openBrace = text[searchIndex...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escape = false
            var closeBrace: String.Index? = nil

            for idx in text.indices[openBrace...] {
                let char = text[idx]
                if escape {
                    escape = false
                    continue
                }
                if char == "\\" && inString {
                    escape = true
                    continue
                }
                if char == "\"" {
                    inString.toggle()
                    continue
                }
                if !inString {
                    if char == "{" {
                        depth += 1
                    } else if char == "}" {
                        depth -= 1
                        if depth == 0 {
                            closeBrace = idx
                            break
                        }
                    }
                }
            }

            if let close = closeBrace {
                let candidate = String(text[openBrace...close])
                if (candidate.contains("\"sceneTitle\"") || candidate.contains("\"weather\"") || candidate.contains("\"precipitation\"")),
                   let data = candidate.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    candidates.append(candidate)
                }
                searchIndex = text.index(after: openBrace)
            } else {
                break
            }
        }

        // Discard any candidates that are just echoed placeholder templates from system prompts
        let nonPlaceholders = candidates.filter {
            !$0.contains("two evocative words") &&
            !$0.contains("one minimalist sentence") &&
            !$0.contains("describing the physical atmosphere") &&
            !$0.contains("Title Here") &&
            !$0.contains("Evocative Title")
        }

        // Pick the LAST non-placeholder candidate (the final generated output at the end of the thought trace)
        if let best = nonPlaceholders.last ?? candidates.last {
            return best
        }

        // Fallback: first '{' to last '}'
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[start...end])
    }

    // MARK: JSON schema (used when response mode is json_schema)

    static var schema: [String: Any] {
        let unit: [String: Any] = ["type": "number", "minimum": 0, "maximum": 0.8]
        let color: [String: Any] = [
            "type": "object",
            "properties": ["name": ["type": "string"], "hex": ["type": "string"]],
            "required": ["name", "hex"],
            "additionalProperties": false
        ]
        let weather: [String: Any] = [
            "type": "object",
            "properties": [
                "sceneTitle": ["type": "string"],
                "atmosphereDescription": ["type": "string"],
                "precipitation": unit, "windSpeed": unit, "fogDensity": unit,
                "snowIntensity": unit, "clearness": unit, "lightningFrequency": unit,
                "colorTemperature": ["type": "string", "enum": WeatherState.allowedColorTemperatures]
            ],
            "required": ["sceneTitle", "atmosphereDescription", "precipitation", "windSpeed", "fogDensity",
                         "snowIntensity", "clearness", "lightningFrequency", "colorTemperature"],
            "additionalProperties": false
        ]
        let palette: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "colors": ["type": "array", "items": color, "minItems": 5, "maxItems": 5]
            ],
            "required": ["title", "colors"],
            "additionalProperties": false
        ]
        return [
            "type": "object",
            "properties": ["weather": weather, "palette": palette],
            "required": ["weather", "palette"],
            "additionalProperties": false
        ]
    }
}
