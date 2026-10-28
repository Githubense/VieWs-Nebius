# Credits & Attributions

## AI Inference & Platform
- **Nebius Token Factory & Serverless Endpoints:** Provided by [Nebius AI Cloud](https://nebius.com) for real-time model hosting, API routing, and serverless container endpoints.
- **NVIDIA Nemotron:** Open atmosphere and parameter generation models developed by NVIDIA, hosted on Nebius Token Factory.

## Audio & Sound Design
- **Procedural Sound Engine:** 5-layer real-time DSP audio synthesizer for rain, wind, fog, snow, and singing bowl sparkle textures authored in Swift using `AVAudioEngine` and `AVAudioSourceNode`.
- **Thunder Sound Effect:** 
  - Asset: "Thunder sound effect 1" by **humanoide9000**
  - Source: [Freesound #441837](https://freesound.org/people/humanoide9000/sounds/441837/)
  - License: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)
  - Attribution note: Used for lightning thunder strikes in VieWs. A procedural sub-bass / filtered-noise synthesis fallback is also included in `AudioEngineService.swift` when the audio file is absent.

## Visual Design & Particle Physics
- **Weather Atmosphere Particles:** Authored using Apple SpriteKit emitter pipelines (`WeatherScene.swift`).
- **Color Theory & Harmonies:** Palette generation dynamically curated across Pastel, Soft, and Dark tonal families.
