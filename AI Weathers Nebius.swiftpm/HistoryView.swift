import SwiftUI
import SwiftData

// MARK: - History screen

struct HistoryView: View {
    @Query(sort: \SavedExperience.dateCreated, order: .reverse)
    private var experiences: [SavedExperience]

    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool
    let onSelect: (SavedExperience) -> Void

    // Per-bubble drag state.
    @State private var dragOffsets: [UUID: CGSize] = [:]
    // Bubbles currently animating toward deletion.
    @State private var deletingIDs: Set<UUID> = []
    // Animated radial positions — updated with spring whenever the list changes.
    @State private var positions: [UUID: CGPoint] = [:]

    private let bubbleSize: CGFloat = 168

    var body: some View {
        ZStack {
            // ── Background ────────────────────────────────────────────────
            Color(hex: "#13131a").ignoresSafeArea()

            // ── Radial bubble field ───────────────────────────────────────
            if !experiences.isEmpty {
                GeometryReader { geo in
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        ZStack {
                            ForEach(experiences) { exp in
                                let drag     = dragOffsets[exp.id] ?? .zero
                                let deleting = deletingIDs.contains(exp.id)
                                let base     = positions[exp.id] ?? .zero
                                let float    = floatingOffset(id: exp.id, t: t)

                                HistoryBubble(experience: exp, size: bubbleSize)
                                    .scaleEffect(deleting ? 0.01 : 1.0)
                                    .opacity(deleting ? 0.0 : 1.0)
                                    .animation(
                                        .spring(response: 0.5, dampingFraction: 0.6),
                                        value: deleting
                                    )
                                    .offset(
                                        x: base.x + drag.width  + CGFloat(float.x),
                                        y: base.y + drag.height + CGFloat(float.y)
                                    )
                                    .gesture(
                                        SimultaneousGesture(
                                            DragGesture()
                                                .onChanged { v in
                                                    dragOffsets[exp.id] = v.translation
                                                }
                                                .onEnded { _ in
                                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                                                        dragOffsets[exp.id] = .zero
                                                    }
                                                },
                                            LongPressGesture(minimumDuration: 0.65)
                                                .onEnded { _ in
                                                    withAnimation { _ = deletingIDs.insert(exp.id) }
                                                    Task {
                                                        try? await Task.sleep(for: .milliseconds(480))
                                                        modelContext.delete(exp)
                                                        deletingIDs.remove(exp.id)
                                                        dragOffsets.removeValue(forKey: exp.id)
                                                    }
                                                }
                                        )
                                    )
                                    .onTapGesture {
                                        guard !deleting else { return }
                                        onSelect(exp)
                                        isPresented = false
                                    }
                                    .accessibilityLabel(exp.sceneTitle)
                                    .accessibilityHint("Double tap to open")
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction(named: "Delete") {
                                        withAnimation { _ = deletingIDs.insert(exp.id) }
                                        Task {
                                            try? await Task.sleep(for: .milliseconds(480))
                                            modelContext.delete(exp)
                                            deletingIDs.remove(exp.id)
                                            dragOffsets.removeValue(forKey: exp.id)
                                        }
                                    }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .ignoresSafeArea()
            }

            // ── Empty state ───────────────────────────────────────────────
            if experiences.isEmpty {
                VStack(spacing: 14) {
                    Text("no memories yet")
                        .font(.system(size: 30, weight: .light, design: .serif))
                        .foregroundColor(.white.opacity(0.25))
                    Text("generate an atmosphere to begin")
                        .font(Theme.monoFont())
                        .foregroundColor(.white.opacity(0.18))
                }
                .accessibilityElement(children: .combine)
            }

            // ── Back button ───────────────────────────────────────────────
            VStack {
                HStack {
                    Button { isPresented = false } label: {
                        Image(systemName: "arrow.backward")
                            .font(.system(size: 22, weight: .light))
                            .foregroundColor(.white.opacity(0.65))
                            .padding(24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close history")
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear { updatePositions(for: experiences) }
        .onChange(of: experiences) { _, newValue in updatePositions(for: newValue) }
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            // Fetch existing scene titles so we only insert seeds that aren't there yet.
            // This runs regardless of whether the user has their own experiences.
            let existingTitles = Set(experiences.map(\.sceneTitle))
            for seed in SavedExperience.seeds {
                guard !existingTitles.contains(seed.sceneTitle) else { continue }
                modelContext.insert(seed)
            }
        }
    }

    // MARK: - Position management

    private func updatePositions(for exps: [SavedExperience]) {
        let total = exps.count
        withAnimation(.spring(response: 0.72, dampingFraction: 0.74)) {
            for (idx, exp) in exps.enumerated() {
                positions[exp.id] = radialPosition(index: idx, total: total)
            }
        }
        let ids = Set(exps.map(\.id))
        positions = positions.filter { ids.contains($0.key) }
    }

    // MARK: - Radial layout

    private func radialPosition(index: Int, total: Int) -> CGPoint {
        let ring1Cap = min(total, 5)
        if index < ring1Cap {
            let angle = CGFloat(index) / CGFloat(ring1Cap) * 2 * .pi - .pi / 2
            return CGPoint(x: cos(angle) * 160, y: sin(angle) * 160)
        } else {
            let idx2   = index - ring1Cap
            let count2 = total - ring1Cap
            let angle  = CGFloat(idx2) / CGFloat(max(1, count2)) * 2 * .pi - .pi / 2
            return CGPoint(x: cos(angle) * 300, y: sin(angle) * 300)
        }
    }

    // MARK: - Floating offset

    /// Deterministic phase derived from the bubble's UUID so it survives re-indexing.
    private func floatingOffset(id: UUID, t: Double) -> (x: Double, y: Double) {
        let seed    = abs(id.hashValue % 10)
        let phase   = Double(seed) * 1.6180339
        let periodX = 3.4 + Double(seed % 4) * 0.7
        let periodY = periodX * 0.87
        let amp     = 6.0 + Double(seed % 3) * 2.0
        return (
            sin(t / periodX * 2 * .pi + phase) * amp * 0.55,
            cos(t / periodY * 2 * .pi + phase + 0.9) * amp
        )
    }
}

// MARK: - Bubble visual

struct HistoryBubble: View {
    let experience: SavedExperience
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: experience.hex0))
                .mask {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white,               location: 0.00),
                            .init(color: .white,               location: 0.58),
                            .init(color: .white.opacity(0.40), location: 0.80),
                            .init(color: .clear,               location: 1.00),
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: size / 2
                    )
                }

            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color(hex: experience.hex1).opacity(0.40),
                            .clear,
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.36
                    )
                )
                .frame(width: size * 0.72, height: size * 0.72)

            Text(experience.sceneTitle)
                .font(.system(size: 17, weight: .light, design: .serif))
                .foregroundColor(experience.contrastTextColor)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
                .padding(.horizontal, 16)
                .frame(width: size * 0.72)
        }
        .frame(width: size, height: size)
    }
}
