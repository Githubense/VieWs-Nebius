import SwiftUI
import SwiftData
import SpriteKit

struct ContentView: View {
    @State private var aiService    = AIService.shared
    @State private var weatherScene = WeatherScene()

    @Environment(\.modelContext) private var modelContext

    /// Controls the history full-screen cover.
    @State private var showHistory: Bool = false
    /// Prevents a duplicate save when loading an experience from history
    /// (which also triggers the palette onChange).
    @State private var isRestoringFromHistory: Bool = false
    /// Controls whether onboarding is presented.
    @State private var showOnboarding: Bool = true

    /// Tutorial hint system — plays once after the first generated scene.
    @State private var tutorialPhase: TutorialPhase = .idle
    @State private var tutorialDone: Bool =
        UserDefaults.standard.bool(forKey: "vw.hasSeenTutorialV1")

    @State private var emotionText: String = ""

    // Title-editing re-prompt (Mode A)
    @State private var isEditingTitle: Bool = false
    @State private var editingTitleText: String = ""
    /// Keeps the user's typed title visible after AI regenerates weather params.
    @State private var pinnedTitle: String? = nil

    @FocusState private var isInputFocused: Bool
    @FocusState private var isTitleFocused: Bool

    // MARK: Loading animation
    /// Drives the opacity pulse shared by all loading states.
    @State private var isBreathing: Bool = false
    /// Currently displayed phrase — changing it triggers a cross-dissolve via .id().
    @State private var currentPhrase: String = ""
    /// Shuffled copy of loadingPhrases rebuilt at the start of every generation.
    @State private var shuffledPhrases: [String] = []
    /// Index into shuffledPhrases; incremented every ~2.8 s during loading.
    @State private var loadingPhraseIndex: Int = 0
    /// Task managing the phrase-cycling loop; cancelled when loading ends.
    @State private var phraseTask: Task<Void, Never>? = nil
    /// Flipped to true only after the breath cycle finishes post-load,
    /// so the result never snaps in mid-breath.
    @State private var showResult: Bool = false
    /// Set false on submit so the input area fades out rather than snapping away.
    @State private var inputVisible: Bool = true
    /// Source pool; never mutated. Shuffled into shuffledPhrases each generation.
    private let loadingPhrases: [String] = [
        "something is forming",
        "translating feeling into sky",
        "reading the weather in you",
        "the atmosphere is shifting",
        "finding your horizon",
        "distilling your mood",
        "composing the air around you",
        "your sky is taking shape",
        "the light is changing",
        "listening to your landscape",
        "sensing the weather in your words",
        "your world is forming",
    ]

    // MARK: - Committed palette
    /// The last successfully generated palette. This is the ONLY value that
    /// drives background colour, text colour, blend mode, and particle contrast.
    /// It is never cleared on reset and never updated from the weather onChange —
    /// only set when the palette session result arrives. This guarantees a single
    /// background transition per generation: previous palette → new palette.
    @State private var displayedPalette: ColorPalette? = nil
    @State private var showDebug = false
    @State private var generationTask: Task<Void, Never>? = nil
    @State private var dbPrecipitation:    Double = 0
    @State private var dbWindSpeed:        Double = 0
    @State private var dbFogDensity:       Double = 0
    @State private var dbSnowIntensity:    Double = 0
    @State private var dbClearness:        Double = 0
    @State private var dbLightning:        Double = 0
    @State private var dbColorTemp:        String = "neutral"

    // MARK: - Palette-driven colours
    // All properties read exclusively from displayedPalette so colours are
    // stable during loading. They only change when displayedPalette is updated
    // (i.e. when the palette session result arrives).

    private var paletteBackground: Color {
        if let c = displayedPalette?.colors[safe: 0]?.validColor { return c }
        return Theme.backgroundColor(for: nil)   // neutral until first palette
    }
    private var paletteText: Color {
        if let textColor = displayedPalette?.colors[safe: 2],
           let bgColor   = displayedPalette?.colors[safe: 0],
           textColor.contrastRatio(against: bgColor) >= 3.5,
           let c = textColor.validColor { return c }
        return Theme.textColor(for: displayedPalette == nil ? nil : aiService.currentWeatherState?.colorTemperature)
    }
    private var paletteHint: Color {
        if let c = displayedPalette?.colors[safe: 3]?.validColor { return c }
        return Theme.hintColor(for: nil)
    }
    private var paletteAccent: Color {
        if let c = displayedPalette?.colors[safe: 4]?.validColor { return c }
        return Theme.midToneNeutral
    }

    /// WCAG relative luminance of the committed background (0 = black, 1 = white).
    private var backgroundLuminanceValue: Double {
        if let lum = displayedPalette?.colors[safe: 0]?.luminance { return lum }
        switch aiService.currentWeatherState?.colorTemperature {
        case "melancholy": return 0.030
        case "cool":       return 0.280
        case "warm":       return 0.750
        case "golden":     return 0.870
        case "crimson":    return 0.025
        case "dusk":       return 0.019
        case "arctic":     return 0.815
        case "ember":      return 0.029
        case "ash":        return 0.545
        default:           return 0.960
        }
    }

    /// .screen on dark backgrounds (additive glow).
    /// .normal on light backgrounds — .screen collapses dark particles to white
    /// against a near-white destination, making them completely invisible.
    private var sceneBlendMode: BlendMode {
        backgroundLuminanceValue < 0.35 ? .screen : .normal
    }

    /// Committed background as UIColor for WeatherScene particle contrast.
    private var backgroundUIColor: UIColor {
        if let hex = displayedPalette?.colors[safe: 0]?.hex {
            let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "#", with: "")
            if cleaned.count == 6, let value = UInt64(cleaned, radix: 16) {
                return UIColor(
                    red:   CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8)  & 0xFF) / 255,
                    blue:  CGFloat( value        & 0xFF) / 255,
                    alpha: 1
                )
            }
        }
        // Fallback to Theme static colours
        switch aiService.currentWeatherState?.colorTemperature {
        case "melancholy": return UIColor(red: 0.165, green: 0.173, blue: 0.173, alpha: 1)
        case "cool":       return UIColor(red: 0.561, green: 0.659, blue: 0.722, alpha: 1)
        case "warm":       return UIColor(red: 0.925, green: 0.878, blue: 0.820, alpha: 1)
        case "golden":     return UIColor(red: 0.961, green: 0.918, blue: 0.847, alpha: 1)
        case "crimson":    return UIColor(red: 0.239, green: 0.082, blue: 0.082, alpha: 1)
        case "dusk":       return UIColor(red: 0.165, green: 0.122, blue: 0.239, alpha: 1)
        case "arctic":     return UIColor(red: 0.839, green: 0.910, blue: 0.941, alpha: 1)
        case "ember":      return UIColor(red: 0.239, green: 0.125, blue: 0.063, alpha: 1)
        case "ash":        return UIColor(red: 0.753, green: 0.753, blue: 0.733, alpha: 1)
        default:           return UIColor(red: 0.980, green: 0.976, blue: 0.961, alpha: 1)
        }
    }

    /// Formatted real-world atmospheric hint when live weather data is pulled from Tavily.
    private var formattedGroundingHint: String? {
        guard let raw = aiService.currentGrounding?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return Self.formatGrounding(
            raw,
            location: aiService.currentGroundingLocation,
            userQuery: emotionText.isEmpty ? pinnedTitle : emotionText
        )
    }

    /// Extracts a subtle, elegant atmospheric hint (e.g. "chiapas is 15°c, passing clouds" or "paris is 14°c, clear skies").
    static func formatGrounding(_ raw: String, location: String? = nil, userQuery: String? = nil) -> String? {
        guard !raw.isEmpty else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // 1. Reject failure responses from Tavily
        if lower.contains("do not provide") || lower.contains("could not find") || lower.contains("no live weather") {
            return nil
        }

        // 2. Extract temperature, strictly prioritizing current/live readings over daily forecast highs
        var tempStr: String? = nil

        // Priority A: Search for explicitly anchored current temperature ("currently 14°C", "is 14°C", "feels like 14°C")
        let currentTempPattern = #"(?:currently|current\s+temp(?:erature)?(?:\s+is)?|temp(?:erature)?\s+is(?:\s+currently)?|is\s+currently|is|feels\s+like|right\s+now)\s*:?\s*(\d{1,3})\s*(?:°\s*([CFcf])|°|degrees?\s*(celsius|fahrenheit)?)"#
        if let regex = try? NSRegularExpression(pattern: currentTempPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
           let numRange = Range(match.range(at: 1), in: text),
           let val = Int(text[numRange]) {
            var unit: String = ""
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound, let uRange = Range(match.range(at: 2), in: text) {
                unit = String(text[uRange]).lowercased()
            } else if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound, let uRange = Range(match.range(at: 3), in: text) {
                unit = String(text[uRange]).lowercased()
            }
            if unit.hasPrefix("f") || (unit.isEmpty && val > 45) {
                let celsius = Int(round((Double(val) - 32.0) * 5.0 / 9.0))
                tempStr = "\(celsius)°c"
            } else {
                tempStr = "\(val)°c"
            }
        }

        // Priority B: Fallback to all temperatures in text, filtering out forecast highs (e.g. "high of 21°C")
        if tempStr == nil {
            let allTempPattern = #"(high\s+of\s+|maximum\s+of\s+|high:\s*|high\s+)?(\d{1,3})\s*(?:°\s*([CFcf])|°|degrees?\s*(celsius|fahrenheit)?)"#
            if let regex = try? NSRegularExpression(pattern: allTempPattern, options: .caseInsensitive) {
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
                let targetMatch = matches.first(where: { m in m.range(at: 1).location == NSNotFound }) ?? matches.first
                if let match = targetMatch,
                   let numRange = Range(match.range(at: 2), in: text),
                   let val = Int(text[numRange]) {
                    var unit: String = ""
                    if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound, let uRange = Range(match.range(at: 3), in: text) {
                        unit = String(text[uRange]).lowercased()
                    } else if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound, let uRange = Range(match.range(at: 4), in: text) {
                        unit = String(text[uRange]).lowercased()
                    }
                    if unit.hasPrefix("f") || (unit.isEmpty && val > 45) {
                        let celsius = Int(round((Double(val) - 32.0) * 5.0 / 9.0))
                        tempStr = "\(celsius)°c"
                    } else {
                        tempStr = "\(val)°c"
                    }
                }
            }
        }

        // 3. Extract prominent weather condition keyword
        let weatherWords = [
            "passing clouds", "scattered clouds", "partly cloudy", "mostly cloudy",
            "overcast", "clear skies", "clear sky", "light rain", "heavy rain",
            "thunderstorm", "showers", "drizzle", "sunny", "clear", "cloudy",
            "rain", "snow", "fog", "mist", "haze", "breeze", "windy"
        ]
        var matchedCond: String? = nil
        for w in weatherWords {
            if lower.contains(w) {
                matchedCond = w
                break
            }
        }

        // 4. Resolve location name: NEVER match from Tavily text snippet!
        let resolvedLocation: String
        if let explicitLoc = location, !explicitLoc.isEmpty {
            resolvedLocation = explicitLoc.lowercased()
        } else if let queryLoc = userQuery.flatMap({ NebiusClient.detectLocation(in: $0) }) {
            resolvedLocation = queryLoc.lowercased()
        } else {
            resolvedLocation = "live atmosphere"
        }

        let hint: String?
        if let temp = tempStr, let cond = matchedCond {
            hint = "\(resolvedLocation) is \(temp), \(cond)"
        } else if let temp = tempStr {
            hint = "\(resolvedLocation) is \(temp)"
        } else if let cond = matchedCond {
            hint = "\(resolvedLocation) is \(cond)"
        } else {
            hint = nil
        }

        if let hint {
            print("[VieWs][Hint] Atmospheric subtitle: '\(hint)'")
        }
        return hint
    }

    var body: some View {
        ZStack {
            // ── Layer 1: Background color ─────────────────────────────────
            // Keyed on displayedPalette — only changes when the palette session
            // result is committed, never during loading or on reset.
            paletteBackground
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2.5), value: displayedPalette?.title)
                .accessibilityHidden(true)

            // ── Layer 2: SpriteKit particles ──────────────────────────────
            WeatherSceneView(scene: weatherScene)
                .ignoresSafeArea()
                .blendMode(sceneBlendMode)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            // ── Layer 3: Content UI ───────────────────────────────────────
            VStack {
                Spacer()

                Group {
                    if let weather = aiService.currentWeatherState, showResult {
                        // ── Result state ─────────────────────────────────
                        // Only shown after showResult flips (post-breath) so the
                        // result title never snaps in mid-pulse.
                        if isEditingTitle {
                            titleEditField(for: weather)
                                .transition(.opacity)
                        } else {
                            resultDisplay(for: weather)
                                .transition(.opacity)
                        }
                    } else if aiService.isLoading || (aiService.currentWeatherState != nil && !showResult) {
                        // ── Loading state ────────────────────────────────
                        // Each phrase is its own view identity via .id so SwiftUI
                        // cross-dissolves between them — identical to the final
                        // phrase → result transition.
                        ZStack {
                            Text(currentPhrase)
                                .id(currentPhrase)
                                .font(Theme.titleFont())
                                .foregroundColor(paletteText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                                .transition(.opacity)
                        }
                        .opacity(isBreathing ? 0.18 : 0.88)
                        .accessibilityLabel("Generating your atmosphere")
                        .accessibilityAddTraits(.updatesFrequently)
                        .onAppear {
                            isBreathing = false
                            loadingPhraseIndex = 0
                            currentPhrase = shuffledPhrases.first ?? loadingPhrases[0]
                            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                                isBreathing = true
                            }
                            // Show only two phrases: sit on the first for ~4 s,
                            // cross-dissolve to the second, then hold until the
                            // AI finishes and the result transition takes over.
                            phraseTask = Task {
                                try? await Task.sleep(for: .seconds(4.0))
                                guard !Task.isCancelled else { return }
                                let second = shuffledPhrases.count > 1 ? shuffledPhrases[1] : shuffledPhrases[0]
                                withAnimation(.easeInOut(duration: 0.55)) {
                                    currentPhrase = second
                                }
                                // No further swaps — hold until loading ends.
                            }
                        }
                        .onDisappear {
                            phraseTask?.cancel()
                            phraseTask = nil
                        }
                        .transition(.opacity)
                    } else {
                        // ── Input state ───────────────────────────────────
                        inputArea()
                            .opacity(inputVisible ? 1 : 0)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.55), value: currentPhrase)
                .animation(.easeInOut(duration: 0.9), value: showResult)
                .animation(.easeInOut(duration: 0.9), value: aiService.isLoading)
                .animation(.easeInOut(duration: 0.55), value: inputVisible)

                Spacer()

                // ── Lower footer: Powered by Nebius badge (main screen) ───────
                if inputVisible && aiService.currentWeatherState == nil && !aiService.isLoading {
                    nebiusFooterBadge()
                        .padding(.bottom, 22)
                        .transition(.opacity)
                }
            }

            // ── Layer 4: Back button (result only) ────────────────────────
            if aiService.currentWeatherState != nil {
                backButton()
            }

            // ── Layer 4b: Tutorial hints ──────────────────────────────────
            if showResult && !tutorialDone && tutorialPhase != .idle {
                TutorialOverlay(phase: tutorialPhase, textColor: paletteText)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.6), value: tutorialPhase)
                    .accessibilityHidden(true)
            }

            // ── Layer 5: History button ───────────────────────────────────
            historyButton()
                .opacity(aiService.isLoading ? 0 : 1)
                .animation(.easeInOut(duration: 0.5), value: aiService.isLoading)

            // ── Layer 6: History overlay (same cross-dissolve as all states) ────
            if showHistory {
                HistoryView(isPresented: $showHistory) { exp in
                    loadExperience(exp)
                }
                .transition(.opacity)
                .zIndex(10)
            }

            // ── Layer 7: Onboarding (topmost; only on first launch) ───────────
            if showOnboarding {
                OnboardingView(
                    weatherScene: weatherScene,
                    isPresented: $showOnboarding
                ) {
                    // Onboarding finished — focus input field
                    isInputFocused = true
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.7), value: showHistory)
        .animation(.easeInOut(duration: 0.9), value: showOnboarding)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let scenePoint = CGPoint(
                        x: value.location.x,
                        y: weatherScene.size.height - value.location.y
                    )
                    weatherScene.moveRepulsor(to: scenePoint)
                    // Advance tutorial from swipeHint on first real drag
                    if tutorialPhase == .swipeHint {
                        withAnimation(.easeInOut(duration: 0.6)) { tutorialPhase = .tapHint }
                    }
                }
                .onEnded { _ in
                    weatherScene.removeRepulsor()
                }
        )
        .onChange(of: aiService.currentWeatherState?.sceneTitle) { _, _ in
            if let weather = aiService.currentWeatherState {
                AudioEngineService.shared.applyWeatherState(weather)
                weatherScene.applyWeatherState(weather)
                // Don't push background values to the scene yet — displayedPalette
                // still holds the previous palette, which is correct because the
                // background hasn't changed. The scene will get updated values
                // when the palette onChange fires and commits the new palette.
                isEditingTitle = false
                print("[VieWs][CV] weather applied  colorTemp=\(weather.colorTemperature)")
            }
        }
        .onChange(of: aiService.currentPalette?.title) { _, _ in
            guard let p = aiService.currentPalette else { return }
            // Commit the new palette — this is the only moment the background and
            // particle colours change. The SwiftUI animation key is on
            // displayedPalette?.title so the cross-fade fires exactly here.
            displayedPalette = p
            weatherScene.externalBackgroundLuminance = backgroundLuminanceValue
            weatherScene.externalBackgroundColor = backgroundUIColor
            let swatches = p.colors.enumerated().map { i, c in "[\(i)]\(c.hex)" }.joined(separator: "  ")
            print("[VieWs][CV] palette committed '\(p.title)'  \(swatches)  blendMode=\(backgroundLuminanceValue < 0.35 ? ".screen" : ".normal")")

            // ── Save to history (skip when restoring a past experience) ──
            guard !isRestoringFromHistory else {
                isRestoringFromHistory = false
                return
            }
            if let weather = aiService.currentWeatherState {
                var savedWeather = weather
                if let pin = pinnedTitle { savedWeather.sceneTitle = pin }
                let exp = SavedExperience(
                    weather: savedWeather,
                    paletteTitle: p.title,
                    hex0: p.colors[safe: 0]?.hex ?? "#2c2c2e",
                    hex1: p.colors[safe: 1]?.hex ?? "#3a3a3c",
                    hex2: p.colors[safe: 2]?.hex ?? "#e5e5ea",
                    hex3: p.colors[safe: 3]?.hex ?? "#88c0d0",
                    hex4: p.colors[safe: 4]?.hex ?? "#a3be8c"
                )
                modelContext.insert(exp)
            }
        }
        .onChange(of: aiService.isLoading) { _, newValue in
            guard !newValue else { return }
            phraseTask?.cancel()
            phraseTask = nil
            withAnimation(.easeInOut(duration: 0.55)) { isBreathing = false }
            let wasEditingHint = (tutorialPhase == .editingHint)
            // Keep tutorialPhase as .editingHint until AFTER showResult flips so that
            // onChange(of: showResult) sees a non-idle phase and skips the swipeHint
            // restart — preventing a race that would reset the tutorial flow.
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.easeInOut(duration: 0.55)) { showResult = true }
                if wasEditingHint {
                    // Now safe to clear — showResult onChange already evaluated its guard
                    tutorialPhase = .idle
                    try? await Task.sleep(for: .seconds(2.0))
                    guard tutorialPhase == .idle else { return }
                    withAnimation(.easeInOut(duration: 0.6)) { tutorialPhase = .navHints }
                }
            }
        }
        .onChange(of: showResult) { _, newValue in
            guard newValue, !tutorialDone, tutorialPhase == .idle else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.0))
                guard showResult, !tutorialDone, tutorialPhase == .idle else { return }
                withAnimation(.easeInOut(duration: 0.6)) { tutorialPhase = .swipeHint }
                // No auto-advance — swipeHint persists until user actually drags
            }
        }
        .onChange(of: isEditingTitle) { _, newValue in
            guard newValue, tutorialPhase == .tapHint else { return }
            withAnimation(.easeInOut(duration: 0.6)) { tutorialPhase = .editingHint }
        }
        .onAppear {
            weatherScene.size = CGSize(width: 1000, height: 1000)
            weatherScene.scaleMode = .resizeFill
            // Don't steal focus while onboarding is playing
            if !showOnboarding { isInputFocused = true }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func resultDisplay(for weather: WeatherState) -> some View {
        let textColor = paletteText
        let displayTitle = pinnedTitle ?? weather.sceneTitle
        VStack(spacing: 7) {
            // Tap title to enter edit mode
            Button {
                editingTitleText = displayTitle
                isEditingTitle = true
            } label: {
                Text(displayTitle)
                    .font(Theme.titleFont())
                    .foregroundColor(textColor)
                    .opacity(0.88)
            }
            .buttonStyle(.plain)

            if let hint = formattedGroundingHint {
                Text(hint)
                    .font(.system(size: 13, weight: .light, design: .serif))
                    .foregroundColor(paletteHint)
                    .opacity(0.75)
                    .transition(.opacity)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .accessibilityLabel("\(displayTitle). \(weather.atmosphereDescription)")
        .accessibilityHint("Double tap to edit and regenerate")
    }

    @ViewBuilder
    private func titleEditField(for weather: WeatherState) -> some View {
        let textColor = paletteText

        VStack(spacing: 7) {
            TextField("", text: $editingTitleText)
                .font(Theme.titleFont())
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .focused($isTitleFocused)
                .onSubmit { submitTitleEdit() }
                .padding(.horizontal, 40)
                .onAppear { isTitleFocused = true }
                .accessibilityLabel("Scene title")
                .accessibilityHint("Submit to regenerate atmosphere")

            if let hint = formattedGroundingHint {
                Text(hint)
                    .font(.system(size: 13, weight: .light, design: .serif))
                    .foregroundColor(paletteHint)
                    .opacity(0.45)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func inputArea() -> some View {
        VStack(spacing: 0) {
            // Big serif heading — sits above the field and never moves,
            // regardless of keyboard state.
            Text("how are you feeling today?")
                .font(.system(size: 46, weight: .light, design: .serif))
                .foregroundColor(paletteText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 38)
                .accessibilityAddTraits(.isHeader)

            // Text entry
            TextField("type a feeling, a moment, a day...", text: $emotionText)
                .font(Theme.bodyFont())
                .foregroundColor(paletteText)
                .multilineTextAlignment(.center)
                .focused($isInputFocused)
                .onSubmit { submitEmotion() }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .frame(width: 160, height: 0.5)
                        .foregroundColor(paletteText.opacity(0.28))
                        .offset(y: 8)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 40)
                .accessibilityLabel("Describe your feeling")
                .accessibilityHint("Submit to generate atmosphere")

            // Enter hint
            Text("↵  and watch your atmosphere form")
                .font(Theme.monoFont())
                .foregroundColor(paletteHint)
                .opacity(0.65)
                .padding(.top, 22)
                .accessibilityHidden(true)
        }
        // Keep the layout anchored — prevent keyboard from pushing the view up.
        .ignoresSafeArea(.keyboard)
    }

    @ViewBuilder
    private func nebiusFooterBadge() -> some View {
        HStack(spacing: 5) {
            Text("powered by")
                .font(.system(size: 11, weight: .light, design: .serif))
            Text("NEBIUS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.4)
            Text("•")
                .font(.system(size: 8))
            Text("NVIDIA Nemotron")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundColor(paletteText.opacity(0.35))
        .accessibilityLabel("Powered by Nebius and NVIDIA Nemotron")
    }

    @ViewBuilder
    private func debugToggleButton() -> some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    if !showDebug {
                        // Seed sliders from current state if available
                        if let w = aiService.currentWeatherState {
                            dbPrecipitation = w.precipitation
                            dbWindSpeed     = w.windSpeed
                            dbFogDensity    = w.fogDensity
                            dbSnowIntensity = w.snowIntensity
                            dbClearness     = w.clearness
                            dbLightning     = w.lightningFrequency
                            dbColorTemp     = w.colorTemperature
                        }
                    }
                    showDebug.toggle()
                } label: {
                    Image(systemName: showDebug ? "slider.horizontal.3" : "slider.horizontal.3")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(paletteText.opacity(showDebug ? 0.88 : 0.45))
                        .padding(24)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func debugPanel() -> some View {
        let debugState = WeatherState(
            sceneTitle:           pinnedTitle ?? aiService.currentWeatherState?.sceneTitle ?? "Debug",
            atmosphereDescription: "debug mode",
            precipitation:        dbPrecipitation,
            windSpeed:            dbWindSpeed,
            fogDensity:           dbFogDensity,
            snowIntensity:        dbSnowIntensity,
            clearness:            dbClearness,
            lightningFrequency:   dbLightning,
            colorTemperature:     dbColorTemp
        )

        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Debug")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .textCase(.uppercase)
                        .kerning(1.5)
                    Spacer()
                    Button("Reset") {
                        dbPrecipitation = 0; dbWindSpeed = 0; dbFogDensity = 0
                        dbSnowIntensity = 0; dbClearness = 0; dbLightning = 0
                        dbColorTemp = "neutral"
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().background(.white.opacity(0.12))

                ScrollView {
                    VStack(spacing: 12) {
                        DebugSliderRow(label: "precipitation", value: $dbPrecipitation)
                        DebugSliderRow(label: "windSpeed",     value: $dbWindSpeed)
                        DebugSliderRow(label: "fogDensity",    value: $dbFogDensity)
                        DebugSliderRow(label: "snowIntensity", value: $dbSnowIntensity)
                        DebugSliderRow(label: "clearness",     value: $dbClearness)
                        DebugSliderRow(label: "lightning",     value: $dbLightning)

                        // colorTemperature picker
                        HStack {
                            Text("colorTemp")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 90, alignment: .leading)
                            Picker("", selection: $dbColorTemp) {
                                ForEach(["warm","cool","neutral","melancholy","golden"], id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                            .scaleEffect(0.78, anchor: .leading)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 310)
            }
            .background(.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showDebug)
        .onChange(of: dbPrecipitation)  { _, _ in applyDebug(debugState) }
        .onChange(of: dbWindSpeed)      { _, _ in applyDebug(debugState) }
        .onChange(of: dbFogDensity)     { _, _ in applyDebug(debugState) }
        .onChange(of: dbSnowIntensity)  { _, _ in applyDebug(debugState) }
        .onChange(of: dbClearness)      { _, _ in applyDebug(debugState) }
        .onChange(of: dbLightning)      { _, _ in applyDebug(debugState) }
        .onChange(of: dbColorTemp)      { _, _ in applyDebug(debugState) }
    }

    private func applyDebug(_ state: WeatherState) {
        AudioEngineService.shared.applyWeatherState(state)
        weatherScene.applyWeatherState(state)
    }

    @ViewBuilder
    private func backButton() -> some View {
        VStack {
            HStack {
                Button {
                    completeTutorial()
                    resetToInput()
                } label: {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(paletteText.opacity(1))
                        .padding(24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go back to home")
                Spacer()
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func historyButton() -> some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    completeTutorial()
                    dismissKeyboard()
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(paletteText.opacity(1))
                        .padding(24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("History")
            }
            Spacer()
        }
    }

    // MARK: - Actions

    /// Restores a saved experience without re-prompting the AI.
    private func loadExperience(_ exp: SavedExperience) {
        dismissKeyboard()
        let weather = exp.weatherState
        let palette = exp.colorPalette

        // Cancel any ongoing generation
        generationTask?.cancel(); generationTask = nil
        phraseTask?.cancel();     phraseTask = nil
        isBreathing   = false
        isEditingTitle = false
        showResult    = false

        // Mark so the palette onChange skips saving a duplicate entry
        isRestoringFromHistory = true

        // Apply to audio + visual engines
        AudioEngineService.shared.applyWeatherState(weather)
        weatherScene.applyWeatherState(weather)

        // Commit palette (drives background color, blend mode, particle contrast)
        displayedPalette = palette
        weatherScene.externalBackgroundLuminance = backgroundLuminanceValue
        weatherScene.externalBackgroundColor     = backgroundUIColor

        // Update AI service so the result display renders correctly
        aiService.currentWeatherState = weather
        aiService.currentPalette      = palette
        aiService.currentGrounding    = nil

        // UI state
        pinnedTitle  = exp.sceneTitle
        emotionText  = exp.sceneTitle
        inputVisible = false

        withAnimation(.easeInOut(duration: 0.55)) { showResult = true }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func submitEmotion() {
        let text = emotionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dismissKeyboard()
        shuffledPhrases = loadingPhrases.shuffled()
        showResult = false
        phraseTask?.cancel()
        phraseTask = nil
        withAnimation(.easeInOut(duration: 0.55)) { inputVisible = false }
        generationTask?.cancel()
        generationTask = Task { await aiService.generateWeather(for: text) }
    }

    private func submitTitleEdit() {
        let text = editingTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { isEditingTitle = false; return }
        emotionText = text
        pinnedTitle = text
        isEditingTitle = false
        shuffledPhrases = loadingPhrases.shuffled()
        showResult = false
        phraseTask?.cancel()
        phraseTask = nil
        generationTask?.cancel()
        generationTask = Task { await aiService.generateWeather(for: text) }
    }

    /// Marks the tutorial complete when the user taps back or history
    /// while nav hints are visible. No-op if already done or not at that phase.
    private func completeTutorial() {
        guard !tutorialDone, tutorialPhase == .navHints else { return }
        UserDefaults.standard.set(true, forKey: "vw.hasSeenTutorialV1")
        withAnimation(.easeInOut(duration: 0.6)) {
            tutorialDone = true
            tutorialPhase = .idle
        }
    }

    private func resetToInput() {
        generationTask?.cancel()
        generationTask = nil
        phraseTask?.cancel()
        phraseTask = nil
        isBreathing = false
        showResult = false
        withAnimation(.easeInOut(duration: 0.4)) { inputVisible = true }
        aiService.currentWeatherState = nil
        aiService.currentPalette = nil
        aiService.currentGrounding = nil
        aiService.currentGroundingLocation = nil
        // Revert to original Theme colors on the homescreen.
        displayedPalette = nil
        isEditingTitle = false
        pinnedTitle = nil
        emotionText = ""
        showDebug = false
        weatherScene.applyWeatherState(nil)
        // Small delay so the UI cross-fade begins before audio fades,
        // preventing an abrupt audio cut on the render thread.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            AudioEngineService.shared.reset()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isInputFocused = true
        }
    }
}

// MARK: - SpriteKit wrapper (suppresses UIFocusEnvironment warning)

/// SKView subclass that opts completely out of the UIKit focus engine.
private final class NoFocusSKView: SKView {
    override var canBecomeFocused: Bool { false }
}

/// Thin UIViewRepresentable using NoFocusSKView instead of plain SKView,
/// eliminating the UIFocusEnvironment console warning entirely.
private struct WeatherSceneView: UIViewRepresentable {
    let scene: SKScene

    func makeUIView(context: Context) -> NoFocusSKView {
        let view = NoFocusSKView()
        view.backgroundColor = .clear
        view.allowsTransparency = true
        view.presentScene(scene)
        return view
    }

    func updateUIView(_ uiView: NoFocusSKView, context: Context) {}
}

private struct DebugSliderRow: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 90, alignment: .leading)
            Slider(value: $value, in: 0...1)
                .tint(.white.opacity(0.7))
            Text(String(format: "%.2f", value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }
}

