import SwiftUI
import SpriteKit

class WeatherScene: SKScene {

    // MARK: - Emitters
    private var rainEmitter: SKEmitterNode?
    private var snowEmitter: SKEmitterNode?
    private var fogEmitter: SKEmitterNode?
    private var goldenEmitter: SKEmitterNode?

    // MARK: - Lightning flash overlay
    private var flashNode: SKSpriteNode?

    // MARK: - Lerp targets & current values
    private var targetPrecipitation: Double = 0.0
    private var currentPrecipitation: Double = 0.0

    private var targetWindSpeed: Double = 0.0
    private var currentWindSpeed: Double = 0.0

    private var targetFogDensity: Double = 0.0
    private var currentFogDensity: Double = 0.0

    private var targetSnowIntensity: Double = 0.0
    private var currentSnowIntensity: Double = 0.0

    private var targetClearness: Double = 0.0
    private var currentClearness: Double = 0.0

    private var targetLightningFrequency: Double = 0.0
    private var currentLightningFrequency: Double = 0.0

    // MARK: - State
    private var colorTemperature: String = "neutral"
    /// Set by ContentView when background luminance is known (from palette or
    /// colorTemperature fallback) so per-frame contrast adjustments are accurate.
    var externalBackgroundLuminance: CGFloat? = nil {
        didSet {
            guard externalBackgroundLuminance != oldValue else { return }
            let lum = externalBackgroundLuminance.map { String(format: "%.4f", $0) } ?? "nil"
            print("[VieWs][BG] luminance → \(lum)")
        }
    }
    /// Actual background UIColor forwarded from ContentView so particle colours
    /// can be derived directly from it rather than from hardcoded fallbacks.
    var externalBackgroundColor: UIColor? = nil {
        didSet {
            guard let c = externalBackgroundColor else { return }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            var h: CGFloat = 0, s: CGFloat = 0, bri: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            c.getHue(&h, saturation: &s, brightness: &bri, alpha: &a)
            let hex = String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
            print("[VieWs][BG] color  → \(hex)  RGB(\(String(format:"%.3f",r)), \(String(format:"%.3f",g)), \(String(format:"%.3f",b)))  HSB(\(String(format:"%.3f",h)), \(String(format:"%.3f",s)), \(String(format:"%.3f",bri)))  source=\(externalBackgroundLuminance != nil ? "palette" : "fallback")")
        }
    }
    // Caches the last hex string per role to suppress per-frame duplicate logs.
    private var lastParticleHex: [ParticleRole: String] = [:]

    // Lightning strike scheduling
    private var lightningAccumulator: TimeInterval = 0
    private var lightningNextStrike: TimeInterval = 4.0

    // Deferred setup guard — emitters need a valid size
    private var isSetUp: Bool = false

    override func didMove(to view: SKView) {
        self.backgroundColor = .clear
        view.allowsTransparency = true
        // Emitter setup is deferred to the first update() when size.width > 0
    }

    /// Called by SpriteKit whenever the scene size changes (orientation flip, window resize).
    /// Re-anchors every emitter and the flash overlay to the new dimensions so
    /// particles always cover the full screen regardless of orientation.
    override func didChangeSize(_ oldSize: CGSize) {
        guard isSetUp, size.width > 0, size.height > 0 else { return }
        repositionNodes()
    }

    /// Updates emitter spawn positions and spread ranges to match the current `size`.
    private func repositionNodes() {
        if let e = rainEmitter {
            e.position = CGPoint(x: size.width / 2, y: size.height + 50)
            e.particlePositionRange = CGVector(dx: size.width * 1.5, dy: 0)
        }
        if let e = snowEmitter {
            e.position = CGPoint(x: size.width / 2, y: size.height + 30)
            e.particlePositionRange = CGVector(dx: size.width * 1.6, dy: 0)
        }
        if let e = fogEmitter {
            e.position = CGPoint(x: size.width / 2, y: size.height / 2)
            e.particlePositionRange = CGVector(dx: size.width * 1.2, dy: size.height * 0.6)
        }
        if let e = goldenEmitter {
            e.position = CGPoint(x: size.width / 2, y: size.height * 0.35)
            e.particlePositionRange = CGVector(dx: size.width * 0.9, dy: size.height * 0.3)
        }
        if let f = flashNode {
            f.size = CGSize(width: size.width * 2, height: size.height * 2)
            f.position = CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }

    // Lazily called from update() after size is known
    private func setupEmitters() {
        guard !isSetUp, size.width > 0 else { return }
        isSetUp = true

        rainEmitter   = makeRainEmitter()
        snowEmitter   = makeSnowEmitter()
        fogEmitter    = makeFogEmitter()
        goldenEmitter = makeGoldenEmitter()
        flashNode     = makeFlashNode()

        [rainEmitter, snowEmitter, fogEmitter, goldenEmitter].compactMap { $0 }.forEach { addChild($0) }
        if let flash = flashNode { addChild(flash) }
    }

    // MARK: - Emitter factories

    private func makeRainEmitter() -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = SKTexture(image: rainParticleImage())
        e.particleBirthRate = 0
        e.particleLifetime = 2.8
        e.particleLifetimeRange = 0.4
        e.particlePositionRange = CGVector(dx: size.width * 1.5, dy: 0)
        e.particleSpeed = 500
        e.particleSpeedRange = 150
        e.particleAlpha = 0.55
        e.particleAlphaRange = 0.25
        e.particleAlphaSpeed = -0.2
        e.particleScale = 1.0
        e.particleScaleRange = 0.4
        e.emissionAngle = 270 * .pi / 180
        e.particleColor = .white
        e.particleColorBlendFactor = 1.0
        e.position = CGPoint(x: size.width / 2, y: size.height + 50)
        e.fieldBitMask = 0x1        // strong repulsor only
        e.targetNode = self
        return e
    }

    private func makeSnowEmitter() -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = SKTexture(image: snowParticleImage())
        e.particleBirthRate = 0
        e.particleLifetime = 6.0
        e.particleLifetimeRange = 2.0
        e.particlePositionRange = CGVector(dx: size.width * 1.6, dy: 0)
        e.particleSpeed = 80
        e.particleSpeedRange = 40
        e.particleAlpha = 0.75
        e.particleAlphaRange = 0.2
        e.particleAlphaSpeed = -0.08
        e.particleScale = 1.0
        e.particleScaleRange = 0.6
        e.emissionAngle = 270 * .pi / 180
        e.particleColor = .white
        e.particleColorBlendFactor = 1.0
        e.position = CGPoint(x: size.width / 2, y: size.height + 30)
        e.fieldBitMask = 0x2        // soft snow repulsor only
        e.targetNode = self
        return e
    }

    private func makeFogEmitter() -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = SKTexture(image: fogParticleImage())
        e.particleBirthRate = 0
        e.particleLifetime = 18.0
        e.particleLifetimeRange = 6.0
        e.particlePositionRange = CGVector(dx: size.width * 1.2, dy: size.height * 0.6)
        e.particleSpeed = 10
        e.particleSpeedRange = 8
        e.particleAlpha = 0.0
        e.particleAlphaRange = 0.0
        e.particleAlphaSpeed = 0.0
        e.particleScale = 8.0
        e.particleScaleRange = 4.0
        e.particleScaleSpeed = 0.05
        e.emissionAngle = 0
        e.emissionAngleRange = 2.0 * .pi
        e.particleColor = UIColor(white: 0.92, alpha: 1.0)
        e.particleColorBlendFactor = 1.0
        e.position = CGPoint(x: size.width / 2, y: size.height / 2)
        e.fieldBitMask = 0x1        // strong repulsor only
        e.targetNode = self
        return e
    }

    private func makeGoldenEmitter() -> SKEmitterNode {
        let e = SKEmitterNode()
        e.particleTexture = SKTexture(image: dotParticleImage(size: CGSize(width: 4, height: 4)))
        e.particleBirthRate = 0
        e.particleLifetime = 8.0
        e.particleLifetimeRange = 3.0
        e.particlePositionRange = CGVector(dx: size.width * 0.9, dy: size.height * 0.3)
        e.particleSpeed = 20
        e.particleSpeedRange = 12
        e.particleAlpha = 0.5
        e.particleAlphaRange = 0.3
        e.particleAlphaSpeed = -0.04
        e.particleScale = 1.0
        e.particleScaleRange = 0.5
        e.emissionAngle = 90 * .pi / 180     // upward drift
        e.emissionAngleRange = 0.6
        e.particleColor = UIColor(red: 0.961, green: 0.788, blue: 0.478, alpha: 1.0) // #f5c97a
        e.particleColorBlendFactor = 1.0
        e.position = CGPoint(x: size.width / 2, y: size.height * 0.35)
        e.fieldBitMask = 0x1        // strong repulsor only
        e.targetNode = self
        return e
    }

    private func makeFlashNode() -> SKSpriteNode {
        let node = SKSpriteNode(color: .white, size: CGSize(width: size.width * 2, height: size.height * 2))
        node.position = CGPoint(x: size.width / 2, y: size.height / 2)
        node.alpha = 0
        node.zPosition = 100
        return node
    }

    // MARK: - Particle textures

    private func rainParticleImage() -> UIImage {
        let sz = CGSize(width: 2, height: 14)
        UIGraphicsBeginImageContextWithOptions(sz, false, 0)
        UIColor.white.setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 1).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    private func snowParticleImage() -> UIImage {
        let sz = CGSize(width: 8, height: 8)
        UIGraphicsBeginImageContextWithOptions(sz, false, 0)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: sz)).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    private func fogParticleImage() -> UIImage {
        let sz = CGSize(width: 64, height: 64)
        UIGraphicsBeginImageContextWithOptions(sz, false, 0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor(white: 1, alpha: 0.25).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawRadialGradient(gradient,
                               startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                               endCenter: CGPoint(x: 32, y: 32), endRadius: 32,
                               options: [])
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    private func dotParticleImage(size sz: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(sz, false, 0)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: sz)).fill()
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    // MARK: - Color temperature → particle tint

    private enum ParticleRole: Hashable { case rain, snow, fog, golden }

    /// Theme-fallback backgrounds keyed by colorTemperature (used when no
    /// externalBackgroundColor has been forwarded yet).
    private func fallbackBackgroundColor(for temp: String) -> UIColor {
        switch temp {
        case "melancholy": return UIColor(red: 0.165, green: 0.173, blue: 0.173, alpha: 1) // #2a2c2c
        case "cool":       return UIColor(red: 0.561, green: 0.659, blue: 0.722, alpha: 1) // #8fa8b8
        case "warm":       return UIColor(red: 0.925, green: 0.878, blue: 0.820, alpha: 1) // #ece0d1
        case "golden":     return UIColor(red: 0.961, green: 0.918, blue: 0.847, alpha: 1) // #f5ead8
        case "crimson":    return UIColor(red: 0.239, green: 0.082, blue: 0.082, alpha: 1) // #3d1515
        case "dusk":       return UIColor(red: 0.165, green: 0.122, blue: 0.239, alpha: 1) // #2a1f3d
        case "arctic":     return UIColor(red: 0.839, green: 0.910, blue: 0.941, alpha: 1) // #d6e8f0
        case "ember":      return UIColor(red: 0.239, green: 0.125, blue: 0.063, alpha: 1) // #3d2010
        case "ash":        return UIColor(red: 0.753, green: 0.753, blue: 0.733, alpha: 1) // #c0c0bb
        default:           return UIColor(red: 0.980, green: 0.976, blue: 0.961, alpha: 1) // #faf9f5
        }
    }

    /// Derives a contrast-compliant particle colour directly from the background.
    ///
    /// Strategy:
    /// • Dark bg  (lum < 0.35) — particles shift toward a luminous, desaturated light
    ///   (near-white with a gentle hue echo) so they glow on screen-blend.
    /// • Light bg (lum ≥ 0.35) — particles shift toward a dark, muted tone derived
    ///   from the background hue, targeting ~3:1 WCAG contrast under .normal blend.
    /// The hue is nudged 35% toward each particle type’s characteristic hue so
    /// rain still reads as cool-grey, snow as cold-white, gold as amber, etc.
    private func contrastParticleColor(for role: ParticleRole) -> UIColor {
        let bgLum   = backgroundLuminance(for: colorTemperature)
        let bgColor = externalBackgroundColor ?? fallbackBackgroundColor(for: colorTemperature)
        var bgH: CGFloat = 0, bgS: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
        bgColor.getHue(&bgH, saturation: &bgS, brightness: &bgB, alpha: &bgA)

        // Hue strategy: stay true to the background hue so particles feel like
        // they belong to the scene's colour temperature. Golden is the one
        // exception — it always wants warm amber regardless of the background.
        let finalH: CGFloat = role == .golden ? 0.08 : bgH

        let result: UIColor
        if bgLum < 0.35 {
            // Dark background → near-white luminous particle.
            // Very low saturation so it reads as "light" not "coloured".
            let targetB: CGFloat = role == .golden ? 0.96 : 0.92
            let targetS: CGFloat
            switch role {
            case .golden: targetS = 0.28
            case .snow:   targetS = min(0.08, bgS * 0.12 + 0.02)  // almost pure white
            case .fog:    targetS = min(0.12, bgS * 0.18 + 0.03)
            default:      targetS = min(0.16, bgS * 0.22 + 0.05)  // rain
            }
            result = UIColor(hue: finalH, saturation: targetS, brightness: targetB, alpha: 1)
        } else {
            // Light background → dark muted particle derived from bg hue.
            let targetB: CGFloat
            let targetS: CGFloat
            switch role {
            case .fog:    targetB = 0.42; targetS = min(0.20, bgS * 0.5)
            case .golden: targetB = 0.48; targetS = 0.65
            case .snow:   targetB = 0.38; targetS = min(0.30, bgS * 0.8 + 0.08)
            default:      targetB = 0.28; targetS = min(0.55, bgS * 1.2 + 0.12)  // rain
            }
            result = UIColor(hue: finalH, saturation: targetS, brightness: targetB, alpha: 1)
        }

        // Log only when the output colour actually changes (not every frame).
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0
        result.getRed(&rr, green: &rg, blue: &rb, alpha: nil)
        let hex = String(format: "#%02X%02X%02X", Int(rr*255), Int(rg*255), Int(rb*255))
        if lastParticleHex[role] != hex {
            lastParticleHex[role] = hex
            var ph: CGFloat = 0, ps: CGFloat = 0, pb: CGFloat = 0
            result.getHue(&ph, saturation: &ps, brightness: &pb, alpha: nil)
            let label = String(describing: role).padding(toLength: 6, withPad: " ", startingAt: 0)
            let side  = bgLum < 0.35 ? "DARK→light" : "LIGHT→dark"
            print("[VieWs][PARTICLE] \(label) → \(hex)  HSB(\(String(format:"%.3f",ph)), \(String(format:"%.3f",ps)), \(String(format:"%.3f",pb)))  bgLum=\(String(format:"%.4f",bgLum))  [\(side)]")
        }
        return result
    }

    // MARK: - Background contrast helpers

    /// Approximate WCAG relative luminance of the Theme background for each
    /// colorTemperature. Uses externalBackgroundLuminance when set by ContentView
    /// (actual palette hex), otherwise estimates from colorTemperature.
    private func backgroundLuminance(for temp: String) -> CGFloat {
        if let ext = externalBackgroundLuminance { return ext }
        switch temp {
        case "melancholy": return 0.030  // #2a2c2c — very dark
        case "cool":       return 0.280  // #8fa8b8 — medium
        case "warm":       return 0.750  // #ece0d1 — light
        case "golden":     return 0.870  // #f5ead8 — very light
        case "neutral":    return 0.960  // #faf9f5 — near-white
        case "crimson":    return 0.025  // #3d1515 — very dark red
        case "dusk":       return 0.019  // #2a1f3d — very dark purple
        case "arctic":     return 0.815  // #d6e8f0 — icy light blue
        case "ember":      return 0.029  // #3d2010 — very dark orange
        case "ash":        return 0.545  // #c0c0bb — medium grey
        default:           return 0.960
        }
    }

    /// Scales a UIColor’s brightness by `factor` and gently boosts saturation
    /// when darkening so hue character is preserved. factor=1 → unchanged;
    /// factor<1 → darker; factor>1 → lighter. Kept for internal utility use.
    private func adjustBrightness(_ color: UIColor, factor: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let f  = max(0, min(2, factor))
        let newS = min(1, s * (1 + (1 - f) * 0.4))   // recover hue when darkening
        let newB = max(0, b * f)
        return UIColor(hue: h, saturation: newS, brightness: newB, alpha: a)
    }

    // MARK: - Public API

    func applyWeatherState(_ state: WeatherState?) {
        guard let state else {
            targetPrecipitation = 0; targetWindSpeed = 0; targetFogDensity = 0
            targetSnowIntensity = 0; targetClearness = 0; targetLightningFrequency = 0
            print("[VieWs][STATE] reset → all targets zeroed")
            return
        }
        targetPrecipitation      = state.precipitation
        targetWindSpeed          = state.windSpeed
        targetFogDensity         = state.fogDensity
        targetSnowIntensity      = state.snowIntensity
        targetClearness          = state.clearness
        targetLightningFrequency = state.lightningFrequency
        colorTemperature         = state.colorTemperature
        // Reset cached particle colours so they are re-evaluated against the new bg.
        lastParticleHex.removeAll()
        print("""
[VieWs][STATE] ──────────────────────────────────────────
  title:             \(state.sceneTitle)
  description:       \(state.atmosphereDescription)
  colorTemperature:  \(state.colorTemperature)
  precipitation:     \(String(format:"%.3f", state.precipitation))
  windSpeed:         \(String(format:"%.3f", state.windSpeed))
  fogDensity:        \(String(format:"%.3f", state.fogDensity))
  snowIntensity:     \(String(format:"%.3f", state.snowIntensity))
  clearness:         \(String(format:"%.3f", state.clearness))
  lightningFreq:     \(String(format:"%.3f", state.lightningFrequency))
──────────────────────────────────────────
""")
    }

    // MARK: - Per-frame update

    override func update(_ currentTime: TimeInterval) {
        // Deferred setup so size is valid
        setupEmitters()

        let lf: Double = 0.02
        currentPrecipitation      += (targetPrecipitation      - currentPrecipitation)      * lf
        currentWindSpeed          += (targetWindSpeed          - currentWindSpeed)          * lf
        currentFogDensity         += (targetFogDensity         - currentFogDensity)         * lf
        currentSnowIntensity      += (targetSnowIntensity      - currentSnowIntensity)      * lf
        currentClearness          += (targetClearness          - currentClearness)          * lf
        currentLightningFrequency += (targetLightningFrequency - currentLightningFrequency) * lf

        updateRain()
        updateSnow()
        updateFog()
        updateGolden()
        updateLightningScheduler(dt: 1.0 / 60.0)
    }

    private func updateRain() {
        guard let e = rainEmitter else { return }
        e.particleBirthRate = CGFloat(currentPrecipitation * 1500)
        let angle = 270.0 - currentWindSpeed * 30.0
        e.emissionAngle = CGFloat(angle * .pi / 180)
        e.particleSpeed = CGFloat(500 + currentPrecipitation * 300 + currentWindSpeed * 800)
        let bgLum = backgroundLuminance(for: colorTemperature)
        e.particleColor      = contrastParticleColor(for: .rain)
        // Dark bg: screen blend makes semitransparent streaks glow.
        // Light bg: normal blend needs higher alpha to be opaque enough.
        e.particleAlpha      = bgLum < 0.35 ? 0.55 : 0.85
        e.particleAlphaRange = 0.18
        // Widen spawn strip to compensate for wind tilt.
        let rainExtra = CGFloat(currentWindSpeed) * size.height * 0.62
        e.particlePositionRange = CGVector(dx: size.width * 1.5 + rainExtra * 2, dy: 0)
    }

    private func updateSnow() {
        guard let e = snowEmitter else { return }
        e.particleBirthRate = CGFloat(currentSnowIntensity * 400)
        let angle = 270.0 - currentWindSpeed * 15.0
        e.emissionAngle = CGFloat(angle * .pi / 180)
        // Snow tilts up to 15° → tan(15°) ≈ 0.268.
        let snowExtra = CGFloat(currentWindSpeed) * size.height * 0.30
        e.particlePositionRange = CGVector(dx: size.width * 1.6 + snowExtra * 2, dy: 0)
        // Lifetime scales with intensity so heavy snow travels further down.
        // alphaSpeed is set to exactly -alpha/lifetime so every flake fades
        // smoothly to zero rather than cutting off abruptly at death.
        let t = CGFloat(currentSnowIntensity)           // 0 → 1
        let lifetime = 6.0 + t * 6.0                   // 6 s light  →  12 s blizzard
        e.particleLifetime    = lifetime
        e.particleLifetimeRange = 2.0 + t * 2.0
        e.particleAlphaSpeed  = CGFloat(-0.75 / lifetime)  // always fades to 0 by death
        let bgLum = backgroundLuminance(for: colorTemperature)
        e.particleColor = contrastParticleColor(for: .snow)
        e.particleAlpha = bgLum < 0.35 ? 0.75 : 0.92
    }

    private func updateFog() {
        guard let e = fogEmitter else { return }
        e.particleBirthRate = CGFloat(currentFogDensity * 3)
        let alpha = Float(currentFogDensity * 0.45)
        e.particleAlphaRange = CGFloat(alpha * 0.5)
        let bgLum = backgroundLuminance(for: colorTemperature)
        e.particleColor = contrastParticleColor(for: .fog)
        e.particleAlpha = bgLum < 0.35
            ? CGFloat(alpha)
            : CGFloat(alpha) * 1.55    // needs more opacity against light bg under .normal blend
    }

    private func updateGolden() {
        guard let e = goldenEmitter else { return }
        e.particleBirthRate = CGFloat(currentClearness * 60)
        let bgLum = backgroundLuminance(for: colorTemperature)
        e.particleColor      = contrastParticleColor(for: .golden)
        e.particleAlpha      = bgLum < 0.35 ? 0.50 : 0.80
        e.particleAlphaRange = 0.25
    }

    private func updateLightningScheduler(dt: TimeInterval) {
        // Use target (not lerped) value so thunder stops the moment frequency is set to 0.
        guard targetLightningFrequency > 0.01 else {
            lightningAccumulator = 0
            return
        }
        lightningAccumulator += dt
        if lightningAccumulator >= lightningNextStrike {
            lightningAccumulator = 0
            // Interval alone controls strike rate — no probability roll so every
            // check is guaranteed to fire. At freq=0.1 → ~6.5 s, freq=0.36 → ~5.2 s,
            // freq=1.0 → ~2 s. Jitter keeps it from sounding metronomic.
            let base = max(2.0, 7.0 - currentLightningFrequency * 5.0)
            lightningNextStrike = base + Double.random(in: 0...(base * 0.4))
            triggerFlash()
        }
    }

    private func triggerFlash() {
        guard let flash = flashNode else { return }
        // Trigger the thunder sound in sync with every visual flash.
        AudioEngineService.shared.triggerThunder()
        flash.removeAllActions()
        let appear  = SKAction.fadeAlpha(to: 0.55, duration: 0.03)
        let hold    = SKAction.wait(forDuration: 0.04)
        let dim     = SKAction.fadeAlpha(to: 0.15, duration: 0.04)
        let hold2   = SKAction.wait(forDuration: 0.03)
        let fadeOut = SKAction.fadeAlpha(to: 0, duration: 0.12)
        flash.run(.sequence([appear, hold, dim, hold2, fadeOut]))
    }

    // MARK: - Touch repulsor (driven from SwiftUI DragGesture in ContentView)

    private var repulsorField: SKFieldNode?      // strong — affects rain, fog, golden (0x1)
    private var repulsorFieldSnow: SKFieldNode?  // soft   — affects snow only (0x2)

    /// Call on DragGesture.onChanged. `point` must be in SpriteKit scene coordinates
    /// (origin bottom-left): pass `CGPoint(x: loc.x, y: scene.size.height - loc.y)`.
    func moveRepulsor(to point: CGPoint) {
        // Strong field for rain / fog / golden
        if repulsorField == nil {
            let field = SKFieldNode.radialGravityField()
            field.strength = -6.0
            field.falloff = 2.5
            field.minimumRadius = 20
            field.categoryBitMask = 0x1
            addChild(field)
            repulsorField = field
        }
        repulsorField?.position = point

        // Soft field for snow — same position, gentler push
        if repulsorFieldSnow == nil {
            let field = SKFieldNode.radialGravityField()
            field.strength = -1.8
            field.falloff = 1.5
            field.minimumRadius = 30
            field.categoryBitMask = 0x2
            addChild(field)
            repulsorFieldSnow = field
        }
        repulsorFieldSnow?.position = point
    }

    /// Call on DragGesture.onEnded to release the repulsor.
    func removeRepulsor() {
        repulsorField?.removeFromParent()
        repulsorField = nil
        repulsorFieldSnow?.removeFromParent()
        repulsorFieldSnow = nil
    }
}
