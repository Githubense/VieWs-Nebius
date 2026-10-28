import Foundation

/// Template configuration for Nebius Token Factory.
///
/// Copy this file to `Secrets.swift` and insert your credentials,
/// or provide them via environment variables:
///   • `NEBIUS_API_KEY`: Token Factory API key
///   • `NEBIUS_PROXY_URL`: Nebius Serverless Endpoints URL (if using proxy)
///
/// See README.md for setup instructions.
enum Secrets {
    /// Token Factory API key (https://tokenfactory.nebius.com → API keys).
    /// Leave as placeholder if using `nebiusProxyURL`.
    static let nebiusAPIKey = "YOUR_NEBIUS_API_KEY"

    /// Verified NVIDIA Nemotron model ID on Token Factory.
    static let nebiusModel = "nvidia/Nemotron-3_5-Lightning"

    /// OpenAI-compatible base URL of Nebius Token Factory.
    static let nebiusBaseURL = "https://api.tokenfactory.eu-north1.nebius.com/v1/"

    /// Deployed Nebius Serverless Endpoints proxy URL (e.g. "https://<endpoint-id>.nebius.cloud").
    /// When set to a valid URL, the app routes requests to the proxy without requiring a client-side API key.
    /// Leave empty to use direct Token Factory API key authentication.
    static let nebiusProxyURL = ""

    /// How to ask for JSON: "json_schema" (strict), "json_object", or "none" (prompt-only).
    /// The client automatically downgrades one step on an HTTP 400.
    static let responseMode = "json_object"
}
