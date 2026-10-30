import Foundation

/// Configuration for Nebius Token Factory and Tavily AI Search.
///
/// ⚠️ Insert your API keys below before running:
///   • Nebius Token Factory: https://tokenfactory.nebius.com
///   • Tavily AI Search:     https://tavily.com
///
/// To prevent Git from tracking your local key edits, run once in terminal:
///     git update-index --skip-worktree "AI Weathers Nebius.swiftpm/Secrets.swift"
enum Secrets {
    /// Token Factory API key (https://tokenfactory.nebius.com → API keys).
    static let nebiusAPIKey = "YOUR_NEBIUS_API_KEY"

    /// NVIDIA Nemotron model ID on Token Factory.
    static let nebiusModel = "nvidia/Nemotron-3_5-Lightning"

    /// OpenAI-compatible base URL of Nebius Token Factory.
    static let nebiusBaseURL = "https://api.tokenfactory.eu-north1.nebius.com/v1/"

    /// Tavily AI Search API key for real-time web atmospheric grounding (https://tavily.com).
    static let tavilyAPIKey = "YOUR_TAVILY_API_KEY"

    /// Response format: "json_object" strictly enforces valid JSON token generation.
    static let responseMode = "json_object"
}
