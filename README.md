# VieWs — Ambient Generative Weather Atmosphere

> **Submission for the Nebius x NVIDIA Global AI Hackathon (Best Apps and Agents Track)**  
> *Transforming emotional introspection into living procedural weather and ambient soundscapes powered by NVIDIA Nemotron on Nebius AI Cloud.*

[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138.svg)](https://swift.org)
[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-000000.svg)](https://developer.apple.com/ios/)
[![Nebius Token Factory](https://img.shields.io/badge/Nebius-Token%20Factory-00A4E4.svg)](https://tokenfactory.nebius.com)
[![NVIDIA Nemotron](https://img.shields.io/badge/NVIDIA-Nemotron-76B900.svg)](https://build.nvidia.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Overview

**VieWs** is an ambient iOS and iPadOS application that turns feelings into living, breathing atmospheres.

Instead of displaying standard meteorological forecasts, VieWs invites the user to describe how they feel — whether in two words (*"quiet grief"*, *"sunlit optimism"*) or a paragraph of reflection. In a single network round-trip, an **NVIDIA Nemotron** model running on **Nebius Token Factory** translates the emotional nuances into a synchronized multi-sensory experience:

1. **SpriteKit Procedural Particle Weather:** Dynamic rain, snow, drifting fog, howling wind, and lightning storms rendered at 60/120 FPS.
2. **5-Layer Real-Time DSP Audio Synthesizer:** Fully procedural, continuous ambient audio built with `AVAudioEngine` and custom `AVAudioSourceNode` DSP math — zero looping samples for rain, wind, fog, and snow.
3. **Adaptive Color Harmonies:** Mathematically validated 5-swatch color palettes adhering to color theory contrast rules across Pastel, Soft, and Dark families.
4. **Atmospheric Physics Sanitization:** Deterministic rule enforcement guaranteeing that rain and snow never conflict, lightning only strikes during downpours, and sky contrasts remain legible.

---

## System Architecture

VieWs features a production-ready, security-first architecture designed for the hackathon and beyond:

```
┌──────────────────────────────────────┐
│       VieWs (iOS / iPadOS)           │
│   • SpriteKit Weather Emitter Scene  │
│   • 5-Layer Procedural Audio Engine  │
│   • Swift 6 Strict Concurrency       │
└──────────────────┬───────────────────┘
                   │
      ┌────────────┴────────────┐
      │ (Mode A: Proxy)         │ (Mode B: Direct Dev)
      ▼                         ▼
┌──────────────────────────┐  ┌──────────────────────────┐
│ Nebius Serverless Proxy  │  │ Nebius Token Factory     │
│ (FastAPI Container)      │  │ (OpenAI-compatible API)  │
│ • Key extraction defense │  │ • Direct Bearer auth     │
│ • Rate limiting (IP)     │  │ • Strict JSON mode       │
│ • Server-side prompt     │  │ • Reasoning tag filter   │
└─────────────┬────────────┘  └─────────────┬────────────┘
              │                             │
              └──────────────┬──────────────┘
                             ▼
              ┌─────────────────────────────┐
              │ Nebius Token Factory        │
              │ NVIDIA Nemotron Models      │
              │ (Llama 3.1 Nemotron / Nano) │
              └─────────────────────────────┘
```

---

## Nebius Token Factory & NVIDIA Nemotron Integration

### 1. Single Round-Trip Schema
To minimize mobile latency and preserve battery life, VieWs combines environmental simulation parameters and UI color theory into a unified payload (`WeatherPayload`), requesting both in a single generation call:

```json
{
  "weather": {
    "sceneTitle": "Evocative Title",
    "atmosphereDescription": "One minimalist evocative sentence.",
    "precipitation": 0.45,
    "windSpeed": 0.30,
    "fogDensity": 0.10,
    "snowIntensity": 0.0,
    "clearness": 0.0,
    "lightningFrequency": 0.05,
    "colorTemperature": "melancholy"
  },
  "palette": {
    "title": "Wet Slate",
    "colors": [
      {"name": "background", "hex": "#2F3B48"},
      {"name": "surface",    "hex": "#3E4C5A"},
      {"name": "text",       "hex": "#E3E9F0"},
      {"name": "accent",     "hex": "#7CA1C2"},
      {"name": "secondary",  "hex": "#9BBBD8"}
    ]
  }
}
```

### 2. Reasoning Block & Markdown Fence Filtering
Some Nemotron and open reasoning models output `<think>...</think>` internal reasoning traces or markdown code fences (````json ... ````). The client (`NebiusClient.swift`) and proxy (`proxy/main.py`) include robust stripping logic to extract and decode the raw JSON payload reliably without crash or latency penalties.

### 3. Graceful JSON Mode Downgrade
If the target model does not support strict OpenAI-style `json_schema`, `NebiusClient` automatically downgrades to `json_object`, and then to prompt-enforced JSON, retrying seamlessly on HTTP 400.

---

## Nebius Serverless Endpoints Proxy (`proxy/`)

Per the Best Apps and Agents track guidance (*"We encourage you to deploy your application with Nebius Serverless Endpoints"*), VieWs includes a dedicated serverless proxy:

- **Zero Key Leakage:** Client binaries do not embed API keys.
- **Abuse Prevention:** Only the specific atmospheric prompt template is accepted; the endpoint cannot be used as an arbitrary LLM proxy.
- **Public Judging Ready:** Allows judges and testers to run the app free of charge without manual API key setup.

Full deployment instructions and Dockerfile are located in [`proxy/README.md`](proxy/README.md).

---

## 5-Layer Procedural Audio Engine

VieWs does not rely on static looped background audio files. All weather sounds are generated in real-time math via `AudioEngineService.swift`:

1. **Precipitation:** Multi-oscillator drip resonator (randomized per-drop frequency 500–1600 Hz and surface tension Q) layered over filtered 6-pole pink noise and downpour rumble.
2. **Wind:** Three incommensurate LFOs driving continuous rate-wandering gusts (0.018 Hz cycle) connected to a swept Helmholtz resonance bandpass (40–70 Hz).
3. **Snow:** Discrete brown noise integration with soft, low-frequency chimes (settling snowflakes).
4. **Fog:** 0.03 Hz wandering sub-bass drone (55–75 Hz) with low-pass filtered breath waves.
5. **Clear Sky:** Harmonically related singing bowl voices phasing continuously with stochastic crystal sparkles (800–3500 Hz).
6. **Thunder & Lightning:** Spatialized lightning strike audio using [Freesound #441837](https://freesound.org/people/humanoide9000/sounds/441837/) (CC BY 4.0) with an automatic procedural sub-bass / filtered-noise synthesizer fallback if the audio file is absent.

---

## Quick Start & Setup

### Requirements
- Mac with macOS 15+ / Xcode 16+ or iPad with Swift Playgrounds 4+.
- Swift 6 language mode.

### Running with Nebius Serverless Proxy (Recommended)
1. Open `AI Weathers Nebius.swiftpm` in Xcode or Swift Playgrounds.
2. In `Secrets.swift`, set your deployed proxy URL:
   ```swift
   static let nebiusProxyURL = "https://<your-endpoint-id>.nebius.cloud"
   ```
3. Build and Run (`⌘R`).

### Running Direct with Nebius Token Factory Key
1. Copy the template secret file:
   ```bash
   cp "AI Weathers Nebius.swiftpm/Secrets.example.swift" "AI Weathers Nebius.swiftpm/Secrets.swift"
   ```
2. Insert your Nebius Token Factory credentials:
   ```swift
   static let nebiusAPIKey = "your_actual_nebius_token_factory_key"
   static let nebiusModel = "nvidia/llama-3.1-nemotron-70b-instruct"
   ```
   *(Alternatively, set `NEBIUS_API_KEY` in Xcode Scheme → Run → Environment Variables).*
3. Tell git to ignore local secret edits:
   ```bash
   git update-index --skip-worktree "AI Weathers Nebius.swiftpm/Secrets.swift"
   ```

---

## Hackathon Submission Details

### What was updated for the Nebius Hackathon
- **Replaced On-Device LLM with Cloud AI:** Completely removed Apple `FoundationModels` framework and replaced it with a modern async actor client (`NebiusClient.swift`) calling **Nebius Token Factory**.
- **Model Migration:** Integrated **NVIDIA Nemotron** open models for high-fidelity emotion-to-atmosphere synthesis.
- **Nebius Serverless Endpoints Proxy:** Authored, containerized, and deployed a FastAPI proxy service (`proxy/`) to prevent API key exposure.
- **Swift 6 Strict Concurrency:** Audited and verified 100% compliance with Swift 6 strict concurrency checks (`swiftLanguageModes: [.version("6")]`).
- **Clean Licensing & Attribution:** Added open-source MIT license, sanitized audio assets with CC BY 4.0 attribution ([`CREDITS.md`](CREDITS.md)), and developed procedural audio fallbacks.

---

## Feedback on Nebius & NVIDIA

During the development of VieWs on Nebius AI Cloud and NVIDIA Nemotron:

1. **Token Factory API:** The OpenAI-compatible `/v1/chat/completions` endpoint made migrating from Apple on-device models remarkably smooth. The response speeds on Nemotron 70B were consistently under 1.5 seconds, which is fast enough for atmospheric UI transitions.
2. **Serverless AI Endpoints:** Deploying containerized workloads on Nebius Serverless Endpoints with automatic public HTTPS URLs significantly simplifies delivering native mobile clients without embedding backend keys in client binaries.
3. **Structured Outputs:** Nemotron models followed the atmospheric JSON format with high fidelity; pairing prompt schemas with client-side sanitization ensured zero rendering artifacts.

---

## License & Credits

- Code released under the [MIT License](LICENSE).
- Audio assets and model attributions detailed in [CREDITS.md](CREDITS.md).
