import SwiftUI

// MARK: - Phase model

private enum OnboardingPhase: Int, Equatable {
    case welcome  // "VieWs" — title + subtitle fade in, then auto-advances
    case breath1  // "Take a breath." — fog drifts in, timed
    case breath2  // "Here, your feelings become the atmosphere." — timed
    case slide3   // "every word becomes weather" — rain, then completes
}

// MARK: - OnboardingView

struct OnboardingView: View {
    let weatherScene: WeatherScene
    @Binding var isPresented: Bool
    let onComplete: () -> Void

    @State private var phase: OnboardingPhase = .welcome
    @State private var titleVisible: Bool = false
    @State private var subtitleVisible: Bool = false
    @State private var continueVisible: Bool = false

    private static let fogState = WeatherState(
        sceneTitle: "", atmosphereDescription: "",
        precipitation: 0, windSpeed: 0.08, fogDensity: 0.50,
        snowIntensity: 0, clearness: 0, lightningFrequency: 0,
        colorTemperature: "neutral"
    )
    private static let rainState = WeatherState(
        sceneTitle: "", atmosphereDescription: "",
        precipitation: 0.30, windSpeed: 0.18, fogDensity: 0,
        snowIntensity: 0, clearness: 0, lightningFrequency: 0,
        colorTemperature: "cool"
    )

    private let bg  = Theme.backgroundColor(for: nil)
    private let ink = Theme.textColor(for: nil)

    // MARK: - Body

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            Group {
                switch phase {
                case .welcome:
                    VStack(spacing: 22) {
                        Text("VieWs")
                            .font(.system(size: 58, weight: .ultraLight, design: .serif))
                            .foregroundColor(ink)
                            .opacity(titleVisible ? 0.88 : 0)
                            .animation(.easeInOut(duration: 1.4), value: titleVisible)
                            .accessibilityAddTraits(.isHeader)
                        Text("a window into how you feel")
                            .font(Theme.subtitleFont())
                            .foregroundColor(ink.opacity(0.50))
                            .opacity(subtitleVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 1.0), value: subtitleVisible)
                    }

                case .breath1:
                    Text("Take a breath.")
                        .font(.system(size: 34, weight: .light, design: .serif))
                        .foregroundColor(ink.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 44)

                case .breath2:
                    Text("Here, your feelings\nbecome the atmosphere.")
                        .font(.system(size: 34, weight: .light, design: .serif))
                        .foregroundColor(ink.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .padding(.horizontal, 44)

                case .slide3:
                    VStack(spacing: 18) {
                        Text("every word\nbecomes weather")
                            .font(.system(size: 34, weight: .light, design: .serif))
                            .foregroundColor(ink)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                        Text("sound, light, and sky — all yours")
                            .font(Theme.subtitleFont())
                            .foregroundColor(ink.opacity(0.50))
                            .multilineTextAlignment(.center)
                        Text("turn up your volume ↑")
                            .font(Theme.monoFont())
                            .foregroundColor(ink.opacity(0.32))
                            .multilineTextAlignment(.center)
                            .opacity(continueVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.8), value: continueVisible)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 44)
                }
            }
            .id(phase)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.7), value: phase)

            // Decorative button — visible on welcome and slide3
            VStack {
                Spacer()
                if phase == .welcome || phase == .slide3 {
                    Button(action: advance) {
                        HStack(spacing: 10) {
                            Text(phase == .slide3 ? "begin" : "enter")
                                .font(Theme.monoFont())
                            Image(systemName: "arrow.forward")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(ink.opacity(0.40))
                    }
                    .buttonStyle(.plain)
                    .opacity(continueVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5), value: continueVisible)
                    .padding(.bottom, 56)
                    .accessibilityLabel("Continue")
                    .accessibilityHidden(!continueVisible)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .onAppear { startPhase(.welcome) }
    }

    // MARK: - State machine

    /// Advance manually — only acts on phases with tap-to-continue.
    private func advance() {
        guard continueVisible else { return }
        switch phase {
        case .welcome:
            startPhase(.breath1)
        case .slide3:
            UserDefaults.standard.set(true, forKey: "vw.hasSeenOnboardingV1")
            AudioEngineService.shared.fadeOutAndReset()
            weatherScene.applyWeatherState(nil)
            withAnimation(.easeInOut(duration: 0.6)) { isPresented = false }
            Task {
                // Allow the onboarding screen to fade out completely before focusing
                try? await Task.sleep(for: .milliseconds(700))
                onComplete()
            }
        default:
            break
        }
    }

    private func startPhase(_ newPhase: OnboardingPhase) {
        continueVisible = false
        withAnimation(.easeInOut(duration: 0.7)) { phase = newPhase }

        switch newPhase {
        case .welcome:
            titleVisible = false
            subtitleVisible = false
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard phase == .welcome else { return }
                withAnimation { titleVisible = true }
                try? await Task.sleep(for: .seconds(1.4))
                guard phase == .welcome else { return }
                withAnimation { subtitleVisible = true }
                try? await Task.sleep(for: .seconds(1.4))
                guard phase == .welcome else { return }
                withAnimation { continueVisible = true }
            }

        case .breath1:
            weatherScene.applyWeatherState(Self.fogState)
            AudioEngineService.shared.applyWeatherState(Self.fogState)
            Task {
                try? await Task.sleep(for: .seconds(2.8))
                guard phase == .breath1 else { return }
                startPhase(.breath2)
            }

        case .breath2:
            Task {
                try? await Task.sleep(for: .seconds(3.2))
                guard phase == .breath2 else { return }
                startPhase(.slide3)
            }

        case .slide3:
            weatherScene.applyWeatherState(Self.rainState)
            AudioEngineService.shared.applyWeatherState(Self.rainState)
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard phase == .slide3 else { return }
                withAnimation { continueVisible = true }
            }
        }
    }
}

