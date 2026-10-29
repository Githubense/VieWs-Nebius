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

    private enum CodingKeys: String, CodingKey { case weather, palette }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.weather) {
            weather = try c.decode(WeatherState.self, forKey: .weather)
            palette = try? c.decodeIfPresent(ColorPalette.self, forKey: .palette)
        } else {
            // Direct root WeatherState
            weather = try WeatherState(from: decoder)
            palette = nil
        }
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
    /// otherwise calls Token Factory directly. Retries once on 429/5xx; downgrades JSON mode on a 400.
    func generate(system: String, user: String) async throws -> WeatherPayload {
        if let proxy = NebiusConfig.proxyURL {
            return try await sendToProxy(proxyURL: proxy, user: user)
        }

        guard NebiusConfig.isConfigured, let base = NebiusConfig.baseURL else { throw NebiusError.notConfigured }

        var attempt = 0
        while true {
            do {
                let text = try await send(system: system, user: user, base: base)
                return try Self.decodePayload(from: text)
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

        // 2. Check for fenced code block ```json ... ``` or ``` ... ```
        if let startFence = text.range(of: "```json"), let endFence = text.range(of: "```", range: startFence.upperBound..<text.endIndex) {
            let fenced = String(text[startFence.upperBound..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? JSONSerialization.jsonObject(with: Data(fenced.utf8))) != nil {
                return fenced
            }
        }
        if let startFence = text.range(of: "```"), let endFence = text.range(of: "```", range: startFence.upperBound..<text.endIndex) {
            let fenced = String(text[startFence.upperBound..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? JSONSerialization.jsonObject(with: Data(fenced.utf8))) != nil {
                return fenced
            }
        }

        // 3. Scan for balanced JSON object containing weather keys
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
                    return candidate
                }
                searchIndex = text.index(after: openBrace)
            } else {
                break
            }
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
