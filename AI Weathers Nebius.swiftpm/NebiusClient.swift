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
            print("[VieWs][Location] Detected '\(loc)' — fetching live Tavily grounding...")
            if let grounding = await fetchTavilyGrounding(forLocation: loc) {
                promptUser += """

Real-world atmospheric grounding for \(loc) (via live Tavily AI search):
\(grounding)
CRITICAL INSTRUCTION: Base temperature, sky, and conditions strictly on the CURRENT real-time weather right now (do NOT use future daily forecast highs). Translate the emotional feeling into weather parameters faithfully informed by this live sensory context.
"""
                liveGrounding = grounding
            }
        } else {
            print("[VieWs][Location] Pure emotion — skipping Tavily grounding.")
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
            } catch NebiusError.invalidJSON(let msg) {
                attempt += 1
                if attempt <= 1 {
                    print("[VieWs][Nebius] JSON decode attempt \(attempt) failed (\(msg)). Retrying with explicit double-quote JSON enforcement...")
                    promptUser += "\n\nCRITICAL: Your previous response was not valid JSON. You MUST output ONLY raw valid JSON starting with '{' and ending with '}'. Use standard double quotes for all keys and strings. Never use single quotes."
                    continue
                }
                throw NebiusError.invalidJSON(msg)
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
        request.timeoutInterval = 7.0

        let query = "current temperature and weather conditions in \(location) right now live degrees"
        let body: [String: Any] = [
            "api_key": key,
            "query": query,
            "search_depth": "basic",
            "include_answer": true,
            "exclude_domains": ["weatherapi.com"],
            "max_results": 4
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[VieWs][Tavily] HTTP error: \(code)")
                return nil
            }
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
            } else {
                print("[VieWs][Tavily] Response JSON decoding failed")
            }
        } catch {
            print("[VieWs][Tavily] Network error/timeout: \(error.localizedDescription)")
            return nil
        }
        return nil
    }

    /// Universal grammatical-semantic check to detect if the user input contains a location reference.
    /// Operates by analyzing spatial prepositions ("in Kyoto", "miss Napoli") and recognized destinations,
    /// while strictly filtering out internal psychological/emotional states and personal pronouns.
    static func detectLocation(in text: String) -> String? {
        let clean = text.replacingOccurrences(of: "Emotion: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let lower = clean.lowercased()

        // 1. Regional abbreviations
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

        // 2. Emotional, psychological, and abstract terms that should NEVER trigger weather searches
        let abstractWords: Set<String> = [
            // Internal feelings, moods & sentiments (English & Spanish)
            "love", "pain", "peace", "grief", "silence", "fear", "doubt", "darkness",
            "light", "hope", "despair", "chaos", "thought", "thoughts", "pieces", "shambles",
            "awe", "melancholy", "sad", "sadness", "happy", "happiness", "peaceful", "anxious",
            "anxiety", "exhausted", "exhaustion", "cozy", "nostalgic", "nostalgia",
            "dreamy", "serene", "lonely", "loneliness", "hopeful", "overwhelmed", "calm",
            "restless", "sleepy", "joy", "anger", "bored", "meditative", "quiet", "solitude",
            "stillness", "heartbroken", "tired", "stressed", "stress", "bliss", "gloomy",
            "depressed", "depression", "excited", "nervous", "empty", "emptiness", "lost",
            "daydreaming", "sorrow", "search", "head", "heart", "chest", "soul", "memory", "memories", "mood",
            "good", "bad", "great", "fine", "okay", "ok", "terrible", "awful", "horrible", "weird",
            "down", "up", "low", "high", "numb", "cold", "warm", "hurt", "broken", "well",
            "sick", "not", "no", "yes", "very", "so", "really", "pretty", "kinda", "super", "quite",
            "just", "much", "little", "bit", "extremely", "totally", "feeling", "feel", "feels", "felt",
            "am", "im", "i'm", "going", "doing", "better", "best", "worse", "worst", "meh", "blah",
            "unhappy", "heavy", "achy", "dont", "don't", "cant", "can't", "wont", "won't", "isnt", "isn't",
            "off", "blue", "gray", "grey", "nothing", "everything", "something",
            // Spanish feelings & modifiers
            "amor", "dolor", "paz", "soledad", "tristeza", "miedo", "rabia", "nostalgia", "calma",
            "bien", "mal", "bueno", "malo", "mas", "menos", "muy", "tan", "estoy", "siento",
            "nada", "todo", "poco", "mucho", "bastante", "algo", "fatal", "pesimo", "genial",
            // Weather nouns (should not trigger city search)
            "rain", "snow", "thunder", "fog", "clouds", "sun", "wind", "storm", "drizzle", "sunshine",
            "lluvia", "nieve", "viento", "sol", "tormenta", "niebla",
            // Pronouns & grammatical objects
            "you", "me", "him", "her", "them", "us", "it", "this", "that", "all", "my",
            "your", "his", "their", "our", "a", "an", "the", "bed", "mind", "home", "work",
            "tears", "today", "yesterday", "tomorrow", "day", "night", "morning", "evening",
            "moment", "time", "life", "world", "here", "there", "school", "office", "room",
            "trabajo", "casa", "cama", "vida", "mundo", "aqui", "alli", "ti", "ella", "el"
        ]

        func isAbstract(_ word: String) -> Bool {
            let w = word.lowercased()
            if abstractWords.contains(w) { return true }
            // Collapse repeated letters (e.g. "goood" -> "good", "sooo" -> "so", "baddd" -> "bad")
            if let collapsed = try? NSRegularExpression(pattern: #"(.)\1+"#).stringByReplacingMatches(
                in: w, options: [], range: NSRange(location: 0, length: (w as NSString).length), withTemplate: "$1"
            ), abstractWords.contains(collapsed) {
                return true
            }
            if let doubleCollapsed = try? NSRegularExpression(pattern: #"(.)\1{2,}"#).stringByReplacingMatches(
                in: w, options: [], range: NSRange(location: 0, length: (w as NSString).length), withTemplate: "$1$1"
            ), abstractWords.contains(doubleCollapsed) {
                return true
            }
            return false
        }

        let weatherAdjectives: Set<String> = [
            "rainy", "sunny", "cloudy", "foggy", "snowy", "cold", "warm", "chilly", "windy",
            "stormy", "misty", "autumn", "winter", "summer", "spring", "gloomy", "breezy"
        ]

        // 3. Universal Spatial Prepositions in English & Spanish (non-greedy, checks multiple prepositions)
        let prepWords = "in|at|from|to|near|around|visiting|miss|missing|of|over|through|for|en|hacia|desde|extraño|extrano|extrañando|visitando|por"
        let prepPattern = #"\b(?:"# + prepWords + #")\s+((?:(?!\b(?:"# + prepWords + #")\b)[A-Za-z])+(?:\s+(?:(?!\b(?:"# + prepWords + #")\b)[A-Za-z])+){0,2})"#
        if let regex = try? NSRegularExpression(pattern: prepPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count))
            for match in matches {
                guard match.numberOfRanges > 1, let targetRange = Range(match.range(at: 1), in: clean) else { continue }
                let candidate = String(clean[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let words = candidate.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
                guard let first = words.first else { continue }
                if isAbstract(first) || first.count <= 2 { continue }

                // 3-word place (e.g. Rio de Janeiro, Cabo San Lucas)
                if words.count >= 3 {
                    let secondLower = words[1].lowercased()
                    let thirdLower = words[2].lowercased()
                    let particles: Set<String> = ["de", "del", "da", "san", "la", "los", "las", "el", "st", "saint"]
                    if particles.contains(secondLower) && !isAbstract(thirdLower) {
                        let particle = ["san", "st", "saint"].contains(secondLower) ? words[1].capitalized : words[1].lowercased()
                        return "\(first.capitalized) \(particle) \(words[2].capitalized)"
                    }
                }

                // 2-word place (e.g. New York, San Cristobal, Puerto Escondido)
                if words.count >= 2 {
                    if !isAbstract(words[1]) {
                        return "\(first.capitalized) \(words[1].capitalized)"
                    }
                }

                return first.capitalized
            }
        }

        // 4. Weather Adjective + Destination (e.g. "rainy Paris" -> "Paris", "sunny Barcelona" -> "Barcelona")
        let lettersOnly = clean.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if lettersOnly.count == 2 {
            let w0 = lettersOnly[0].lowercased()
            let w1 = lettersOnly[1].lowercased()
            if weatherAdjectives.contains(w0) && !isAbstract(w1) && w1.count > 2 {
                return lettersOnly[1].capitalized
            }
        }

        // 5. Standalone destination query (exact match for recognized world cities / destinations)
        let knownDestinations: Set<String> = [
            "tokyo", "kyoto", "osaka", "sapporo", "fukuoka", "okinawa",
            "napoli", "naples", "rome", "roma", "milan", "milano", "florence", "firenze", "venice", "venezia",
            "paris", "lyon", "marseille", "nice", "bordeaux",
            "london", "manchester", "edinburgh", "glasgow", "dublin",
            "madrid", "barcelona", "seville", "valencia", "bilbao",
            "berlin", "munich", "hamburg", "frankfurt", "cologne",
            "amsterdam", "rotterdam", "brussels", "antwerp", "vienna", "prague", "budapest", "warsaw", "krakow",
            "stockholm", "oslo", "copenhagen", "helsinki", "reykjavik", "zurich", "geneva",
            "athens", "istanbul", "ankara", "lisbon", "porto",
            "new york", "los angeles", "chicago", "san francisco", "seattle", "austin", "denver",
            "miami", "boston", "honolulu", "portland", "new orleans", "atlanta",
            "toronto", "vancouver", "montreal", "calgary",
            "sydney", "melbourne", "brisbane", "auckland",
            "seoul", "busan", "singapore", "hong kong", "taipei", "bangkok", "hanoi", "manila", "jakarta",
            "delhi", "mumbai", "bangalore", "dubai", "doha", "cairo", "cape town",
            "mexico city", "oaxaca", "cancun", "guadalajara", "monterrey", "puerto escondido",
            "buenos aires", "rio", "rio de janeiro", "sao paulo", "bogota", "medellin", "cartagena",
            "lima", "cusco", "santiago", "havana"
        ]

        let joinedQuery = lettersOnly.map { $0.lowercased() }.joined(separator: " ")
        if knownDestinations.contains(joinedQuery) {
            return lettersOnly.map { $0.capitalized }.joined(separator: " ")
        }
        if lettersOnly.count == 1, let single = lettersOnly.first, knownDestinations.contains(single.lowercased()) {
            return single.capitalized
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

    /// Sanitizes common LLM output anomalies (single quotes, trailing commas, parenthetical notes, comments).
    static func repairJSON(_ raw: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the model wrapped the JSON in conversational text, isolate the JSON substring first
        if let open = str.firstIndex(of: "{"), let close = str.lastIndex(of: "}"), open < close {
            str = String(str[open...close]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 1. If already valid JSON according to JSONSerialization, keep it
        if let data = str.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return str
        }

        // 2. Strip single-line comments // ...
        if let commentRegex = try? NSRegularExpression(pattern: #"//[^\n\r]*"#) {
            str = commentRegex.stringByReplacingMatches(
                in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length), withTemplate: ""
            )
        }

        // 3. Remove inline parenthetical comments after numbers: e.g. "precipitation": 0.0 (none), -> "precipitation": 0.0,
        if let numNoteRegex = try? NSRegularExpression(pattern: #":\s*([0-9.]+)\s*\([^)]*\)"#) {
            str = numNoteRegex.stringByReplacingMatches(
                in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length), withTemplate: ": $1"
            )
        }

        // 4. Remove inline parenthetical comments after strings: e.g. "colorTemperature": "golden" (warm), -> "colorTemperature": "golden",
        if let strNoteRegex = try? NSRegularExpression(pattern: #":\s*("[^"]*")\s*\([^)]*\)"#) {
            str = strNoteRegex.stringByReplacingMatches(
                in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length), withTemplate: ": $1"
            )
        }

        // 5. Convert single quotes around JSON keys: e.g. 'sceneTitle': -> "sceneTitle":
        if let keyRegex = try? NSRegularExpression(pattern: #"'([A-Za-z0-9_]+)'\s*:"#) {
            str = keyRegex.stringByReplacingMatches(
                in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length), withTemplate: "\"$1\":"
            )
        }

        // 6. Convert single quotes around string values: e.g. : 'some value' -> : "some value"
        let valPattern = #":\s*'((?:\\'|[^'\r\n])*)'(?=\s*[,}\]\r\n]|$)"#
        if let valRegex = try? NSRegularExpression(pattern: valPattern) {
            let currentNsStr = str as NSString
            let matches = valRegex.matches(in: str, options: [], range: NSRange(location: 0, length: currentNsStr.length))
            for match in matches.reversed() {
                let matchRange = match.range(at: 0)
                let innerRange = match.range(at: 1)
                let inner = (str as NSString).substring(with: innerRange)
                let fixedInner = inner.replacingOccurrences(of: "\"", with: "\\\"")
                                      .replacingOccurrences(of: "\\'", with: "'")
                let replacement = ": \"\(fixedInner)\""
                str = (str as NSString).replacingCharacters(in: matchRange, with: replacement)
            }
        }

        // 7. Remove trailing commas before closing braces/brackets (e.g. ", }" or ", ]")
        if let commaRegex = try? NSRegularExpression(pattern: #",\s*([}\]])"#) {
            str = commaRegex.stringByReplacingMatches(
                in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length), withTemplate: "$1"
            )
        }

        return str
    }

    /// Strips reasoning blocks and code fences, repairs formatting, then decodes into WeatherPayload.
    static func decodePayload(from raw: String) throws -> WeatherPayload {
        let extracted = extractJSON(from: raw)
        let json = repairJSON(extracted)
        guard let data = json.data(using: .utf8) else { throw NebiusError.invalidJSON("not UTF-8") }
        do {
            return try JSONDecoder().decode(WeatherPayload.self, from: data)
        } catch {
            // One last attempt: try decoding directly from the raw extracted if repair had side effects
            if let rawData = extracted.data(using: .utf8),
               let payload = try? JSONDecoder().decode(WeatherPayload.self, from: rawData) {
                return payload
            }
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

        // Helper to validate and repair candidate strings
        func tryCandidate(_ rawCandidate: String) {
            let candidate = repairJSON(rawCandidate)
            if (candidate.contains("\"sceneTitle\"") || candidate.contains("\"weather\"") || candidate.contains("\"precipitation\"")),
               let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                candidates.append(candidate)
            }
        }

        // 2. Collect all fenced code blocks ```json ... ```, ```python ... ```, or ``` ... ```
        var fenceIndex = text.startIndex
        while fenceIndex < text.endIndex, let startFence = text[fenceIndex...].range(of: "```") {
            let afterStart = startFence.upperBound
            var codeStart = afterStart
            if text[afterStart...].hasPrefix("json") {
                codeStart = text.index(afterStart, offsetBy: 4)
            } else if text[afterStart...].hasPrefix("python") {
                codeStart = text.index(afterStart, offsetBy: 6)
            }
            if let endFence = text[codeStart...].range(of: "```") {
                let fenced = String(text[codeStart..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                tryCandidate(fenced)
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
                tryCandidate(candidate)
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
            return repairJSON(text)
        }
        return repairJSON(String(text[start...end]))
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
