# VieWs – Copilot Instructions

## Project Overview
VieWs is an iOS 26+ Swift Playgrounds app (`.swiftpm`) mapping emotional text to a synchronized atmospheric experience. An on-device LLM generates a `WeatherState`, which simultaneously drives procedural audio synthesis, five SpriteKit emitters, and SwiftUI theme colors.

## Architecture: One AI Response, Five Output Layers
```
User emotion text (typed or spoken via SpeechService)
      │
  AIService (FoundationModels / LanguageModelSession)
      │  generates WeatherState (@Generable structured output)
      ▼
ContentView.onChange(of: sceneTitle)
  ├── AudioEngineService.shared.applyWeatherState(_:)  → rain + wind + thunder synthesis
  ├── WeatherScene.applyWeatherState(_:)               → rain/snow/fog/golden/flash emitters
  └── Theme.backgroundColor(for: colorTemperature)     → SwiftUI background (via @Observable)
```

## Key Files
- [WeatherState.swift](../WeatherState.swift) — central data model; **all** output layers driven exclusively by its 10 properties
- [AIService.swift](../AIService.swift) — `@MainActor` singleton; owns `LanguageModelSession`, produces `WeatherState`
- [AudioEngineService.swift](../AudioEngineService.swift) — `@Observable` singleton; real-time DSP via `AVAudioSourceNode` (rain, wind, thunder)
- [WeatherScene.swift](../WeatherScene.swift) — `SKScene`; five `SKEmitterNode`s + lightning `SKSpriteNode`, all programmatic
- [SpeechService.swift](../SpeechService.swift) — `@Observable @MainActor` singleton; `SFSpeechRecognizer` with 2-second silence auto-submit
- [Theme.swift](../Theme.swift) — static struct; all colors (including `goldenAccent`, `hintColor(for:)`) and fonts

## WeatherState Properties (10 total)
| Property | Type | Drives |
|---|---|---|
| `sceneTitle` | `String` | UI title; also the `onChange` trigger |
| `atmosphereDescription` | `String` | UI subtitle (10–15 word prose sentence) |
| `precipitation` | `Double` 0–1 | Rain audio (pink noise) + rain emitter birth rate |
| `windSpeed` | `Double` 0–1 | Wind audio (white noise + LFO EQ) + rain/snow tilt |
| `fogDensity` | `Double` 0–1 | Fog emitter birth rate + alpha |
| `snowIntensity` | `Double` 0–1 | Snow emitter birth rate |
| `clearness` | `Double` 0–1 | Golden motes emitter; silences audio when high + no other activity |
| `lightningFrequency` | `Double` 0–1 | Stochastic thunder bursts + screen flash |
| `colorTemperature` | `String` | `@Guide(.anyOf(["warm","cool","neutral","melancholy","golden"]))` — background + particle tints |
| `isInteractive` | `Bool` | Gates touch-repulsor field in `WeatherScene` |

## Critical Patterns

### Structured LLM Output
`WeatherState` uses `@Generable`. `@Guide` constrains string fields to a fixed set:
```swift
@Guide(description: "...", .anyOf(["warm", "cool", "neutral", "melancholy", "golden"]))
var colorTemperature: String
```
Call with `session.respond(to: emotion, generating: WeatherState.self)` — never parse free-form text.

### Observable Singletons (not EnvironmentObject)
Services are `@Observable` singletons accessed via `.shared`. In views, always declare with `@State`:
```swift
@State private var aiService = AIService.shared
```
Do **not** use `@ObservableObject`, `@StateObject`, or `@EnvironmentObject`.

### Swift 6 Concurrency
- `AIService` and `SpeechService` are `@MainActor` — all property mutations are automatically main-thread.
- `AudioEngineService` is `final @unchecked Sendable` — `AVAudioSourceNode` callbacks run on the real-time audio thread. Mutate only `target*` properties via `applyWeatherState(_:)` or `reset()`.
- `SpeechService` recognition callbacks use `Task { @MainActor in ... }` to hop back to the main actor.

### Smooth Parameter Transitions (lerp convention)
Both audio and visual layers interpolate per-frame. **Always set `target*`; never write `current*` from outside the engine.**
```swift
let lerpFactor: Double = 0.005   // audio (per audio buffer)
let lerpFactor: Double = 0.02    // visual (per SpriteKit update)
currentValue += (targetValue - currentValue) * lerpFactor
```

### Deferred Scene Setup (Bug Fix)
Emitters in `WeatherScene` are created lazily on the first `update()` call where `size.width > 0`, not in `didMove(to:)`, because `ContentView.onAppear` sets `scene.size` after `didMove` fires. Guard: `guard !isSetUp, size.width > 0`.

### Silence Gate
`AudioEngineService` short-circuits its render callbacks (outputs zeros) when `currentPrecipitation < 0.03` or `currentWindSpeed < 0.03`. When total atmospheric activity is low and `clearness > 0.3`, `targetMasterVolume` fades to `0.08` via a lerped `mixerNode.outputVolume`.

### Audio Layers
- **Rain**: Paul Kellet 7-coefficient pink noise filter on white noise, scaled by `currentPrecipitation`
- **Wind**: white noise → `AVAudioUnitEQ` (low-pass), cutoff modulated by a 60 Hz LFO on the main thread
- **Thunder**: noise-crack + sine-sweep (60→30 Hz) burst, routed through `AVAudioUnitReverb`. Stochastic `Timer` on main thread sets `thunderTrigger = true`; render callback consumes it

### FoundationModels Availability
`SystemLanguageModel.default.availability` must be checked before creating a session. Always provide a hardcoded fallback `WeatherState` for devices without Apple Intelligence.

### Speech Input Privacy Keys
`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` **cannot** be added to the auto-generated `Package.swift`. In Swift Playgrounds on iPad the host app covers both. When exporting to Xcode, add both keys to the target's `Info.plist`.  

## ContentView UI States
1. **Input** — underline-style `TextField` + mic `Button` (if `SpeechService.isAvailable`); hint text "return to compose"
2. **Loading** — `ProgressView`
3. **Result** — tappable `sceneTitle` (tap → Mode A re-prompt) + `atmosphereDescription` subtitle; `←` back button (top-left, Mode B re-prompt)
4. **Title editing** — `TextField` pre-filled with `sceneTitle` in `titleFont`; submit generates new weather

## Platform & Tooling
- **Minimum deployment: iOS 26.0** — FoundationModels, `LanguageModelSession` are iOS 26-only.
- **Swift 6 language mode** — strict concurrency enforced; avoid `nonisolated(unsafe)` except in render callbacks.
- Opened/run via **Swift Playgrounds 5** or **Xcode 26+**. `Package.swift` is auto-generated — do not edit.
- No unit test targets, no asset catalogs, no storyboards, no `.sks` emitter files — everything is code-only.

