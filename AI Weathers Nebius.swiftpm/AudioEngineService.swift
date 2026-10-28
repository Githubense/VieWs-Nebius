import Foundation
import AVFoundation
import CoreAudio

// MARK: - Helpers

/// Attempt a hermite-style smooth step for crossfading.
private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

@Observable
final class AudioEngineService: @unchecked Sendable {
    static let shared = AudioEngineService()

    private var engine = AVAudioEngine()
    private var mixerNode: AVAudioMixerNode!
    private let sampleRate: Double = 44100
    private let format: AVAudioFormat

    // ──────────────────────────────────────────────────────────────────
    // MARK: Rain – 3 crossfaded layers
    // ──────────────────────────────────────────────────────────────────
    private var rainNode: AVAudioSourceNode!
    private var currentPrecipitation: Double = 0
    private var targetPrecipitation:  Double = 0
    // Paul Kellet pink noise state
    private var pinkB = [Float](repeating: 0, count: 7)
    // Drip resonator state — frequency and Q randomised per drop
    private var dripResonatorY1: Float = 0
    private var dripResonatorY2: Float = 0
    private var dripTimer: Float = 0
    private var dripImpulse: Float = 0
    private var dripFreq: Float = 800         // random per drip: 500–1600 Hz
    private var dripQ: Float = 12             // random per drip: 5–20
    // Slow amplitude breath (0.03–0.07 Hz) — rain naturally waxes and wanes
    private var rainBreathPhase: Float = 0
    private var rainBreathRate: Float = 0.05

    // ──────────────────────────────────────────────────────────────────
    // MARK: Wind – broadband noise + gusting LFO + Helmholtz resonance
    // ──────────────────────────────────────────────────────────────────
    private var windNode: AVAudioSourceNode!
    private var eqNode: AVAudioUnitEQ!
    private var currentWindSpeed: Double = 0
    private var targetWindSpeed:  Double = 0
    // Slow LFO (sustained gusts) + fast LFO (micro-gusts)
    private var gustSlowPhase: Float = 0
    private var gustFastPhase: Float = 0
    // Rate-wander oscillator — slowly shifts the slow-gust period so gusts
    // never recur at a fixed interval. Advances at ~0.018 Hz.
    private var gustRateWanderPhase: Float = 0
    // Third incommensurate pressure-surge oscillator (~0.09 Hz).
    // Its ratio to the slow rate is never rational so the combined envelope
    // takes minutes to meaningfully repeat.
    private var gustSurgePhase: Float = 0
    // Stochastic nudge: every 3–8 s a random phase offset disrupts the slow LFO.
    private var gustJitterTimer: Float = 0
    // Independent EQ phase: filter cutoff sweeps at a different rate than
    // amplitude so tonal colour and loudness don't lock-step.
    private var eqFilterPhase: Float = 0
    // Helmholtz hollow-howl oscillator (40–70 Hz) with slow frequency drift
    private var helmholtzPhase: Float = 0
    private var helmDrift: Float = 0          // current drift offset in Hz (±8 Hz wander)
    private var helmDriftPhase: Float = 0     // 0.04–0.08 Hz drift LFO
    // Random turbulence spikes: occasional noise surges
    private var turbTimer: Float = 0          // samples until next spike
    private var turbEnv: Float = 0            // current spike envelope

    // ──────────────────────────────────────────────────────────────────
    // MARK: Snow – brown noise bed + rare soft low-freq chimes
    // Snow absorbs sound; the character is muffled, soft, almost silent.
    // Brown noise (integrated white) provides the hush bed.
    // Occasional 200–700 Hz gentle ring-downs simulate settling flakes.
    // ──────────────────────────────────────────────────────────────────
    private var snowNode: AVAudioSourceNode!
    private var snowEQ: AVAudioUnitEQ!           // low-pass at 900 Hz to keep it muffled
    private var currentSnowIntensity: Double = 0
    private var targetSnowIntensity:  Double = 0
    // Brown noise integrator
    private var brownAccum: Float = 0
    // 6-voice soft chime pool (200–700 Hz, 15–40 ms decay)
    private let chimeVoices = 6
    private var chimePhase:    [Float] = [Float](repeating: 0, count: 6)
    private var chimeEnv:      [Float] = [Float](repeating: 0, count: 6)
    private var chimeDecay:    [Float] = [Float](repeating: 0.999, count: 6)
    private var chimeFreq:     [Float] = [Float](repeating: 400, count: 6)
    private var chimeTimer:    [Float] = [Float](repeating: 0, count: 6)

    // ──────────────────────────────────────────────────────────────────
    // MARK: Fog – muffled brown-noise bed + sub-bass tonal drift
    // Fog deadens the air completely: no high frequencies survive.
    // Two layers:
    //   • Brown noise low-passed at 250 Hz — the dead, smothered air
    //   • Slowly drifting sub-bass sine (55–75 Hz) — the barely-felt
    //     tonal mass that dense fog seems to carry
    // Both swell on a very slow breath LFO (0.03–0.08 Hz) so the
    // soundscape gently breathes like a fog bank rolling in and out.
    // ──────────────────────────────────────────────────────────────────
    private var fogNode: AVAudioSourceNode!
    private var fogEQ: AVAudioUnitEQ!            // low-pass at 250 Hz + low-shelf boost
    private var currentFogDensity: Double = 0
    private var targetFogDensity:  Double = 0
    private var fogBrownAccum: Float = 0
    private var fogBreathPhase: Float = 0
    private var fogBreathRate:  Float = 0.05     // 0.03–0.08 Hz — very slow swell
    private var fogDronePhase:  Float = 0        // sub-bass sine oscillator
    private var fogDroneDriftPhase: Float = 0    // 0.02–0.04 Hz frequency wander

    // ──────────────────────────────────────────────────────────────────
    // MARK: Thunder – 4-voice pool so rapid strikes overlap naturally
    // Each voice: playerNode → pitchNode → reverbNode → mixer.
    // Strike character (close crack vs. distant rumble) is driven by
    // targetLightningFrequency so intense storms sound different from
    // far-off storms.
    // ──────────────────────────────────────────────────────────────────
    private let thunderPoolSize = 4
    private var thunderPlayers: [AVAudioPlayerNode] = []
    private var thunderPitches: [AVAudioUnitTimePitch] = []
    private var thunderReverbs: [AVAudioUnitReverb] = []
    private var thunderPoolIndex: Int = 0
    private var thunderBuffer: AVAudioPCMBuffer?           // preloaded from thunder.mp3
    private var targetLightningFrequency: Double = 0

    // ──────────────────────────────────────────────────────────────────
    // MARK: Clearness – singing bowl harmonics + crystal sparkles
    // High clearness = mystical golden stillness. Three layers:
    //   • 4-voice singing bowl: harmonically-related sines (A3–E5)
    //     each on its own incommensurate slow-breath LFO — natural
    //     acoustic beating like rubbing a crystal glass
    //   • 8-voice crystal sparkle pool: stochastic 800–3500 Hz bell
    //     ring-downs (200–900 ms decay) — fairy-dust transients
    //   • Sub-harmonic anchor: ~55 Hz barely-felt ground presence
    // ──────────────────────────────────────────────────────────────────
    private var clearnessNode: AVAudioSourceNode!
    private var currentClearness: Double = 0
    private var targetClearness:  Double = 0
    // Singing bowl: 4 harmonically-related sines
    private let bowlCount = 4
    private var bowlPhase:       [Float] = [0, 0, 0, 0]
    private let bowlFreq:        [Float] = [220.0, 329.6, 440.0, 659.3]  // A3 E4 A4 E5
    private var bowlBreathPhase: [Float] = [0, 0, 0, 0]
    private let bowlBreathRate:  [Float] = [0.023, 0.031, 0.019, 0.027]  // incommensurate
    // Crystal sparkle pool: 8 voices
    private let sparkleVoices = 8
    private var sparklePhase: [Float] = [Float](repeating: 0,     count: 8)
    private var sparkleEnv:   [Float] = [Float](repeating: 0,     count: 8)
    private var sparkleDecay: [Float] = [Float](repeating: 0.999, count: 8)
    private var sparkleFreq:  [Float] = [Float](repeating: 1200,  count: 8)
    private var sparkleTimer: [Float] = [Float](repeating: 0,     count: 8)
    // Sub-harmonic anchor
    private var subHarmPhase: Float = 0

    // ──────────────────────────────────────────────────────────────────
    // MARK: Master volume (silence gate)
    // ──────────────────────────────────────────────────────────────────
    private var currentMasterVolume: Float = 1.0
    private var targetMasterVolume:  Float = 1.0
    /// When true, updateMasterVolume() uses a faster lerp (~2 s fade)
    /// instead of the normal slow tracking lerp.

    // ──────────────────────────────────────────────────────────────────
    // MARK: Init
    // ──────────────────────────────────────────────────────────────────

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        setupEngine()
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        mixerNode = engine.mainMixerNode
        let sr = Float(sampleRate)

        // ━━━ Rain Node ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        rainNode = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            let lerp = 0.005
            self.currentPrecipitation += (self.targetPrecipitation - self.currentPrecipitation) * lerp
            let p = self.currentPrecipitation

            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)

            guard p > 0.015 else {
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    for i in 0..<Int(frameCount) { ptr[i] = 0 }
                }
                return noErr
            }

            // Crossfade weights across 3 layers
            let dripsW    = Float(1.0 - smoothstep(0.0, 0.35, p))
            let steadyW   = Float(smoothstep(0.15, 0.4, p) * (1.0 - smoothstep(0.65, 0.9, p)))
            let downpourW = Float(smoothstep(0.55, 0.85, p))

            for frame in 0..<Int(frameCount) {
                // --- Layer A: Drip resonator (sparse stochastic impulses) ---
                self.dripTimer -= 1
                if self.dripTimer <= 0 {
                    let baseInterval = Float(max(0.005, 0.18 - p * 0.5))
                    let jitter = Float.random(in: 0.5...1.5)
                    self.dripTimer    = baseInterval * jitter * sr
                    self.dripImpulse  = Float.random(in: 0.3...1.0)
                    // Randomise resonator character per drop: freq = drop size, Q = surface tension
                    self.dripFreq     = Float.random(in: 500...1600)
                    self.dripQ        = Float.random(in: 5...20)
                    // Occasionally re-randomise breath rate for natural variation
                    if Float.random(in: 0...1) < 0.1 {
                        self.rainBreathRate = Float.random(in: 0.03...0.07)
                    }
                } else {
                    self.dripImpulse *= 0.92
                }
                // 2nd-order bandpass resonator with per-drip freq and Q
                let omega = 2.0 * Float.pi * self.dripFreq / sr
                let alpha = sin(omega) / (2.0 * self.dripQ)
                let a0 = 1.0 + alpha
                let b0 = alpha / a0
                let b2 = -alpha / a0
                let a1 = (-2.0 * cos(omega)) / a0
                let a2 = (1.0 - alpha) / a0
                let dripOut = b0 * self.dripImpulse + b2 * self.dripResonatorY2
                              - a1 * self.dripResonatorY1 - a2 * self.dripResonatorY2
                self.dripResonatorY2 = self.dripResonatorY1
                self.dripResonatorY1 = dripOut

                // --- Layer B: Steady pink noise ---
                let white = Float.random(in: -1.0...1.0)
                self.pinkB[0] = 0.99886 * self.pinkB[0] + white * 0.0555179
                self.pinkB[1] = 0.99332 * self.pinkB[1] + white * 0.0750759
                self.pinkB[2] = 0.96900 * self.pinkB[2] + white * 0.1538520
                self.pinkB[3] = 0.86650 * self.pinkB[3] + white * 0.3104856
                self.pinkB[4] = 0.55000 * self.pinkB[4] + white * 0.5329522
                self.pinkB[5] = -0.7616 * self.pinkB[5] - white * 0.0168980
                let pink = (self.pinkB[0] + self.pinkB[1] + self.pinkB[2]
                          + self.pinkB[3] + self.pinkB[4] + self.pinkB[5]
                          + self.pinkB[6] + white * 0.5362) * 0.11
                self.pinkB[6] = white * 0.115926

                // --- Layer C: Downpour broadband ---
                let downpourSample = pink + Float.random(in: -0.04...0.04)

                // --- Slow breath: intensity naturally waxes/wanes (±20%) ---
                self.rainBreathPhase += self.rainBreathRate / sr
                if self.rainBreathPhase > 1.0 { self.rainBreathPhase -= 1.0 }
                let breath = 0.80 + 0.20 * (sin(self.rainBreathPhase * 2.0 * .pi) + 1.0) * 0.5

                // --- Mix ---
                let rainSample = (dripOut * dripsW * 0.35
                               + pink * steadyW * 0.18
                               + downpourSample * downpourW * 0.22) * breath

                let finalRain = rainSample * Float(p)
                for buf in ablPtr {
                    UnsafeMutableBufferPointer<Float>(buf)[frame] = finalRain
                }
            }
            return noErr
        }

        // ━━━ Wind Node ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        windNode = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            let lerp = 0.005
            self.currentWindSpeed += (self.targetWindSpeed - self.currentWindSpeed) * lerp
            let w = self.currentWindSpeed

            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            guard w > 0.015 else {
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    for i in 0..<Int(frameCount) { ptr[i] = 0 }
                }
                return noErr
            }

            // Power curve: makes soft wind much quieter while keeping storms loud.
            // At w=0.2 → amp≈4%;  w=0.5 → amp≈29%;  w=1.0 → amp=100%
            let windPower = Float(pow(w, 1.8))

            // Fast micro-gust rate (constant per buffer; fine resolution unneeded)
            let fastRate = Float(1.5 + w * 2.5)       // 1.5–4 Hz micro-gusts
            // Helmholtz resonance frequency (hollow howl): 40–70 Hz
            let helmFreq = Float(40.0 + w * 30.0)

            for frame in 0..<Int(frameCount) {
                // ── Rate-wander: drift the slow gust period continuously ──────
                // Advances at 0.018 Hz → full wander cycle takes ~55 s.
                // Modulates slowRate by ±0.12 Hz so the gust interval is never fixed.
                self.gustRateWanderPhase += 0.018 / sr
                if self.gustRateWanderPhase > 1.0 { self.gustRateWanderPhase -= 1.0 }
                let wanderedSlowRate = Float(0.20 + w * 0.28)
                    + sin(self.gustRateWanderPhase * 2.0 * .pi) * 0.12

                // ── Three incommensurate oscillators ─────────────────────────
                self.gustSlowPhase += max(0.06, wanderedSlowRate) / sr
                if self.gustSlowPhase > 1.0 { self.gustSlowPhase -= 1.0 }

                // Pressure-surge LFO: 0.07–0.13 Hz (irrational ratio to slow)
                self.gustSurgePhase += Float(0.07 + w * 0.06) / sr
                if self.gustSurgePhase > 1.0 { self.gustSurgePhase -= 1.0 }

                self.gustFastPhase += fastRate / sr
                if self.gustFastPhase > 1.0 { self.gustFastPhase -= 1.0 }

                // ── EQ phase advances independently for decoupled tonal sweep ─
                self.eqFilterPhase += Float(0.11 + w * 0.18) / sr
                if self.eqFilterPhase > 1.0 { self.eqFilterPhase -= 1.0 }

                let slowLFO  = (sin(self.gustSlowPhase  * 2.0 * .pi) + 1.0) * 0.5
                let surgeLFO = (sin(self.gustSurgePhase * 2.0 * .pi) + 1.0) * 0.5
                let fastLFO  = (sin(self.gustFastPhase  * 2.0 * .pi) + 1.0) * 0.5
                // Blend: slow gusts dominate; pressure surge adds weight;
                // fast shimmer adds texture. Sum stays in [0.30, 1.00].
                let gustEnvelope = 0.30 + slowLFO * 0.32 + surgeLFO * 0.22 + fastLFO * 0.16

                // ── Stochastic phase nudge ────────────────────────────────────
                // Every 3–8 s a random offset is added to the slow gust phase
                // so gusts don't arrive at mathematically predictable times.
                self.gustJitterTimer -= 1
                if self.gustJitterTimer <= 0 {
                    self.gustJitterTimer = Float.random(in: 3.0...8.0) * sr
                    self.gustSlowPhase += Float.random(in: 0.0...0.4)
                    if self.gustSlowPhase > 1.0 { self.gustSlowPhase -= 1.0 }
                }

                // Turbulence spikes: only appear at moderate+ wind (≥0.45) so soft
                // breezes stay smooth; storms get unpredictable bursts.
                self.turbTimer -= 1
                if self.turbTimer <= 0 {
                    let interval = Float.random(in: 0.5...3.0) * Float(max(0.2, 1.0 - w * 0.8))
                    self.turbTimer = interval * sr
                    self.turbEnv = Float(w) > 0.45 ? Float.random(in: 0...0.40) : Float.random(in: 0...0.04)
                }
                let turbSample = Float.random(in: -1.0...1.0) * self.turbEnv * windPower * 0.18
                self.turbEnv *= 0.9985  // slow decay between spikes

                // Broadband noise shaped by gust envelope
                let noise = Float.random(in: -1.0...1.0) * gustEnvelope * windPower * 0.22

                // Helmholtz howl with slow frequency drift (±8 Hz wander)
                let driftRate = Float(0.04 + w * 0.04)   // 0.04–0.08 Hz
                self.helmDriftPhase += driftRate / sr
                if self.helmDriftPhase > 1.0 { self.helmDriftPhase -= 1.0 }
                self.helmDrift = sin(self.helmDriftPhase * 2.0 * .pi) * 8.0
                let currentHelmFreq = helmFreq + self.helmDrift
                self.helmholtzPhase += currentHelmFreq / sr * 2.0 * .pi
                if self.helmholtzPhase > 2.0 * .pi { self.helmholtzPhase -= 2.0 * .pi }
                let howl = sin(self.helmholtzPhase) * Float(w * w) * 0.08 * slowLFO

                let windSample = noise + howl + turbSample

                for buf in ablPtr {
                    UnsafeMutableBufferPointer<Float>(buf)[frame] = windSample
                }
            }
            return noErr
        }

        eqNode = AVAudioUnitEQ(numberOfBands: 1)
        eqNode.bands[0].filterType = .lowPass
        eqNode.bands[0].frequency = 400.0
        eqNode.bands[0].bypass = false

        // ━━━ Snow Node (brown noise + soft low-freq chimes) ━━━━━━━━━━
        // Brown noise = integrated white noise: very warm, muffled, soothing.
        // Chimes at 200–700 Hz fire rarely (0.2–3 s intervals) with gentle
        // 15–40 ms exponential decay — settling snowflakes, not crystals.
        // Downstream low-pass at 900 Hz keeps everything soft.
        snowNode = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            let lerp: Double = 0.005
            self.currentSnowIntensity += (self.targetSnowIntensity - self.currentSnowIntensity) * lerp
            let s = Float(self.currentSnowIntensity)

            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            guard s > 0.015 else {
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    for i in 0..<Int(frameCount) { ptr[i] = 0 }
                }
                return noErr
            }

            for frame in 0..<Int(frameCount) {
                // ── Brown noise bed: integrate white noise, very quiet ──
                // Brown noise = ∫white dt, giving 6 dB/octave low-frequency emphasis.
                // Normalise by 0.02 to prevent accumulator blowup; clamp to ±1.
                let white = Float.random(in: -1.0...1.0)
                self.brownAccum = max(-1.0, min(1.0, self.brownAccum + white * 0.02))
                let brownBed = self.brownAccum * s * 0.06

                // ── Rare soft chimes: low-freq settling transients ──
                var chimeMix: Float = 0
                for v in 0..<self.chimeVoices {
                    self.chimeTimer[v] -= 1
                    if self.chimeTimer[v] <= 0 {
                        // 200–3000 ms intervals; sparser at low intensity
                        let baseMs = Float(max(200, 3000 - Double(s) * 2800))
                        self.chimeTimer[v] = baseMs * 0.001 * Float.random(in: 0.5...2.5) * sr
                        // Warm low-freq: 200–700 Hz (like snow settling on a surface)
                        self.chimeFreq[v] = Float.random(in: 200...700)
                        self.chimePhase[v] = 0
                        // Soft amplitude, randomised
                        self.chimeEnv[v] = s * Float.random(in: 0.03...0.08)
                        // Gentle decay: 15–40 ms
                        let decayMs = Float.random(in: 15.0...40.0)
                        let decaySamples = decayMs * 0.001 * sr
                        self.chimeDecay[v] = exp(-6.908 / decaySamples)
                    }
                    if self.chimeEnv[v] > 0.0001 {
                        self.chimePhase[v] += self.chimeFreq[v] / sr * 2.0 * .pi
                        if self.chimePhase[v] > 2.0 * .pi { self.chimePhase[v] -= 2.0 * .pi }
                        chimeMix += sin(self.chimePhase[v]) * self.chimeEnv[v]
                        self.chimeEnv[v] *= self.chimeDecay[v]
                    }
                }

                let snowSample = brownBed + chimeMix
                for buf in ablPtr {
                    UnsafeMutableBufferPointer<Float>(buf)[frame] = snowSample
                }
            }
            return noErr
        }

        // Low-pass at 900 Hz: keeps the snow sound muffled and warm
        snowEQ = AVAudioUnitEQ(numberOfBands: 1)
        snowEQ.bands[0].filterType = .lowPass
        snowEQ.bands[0].frequency = 900.0
        snowEQ.bands[0].bypass = false

        // ━━━ Fog Node (muffled brown noise + sub-bass drone) ━━━━━━━━━
        fogNode = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            let lerp: Double = 0.005
            self.currentFogDensity += (self.targetFogDensity - self.currentFogDensity) * lerp
            let f = Float(self.currentFogDensity)

            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            guard f > 0.015 else {
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    for i in 0..<Int(frameCount) { ptr[i] = 0 }
                }
                return noErr
            }

            for frame in 0..<Int(frameCount) {
                // Very slow breath envelope — fog naturally rolls in waves
                self.fogBreathPhase += self.fogBreathRate / sr
                if self.fogBreathPhase > 1.0 { self.fogBreathPhase -= 1.0 }
                let breath = 0.72 + 0.28 * sin(self.fogBreathPhase * 2.0 * .pi)

                // Muffled brown noise bed — integrated white, no highs survive
                let white = Float.random(in: -1.0...1.0)
                self.fogBrownAccum = max(-1.0, min(1.0, self.fogBrownAccum + white * 0.02))
                let brownBed = self.fogBrownAccum * f * 0.09 * breath

                // Sub-bass tonal drift (55–75 Hz) — barely felt, not heard
                // A 0.03 Hz LFO wanders ±12 Hz so it never sounds static.
                self.fogDroneDriftPhase += 0.03 / sr
                if self.fogDroneDriftPhase > 1.0 { self.fogDroneDriftPhase -= 1.0 }
                let droneFreq = (55.0 + 20.0 * f)
                              + sin(self.fogDroneDriftPhase * 2.0 * .pi) * 12.0
                self.fogDronePhase += droneFreq / sr * 2.0 * .pi
                if self.fogDronePhase > 2.0 * .pi { self.fogDronePhase -= 2.0 * .pi }
                // f*f keeps the drone very quiet at low density, grows non-linearly
                let droneOut = sin(self.fogDronePhase) * f * f * 0.05 * breath

                let fogSample = brownBed + droneOut
                for buf in ablPtr {
                    UnsafeMutableBufferPointer<Float>(buf)[frame] = fogSample
                }
            }
            return noErr
        }

        // ━━━ Clearness Node (singing bowls + crystal sparkles + sub-bass) ━━
        clearnessNode = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self else { return noErr }
            let lerp: Double = 0.005
            self.currentClearness += (self.targetClearness - self.currentClearness) * lerp
            let c = Float(self.currentClearness)

            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            guard c > 0.015 else {
                for buf in ablPtr {
                    let ptr = UnsafeMutableBufferPointer<Float>(buf)
                    for i in 0..<Int(frameCount) { ptr[i] = 0 }
                }
                return noErr
            }

            for frame in 0..<Int(frameCount) {
                // ── Singing bowls: 4 harmonically-related voices ───────────
                // Each voice independently breathes at an incommensurate rate
                // so they phase in and out of each other like a real singing bowl.
                var bowlMix: Float = 0
                for v in 0..<self.bowlCount {
                    self.bowlBreathPhase[v] += self.bowlBreathRate[v] / sr
                    if self.bowlBreathPhase[v] > 1.0 { self.bowlBreathPhase[v] -= 1.0 }
                    // Breath stays between 0.15–0.85 so voices never fully silence
                    let breath = 0.15 + 0.70 * (sin(self.bowlBreathPhase[v] * 2.0 * .pi) + 1.0) * 0.5

                    self.bowlPhase[v] += self.bowlFreq[v] / sr * 2.0 * .pi
                    if self.bowlPhase[v] > 2.0 * .pi { self.bowlPhase[v] -= 2.0 * .pi }
                    // Higher harmonics softer: 1/(v+1) rolloff
                    let harmAmp: Float = 1.0 / Float(v + 1)
                    bowlMix += sin(self.bowlPhase[v]) * breath * harmAmp
                }
                let bowlOut = bowlMix * c * 0.038

                // ── Crystal sparkles: stochastic bell ring-downs ───────────
                var sparkleMix: Float = 0
                for v in 0..<self.sparkleVoices {
                    self.sparkleTimer[v] -= 1
                    if self.sparkleTimer[v] <= 0 {
                        // Sparser at low clearness; shimmering at high clearness
                        let baseMs = Float(max(80, 2200 - Double(c) * 1900))
                        self.sparkleTimer[v] = baseMs * 0.001 * Float.random(in: 0.25...3.0) * sr
                        // Crystal tones: 800–3500 Hz
                        self.sparkleFreq[v]  = Float.random(in: 800...3500)
                        self.sparklePhase[v] = 0
                        self.sparkleEnv[v]   = c * Float.random(in: 0.010...0.030)
                        // Ring-down: 200–900 ms
                        let decayMs = Float.random(in: 200.0...900.0)
                        let decaySamples = decayMs * 0.001 * sr
                        self.sparkleDecay[v] = exp(-6.908 / decaySamples)
                    }
                    if self.sparkleEnv[v] > 0.00008 {
                        self.sparklePhase[v] += self.sparkleFreq[v] / sr * 2.0 * .pi
                        if self.sparklePhase[v] > 2.0 * .pi { self.sparklePhase[v] -= 2.0 * .pi }
                        sparkleMix += sin(self.sparklePhase[v]) * self.sparkleEnv[v]
                        self.sparkleEnv[v] *= self.sparkleDecay[v]
                    }
                }

                // ── Sub-harmonic anchor: ~55 Hz grounding presence ─────────
                // c² keeps it barely felt at moderate clearness; full at c=1
                self.subHarmPhase += 55.0 / sr * 2.0 * .pi
                if self.subHarmPhase > 2.0 * .pi { self.subHarmPhase -= 2.0 * .pi }
                let subOut = sin(self.subHarmPhase) * c * c * 0.022

                let clearSample = bowlOut + sparkleMix + subOut
                for buf in ablPtr {
                    UnsafeMutableBufferPointer<Float>(buf)[frame] = clearSample
                }
            }
            return noErr
        }

        // LP at 250 Hz strips all presence; low-shelf +4 dB at 80 Hz adds weight
        fogEQ = AVAudioUnitEQ(numberOfBands: 2)
        fogEQ.bands[0].filterType = .lowPass
        fogEQ.bands[0].frequency  = 250.0
        fogEQ.bands[0].bypass     = false
        fogEQ.bands[1].filterType = .lowShelf
        fogEQ.bands[1].frequency  = 80.0
        fogEQ.bands[1].gain       = 4.0
        fogEQ.bands[1].bypass     = false
        // Each voice is an independent signal chain so simultaneous strikes
        // play concurrently without scheduling delays.
        for _ in 0..<thunderPoolSize {
            let player = AVAudioPlayerNode()
            let pitch  = AVAudioUnitTimePitch()
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.largeHall)
            reverb.wetDryMix = 65
            thunderPlayers.append(player)
            thunderPitches.append(pitch)
            thunderReverbs.append(reverb)
        }

        // Preload thunder.mp3 into a PCM buffer for zero-latency scheduling.
        // Swift Playgrounds .swiftpm packages embed resources inside an SPM module bundle
        // (AppModule_AppModule.bundle) nested within the main app bundle, so Bundle.main
        // alone won't find the file. We enumerate the entire bundle tree as a fallback.
        let thunderURL: URL? = {
            let exts = ["mp3", "wav", "m4a", "caf", "aiff"]
            for ext in exts {
                if let u = Bundle.main.url(forResource: "thunder", withExtension: ext) { return u }
                if let u = Bundle.main.url(forResource: "thunder", withExtension: ext, subdirectory: "Resources") { return u }
            }
            let fm = FileManager.default
            if let enumerator = fm.enumerator(
                at: Bundle.main.bundleURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    let base = fileURL.deletingPathExtension().lastPathComponent
                    let ext = fileURL.pathExtension.lowercased()
                    if base == "thunder" && exts.contains(ext) {
                        return fileURL
                    }
                }
            }
            return nil
        }()
        print("AudioEngineService ▶ thunder URL: \(thunderURL?.path ?? "NOT FOUND ✗")")
        if let url = thunderURL,
           let file = try? AVAudioFile(forReading: url) {
            let length = AVAudioFrameCount(file.length)
            if let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: length) {
                try? file.read(into: buf)
                thunderBuffer = buf
                print("AudioEngineService ▶ thunder buffer loaded — \(buf.frameLength) frames")
            }
        }
        if thunderBuffer == nil {
            print("AudioEngineService ▶ thunder audio file absent — synthesizing procedural thunder fallback")
            thunderBuffer = Self.generateProceduralThunderBuffer(format: format)
        }

        // ━━━ Connections ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        engine.attach(rainNode)
        engine.attach(windNode)
        engine.attach(eqNode)
        engine.attach(snowNode)
        engine.attach(snowEQ)
        engine.connect(rainNode, to: mixerNode, format: format)
        engine.connect(windNode,  to: eqNode,   format: format)
        engine.connect(eqNode,    to: mixerNode, format: format)
        engine.connect(snowNode,  to: snowEQ,   format: format)
        engine.connect(snowEQ,    to: mixerNode, format: format)
        engine.attach(fogNode)
        engine.attach(fogEQ)
        engine.connect(fogNode, to: fogEQ,    format: format)
        engine.connect(fogEQ,   to: mixerNode, format: format)

        engine.attach(clearnessNode)
        engine.connect(clearnessNode, to: mixerNode, format: format)

        for i in 0..<thunderPoolSize {
            engine.attach(thunderPlayers[i])
            engine.attach(thunderPitches[i])
            engine.attach(thunderReverbs[i])
            engine.connect(thunderPlayers[i], to: thunderPitches[i], format: nil)
            engine.connect(thunderPitches[i], to: thunderReverbs[i], format: nil)
            engine.connect(thunderReverbs[i], to: mixerNode,         format: nil)
        }

        // Activate audio session and start engine off the main thread to prevent UI hang risk
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
                try AVAudioSession.sharedInstance().setActive(true)
                self.engine.prepare()
                try self.engine.start()
                DispatchQueue.main.async {
                    self.thunderPlayers.forEach { $0.play() }
                }
            } catch {
                print("AudioEngineService: failed to start — \(error)")
            }
        }

        // 60 Hz timer: EQ modulation + thunder scheduling + master volume
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            self?.onMainThreadTick(dt: 1.0 / 60.0)
        }
    }

    // MARK: - Thunder playback

    /// Called by WeatherScene whenever a lightning flash is triggered.
    /// All sound properties (pitch, reverb, volume) scale continuously with
    /// targetLightningFrequency, so low values sound distant and rumbly while
    /// high values crack brightly — no hard threshold cuts.
    func triggerThunder() {
        guard let buf = thunderBuffer else {
            print("AudioEngineService ▶ triggerThunder() called but thunderBuffer is nil")
            return
        }

        let i      = thunderPoolIndex % thunderPoolSize
        thunderPoolIndex += 1

        let f      = Float(max(0, min(1, targetLightningFrequency)))  // 0–1
        let player = thunderPlayers[i]
        let pitch  = thunderPitches[i]
        let reverb = thunderReverbs[i]

        // Pitch: at f=0 → deep rumble (−800…−300 cents)
        //        at f=1 → bright crack (−100…+600 cents)
        let pitchLo = -800 + f * 700              // −800 → −100
        let pitchHi = -300 + f * 900              // −300 → +600
        pitch.pitch = Float.random(in: pitchLo...pitchHi)

        // Rate: slow at low freq, faster at high
        let rateMin = 0.72 + f * 0.28              // 0.72 → 1.00
        let rateMax = 0.88 + f * 0.37              // 0.88 → 1.25
        pitch.rate  = Float.random(in: rateMin...rateMax)

        // Reverb: very wet and spacious at low freq, drier at high
        let revMin = 78 - f * 52                   // 78 → 26
        let revMax = 94 - f * 50                   // 94 → 44
        reverb.wetDryMix = Float.random(in: revMin...revMax)

        // Volume: loud throughout; low freq is still impactful (distant thunder
        // carries far). High freq gets a slight extra bite.
        let volMin = 0.60 + f * 0.20               // 0.60 → 0.80
        let volMax = 0.80 + f * 0.20               // 0.80 → 1.00
        player.volume = Float.random(in: volMin...volMax)

        player.scheduleBuffer(buf, completionHandler: nil)
    }

    // MARK: - Main-thread tick

    private func onMainThreadTick(dt: TimeInterval) {
        updateWindEQ()
        updateMasterVolume()
    }

    private func updateWindEQ() {
        // At low wind the EQ cutoff stays very low (120 Hz) so barely any
        // high-frequency content gets through — a gentle rustle rather than
        // an aggressive whoosh. At full storm wind it opens up to 2000 Hz.
        // Uses eqFilterPhase (advanced in the render callback at an irrational
        // multiple of the gust rate) so the filter sweep is decoupled from the
        // amplitude envelope — tonal colour and loudness diverge naturally.
        let windP = Float(pow(currentWindSpeed, 1.8))
        let baseFreq: Float = 120.0
        let maxFreq: Float  = baseFreq + windP * 1880.0   // 120 → 2000 Hz
        let lfoVal = (sin(eqFilterPhase * 2.0 * .pi) + 1.0) / 2.0
        eqNode.bands[0].frequency = baseFreq + (maxFreq - baseFreq) * lfoVal
    }

    private func updateMasterVolume() {
        currentMasterVolume += (targetMasterVolume - currentMasterVolume) * 0.005
        mixerNode.outputVolume = currentMasterVolume
    }

    // MARK: - Public API

    func applyWeatherState(_ state: WeatherState) {
        targetPrecipitation = state.precipitation
        targetWindSpeed = state.windSpeed
        targetSnowIntensity = state.snowIntensity
        targetFogDensity = state.fogDensity
        targetLightningFrequency = state.lightningFrequency
        targetClearness = state.clearness

        // Gate master volume only when every channel is truly silent —
        // clearness now has its own sound so a high clearness value is
        // no longer a reason to silence the mix.
        let totalActivity = state.precipitation + state.windSpeed + state.fogDensity
                          + state.snowIntensity + state.lightningFrequency + state.clearness
        targetMasterVolume = totalActivity < 0.10 ? 0.04 : 1.0
    }

    /// Fade all layers to silence (called when returning to the input screen).
    func reset() {
        targetPrecipitation = 0
        targetWindSpeed = 0
        targetSnowIntensity = 0
        targetFogDensity = 0
        targetLightningFrequency = 0
        targetClearness = 0
        targetMasterVolume = 0.0
    }

    /// Smoothly transitions all weather layers to zero using the normal per-frame
    /// lerp — identical to receiving a WeatherState with every property at 0.
    /// Use this for scene-exit transitions (e.g. onboarding → home).
    func fadeOutAndReset() {
        targetPrecipitation = 0
        targetWindSpeed = 0
        targetSnowIntensity = 0
        targetFogDensity = 0
        targetLightningFrequency = 0
        targetClearness = 0
        targetMasterVolume = 0.04   // idle floor (totalActivity == 0)
    }

    // MARK: - Procedural Fallbacks

    /// Synthesizes a realistic thunder rumble into an `AVAudioPCMBuffer` when an external audio file is missing.
    /// Combines a sub-bass pitch sweep (65 Hz down to 25 Hz) with filtered white-noise rumble and exponential decay.
    private static func generateProceduralThunderBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100.0
        let duration: Double = 3.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let channels = Int(format.channelCount)
        guard let channelData = buffer.floatChannelData else { return nil }

        var lowpass: Float = 0.0
        var phase: Double = 0.0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = Float(exp(-t * 1.5))

            // Sub-bass sweep: 65 Hz down to 25 Hz
            let freq = max(25.0, 65.0 - t * 14.0)
            phase += 2.0 * Double.pi * freq / sampleRate
            let subBass = Float(sin(phase)) * 0.45

            // Filtered noise for crackle/rumble body
            let whiteNoise = Float.random(in: -1.0...1.0)
            lowpass += (whiteNoise - lowpass) * 0.08
            let rumble = (lowpass * 0.55 + subBass) * envelope

            for ch in 0..<channels {
                channelData[ch][frame] = max(-1.0, min(1.0, rumble))
            }
        }
        return buffer
    }
}
