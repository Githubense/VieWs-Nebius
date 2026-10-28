import SwiftUI

// MARK: - Tutorial phase model

enum TutorialPhase: Equatable {
    case idle         // tutorial hasn't started or is suppressed
    case swipeHint    // "swipe around to interact with the environment"
    case tapHint      // "tap on the title to edit"
    case editingHint  // "editing will generate a new environment based on the text alone"
    case navHints     // labels near back + history buttons
}

// MARK: - Overlay view

/// Non-interactive overlay that renders contextual tutorial hints.
/// All text uses `textColor` so it adapts to the current palette.
struct TutorialOverlay: View {
    let phase: TutorialPhase
    let textColor: Color

    var body: some View {
        ZStack {
            // ── Centre-bottom hints ───────────────────────────────────────
            if phase == .swipeHint || phase == .tapHint || phase == .editingHint {
                VStack {
                    Spacer()
                    Text(centreText)
                        .font(Theme.monoFont())
                        .foregroundColor(textColor.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                        .padding(.bottom, 120)
                        .id(phase)           // triggers cross-dissolve on phase change
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.55), value: phase)
                }
            }

            // ── Navigation-corner hints ───────────────────────────────────
            if phase == .navHints {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        // Back button label (top-left, below the arrow icon)
                        Text("go back to home")
                            .font(Theme.monoFont())
                            .foregroundColor(textColor.opacity(0.42))
                            .padding(.leading, 26)
                            .padding(.top, 76)

                        Spacer()

                        // History button label (top-right, below the clock icon)
                        Text("history\nof environments")
                            .font(Theme.monoFont())
                            .foregroundColor(textColor.opacity(0.42))
                            .multilineTextAlignment(.trailing)
                            .padding(.trailing, 26)
                            .padding(.top, 76)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.6), value: phase)
    }

    private var centreText: String {
        switch phase {
        case .swipeHint:   return "swipe around to interact with the environment"
        case .tapHint:     return "tap on the title to edit"
        case .editingHint: return "editing will generate a new environment based on the text alone"
        default:           return ""
        }
    }
}
