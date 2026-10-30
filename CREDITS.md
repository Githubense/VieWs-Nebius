# Credits & Attributions

## AI Inference & Grounding
- **Nebius Token Factory:** High-throughput cloud inference for NVIDIA Nemotron models via OpenAI-compatible endpoints ([Nebius AI Cloud](https://nebius.com)).
- **NVIDIA Nemotron:** Open atmosphere and parameter generation model (`nvidia/Nemotron-3_5-Lightning`).
- **Tavily AI Search:** Sub-second real-world atmospheric web grounding and meteorological retrieval ([Tavily](https://tavily.com)).

## Native iOS Architecture & Sound Design
- **Procedural Sound Engine:** 5-layer real-time DSP audio synthesizer for rain, wind, fog, snow, and clear sky singing bowl textures authored in native Swift using `AVAudioEngine` and `AVAudioSourceNode`.
- **Thunder Sound Effect:** 
  - Asset: "Thunder sound effect 1" by **humanoide9000**
  - Source: [Freesound #441837](https://freesound.org/people/humanoide9000/sounds/441837/)
  - License: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)
  - Attribution note: Used for lightning strikes. A procedural sub-bass and filtered-noise synthesis fallback is included in `AudioEngineService.swift` when audio files are absent.

## Visual Design & Particle Physics
- **Weather Atmosphere Particles:** Real-time 60 FPS rain, snow, fog, and lightning simulations authored using Apple SpriteKit emitter pipelines (`WeatherScene.swift`).
- **Color Theory & Harmonies:** Procedural palette generation dynamically calculated across Warm, Cool, Neutral, Melancholy, Golden, Crimson, Dusk, Arctic, Ember, and Ash color temperatures with WCAG-compliant contrast.
