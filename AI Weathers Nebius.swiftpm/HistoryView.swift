import SwiftUI
import SwiftData

// MARK: - Responsive Canvas Geometry

struct HistoryCanvasGeometry: Equatable {
    let viewport: CGSize
    let totalItems: Int

    /// Smallest dimension of the container (handles portrait, landscape, foldables, and split view).
    var minDimension: CGFloat {
        min(viewport.width, viewport.height)
    }

    /// Dynamic bubble diameter scaled proportionally to the container.
    /// Clamped between 98pt (compact screens) and 156pt (tablets / desktop).
    var bubbleSize: CGFloat {
        min(156.0, max(98.0, minDimension * 0.28))
    }

    /// Primary orbit radius — strictly constrained so that Ring 1 bubbles never clip off screen edges.
    /// `maxSafeRadius` guarantees `radius + bubbleSize/2 + padding <= minDimension / 2`.
    var innerOrbitRadius: CGFloat {
        let maxSafeRadius = (minDimension / 2.0) - (bubbleSize / 2.0) - 24.0
        let preferredRadius = minDimension * 0.26
        return max(bubbleSize * 0.82, min(maxSafeRadius, preferredRadius))
    }

    /// Radial step between successive orbital tiers.
    var ringSpacing: CGFloat {
        bubbleSize * 1.15
    }

    /// Computes the resting position for an item at `index` in the constellation.
    func position(for index: Int) -> CGPoint {
        guard totalItems > 0 else { return .zero }
        let ring1Cap = min(totalItems, 5)

        if index < ring1Cap {
            // Tier 1: Primary orbit, evenly spaced around the center
            let angle = (CGFloat(index) / CGFloat(ring1Cap)) * 2 * .pi - (.pi / 2)
            return CGPoint(
                x: cos(angle) * innerOrbitRadius,
                y: sin(angle) * innerOrbitRadius
            )
        } else {
            // Tier 2+: Outer orbits expanding into the cosmos
            let remaining = totalItems - ring1Cap
            let outerIdx = index - ring1Cap
            let ring2Cap = 8

            if outerIdx < ring2Cap || remaining <= ring2Cap {
                let count = min(remaining, ring2Cap)
                let tierRadius = innerOrbitRadius + ringSpacing
                // Stagger angle by half an interval so outer bubbles nest between inner ones
                let stagger = .pi / CGFloat(max(1, count))
                let angle = (CGFloat(outerIdx) / CGFloat(max(1, count))) * 2 * .pi - (.pi / 2) + stagger
                return CGPoint(
                    x: cos(angle) * tierRadius,
                    y: sin(angle) * tierRadius
                )
            } else {
                let ring3Idx = outerIdx - ring2Cap
                let count3 = remaining - ring2Cap
                let tierRadius = innerOrbitRadius + (ringSpacing * 2.0)
                let stagger = .pi / 3.0
                let angle = (CGFloat(ring3Idx) / CGFloat(max(1, count3))) * 2 * .pi - (.pi / 2) + stagger
                return CGPoint(
                    x: cos(angle) * tierRadius,
                    y: sin(angle) * tierRadius
                )
            }
        }
    }
}

// MARK: - History Screen

struct HistoryView: View {
    @Query(sort: \SavedExperience.dateCreated, order: .reverse)
    private var experiences: [SavedExperience]

    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool
    let onSelect: (SavedExperience) -> Void

    // Per-bubble drag state (local tug & spring).
    @State private var dragOffsets: [UUID: CGSize] = [:]
    // Bubbles currently animating toward deletion.
    @State private var deletingIDs: Set<UUID> = []
    // Animated radial positions in canvas space.
    @State private var positions: [UUID: CGPoint] = [:]

    // World canvas pan offset (persisted across drags).
    @State private var worldPanOffset: CGSize = .zero
    // Active drag translation during canvas exploration gesture.
    @State private var worldDragTranslation: CGSize = .zero

    private var activeWorldOffset: CGSize {
        CGSize(
            width: worldPanOffset.width + worldDragTranslation.width,
            height: worldPanOffset.height + worldDragTranslation.height
        )
    }

    private var worldTravelDistance: CGFloat {
        hypot(activeWorldOffset.width, activeWorldOffset.height)
    }

    var body: some View {
        ZStack {
            // ── Background ────────────────────────────────────────────────
            Color(hex: "#13131a").ignoresSafeArea()

            // ── Radial bubble field ───────────────────────────────────────
            if !experiences.isEmpty {
                GeometryReader { geo in
                    let geom = HistoryCanvasGeometry(viewport: geo.size, totalItems: experiences.count)
                    let world = activeWorldOffset

                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        ZStack {
                            // ── Background interactive canvas surface ─────────────
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 4)
                                        .onChanged { v in
                                            worldDragTranslation = v.translation
                                        }
                                        .onEnded { v in
                                            let maxExtent = max(geo.size.width, geo.size.height) * 1.5
                                            let rawX = worldPanOffset.width + v.translation.width
                                            let rawY = worldPanOffset.height + v.translation.height
                                            let dist = hypot(rawX, rawY)
                                            let clampedX: CGFloat
                                            let clampedY: CGFloat
                                            if dist > maxExtent {
                                                let scale = maxExtent / dist
                                                clampedX = rawX * scale
                                                clampedY = rawY * scale
                                            } else {
                                                clampedX = rawX
                                                clampedY = rawY
                                            }
                                            withAnimation(.spring(response: 0.48, dampingFraction: 0.76)) {
                                                worldPanOffset = CGSize(width: clampedX, height: clampedY)
                                                worldDragTranslation = .zero
                                            }
                                        }
                                )

                            // ── Faint constellation orbit guides ──────────────────
                            Circle()
                                .stroke(
                                    Color.white.opacity(0.06),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 8])
                                )
                                .frame(width: geom.innerOrbitRadius * 2, height: geom.innerOrbitRadius * 2)
                                .offset(x: world.width, y: world.height)
                                .allowsHitTesting(false)

                            if experiences.count > 5 {
                                Circle()
                                    .stroke(
                                        Color.white.opacity(0.04),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 10])
                                    )
                                    .frame(
                                        width: (geom.innerOrbitRadius + geom.ringSpacing) * 2,
                                        height: (geom.innerOrbitRadius + geom.ringSpacing) * 2
                                    )
                                    .offset(x: world.width, y: world.height)
                                    .allowsHitTesting(false)
                            }

                            // ── Floating memory bubbles ───────────────────────────
                            ForEach(Array(experiences.enumerated()), id: \.element.id) { idx, exp in
                                let drag     = dragOffsets[exp.id] ?? .zero
                                let deleting = deletingIDs.contains(exp.id)
                                let base     = positions[exp.id] ?? geom.position(for: idx)
                                let float    = floatingOffset(id: exp.id, t: t)

                                HistoryBubble(experience: exp, size: geom.bubbleSize)
                                    .scaleEffect(deleting ? 0.01 : 1.0)
                                    .opacity(deleting ? 0.0 : 1.0)
                                    .animation(
                                        .spring(response: 0.5, dampingFraction: 0.6),
                                        value: deleting
                                    )
                                    .offset(
                                        x: base.x + drag.width  + world.width  + CGFloat(float.x),
                                        y: base.y + drag.height + world.height + CGFloat(float.y)
                                    )
                                    .contentShape(Circle())
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
                                    .accessibilityHint("Double tap to open, long press to remove")
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
                    .onAppear {
                        updatePositions(for: experiences, in: geom)
                    }
                    .onChange(of: experiences) { _, newValue in
                        let updatedGeom = HistoryCanvasGeometry(viewport: geo.size, totalItems: newValue.count)
                        updatePositions(for: newValue, in: updatedGeom)
                    }
                    .onChange(of: geo.size) { _, newSize in
                        let updatedGeom = HistoryCanvasGeometry(viewport: newSize, totalItems: experiences.count)
                        updatePositions(for: experiences, in: updatedGeom)
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

            // ── Top Navigation Bar ─────────────────────────────────────────
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

            // ── Floating Recenter Compass Pill ────────────────────────────
            if worldTravelDistance > 48 {
                VStack {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.76)) {
                            worldPanOffset = .zero
                            worldDragTranslation = .zero
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "scope")
                                .font(.system(size: 13, weight: .semibold))
                            Text("recenter")
                                .font(Theme.monoFont(size: 12))
                        }
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(Color(hex: "#1b1b24").opacity(0.85))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.18), lineWidth: 0.75)
                                )
                                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .padding(.bottom, 36)
                    .accessibilityLabel("Recenter memory constellation")
                }
            }
        }
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

    private func updatePositions(for exps: [SavedExperience], in geom: HistoryCanvasGeometry) {
        withAnimation(.spring(response: 0.72, dampingFraction: 0.74)) {
            for (idx, exp) in exps.enumerated() {
                positions[exp.id] = geom.position(for: idx)
            }
        }
        let ids = Set(exps.map(\.id))
        positions = positions.filter { ids.contains($0.key) }
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

    private var textScale: CGFloat {
        size / 168.0
    }

    private var titleFontSize: CGFloat {
        max(12.0, min(17.0, 17.0 * textScale))
    }

    private var horizontalPadding: CGFloat {
        max(8.0, 16.0 * textScale)
    }

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
                .font(.system(size: titleFontSize, weight: .light, design: .serif))
                .foregroundColor(experience.contrastTextColor)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
                .padding(.horizontal, horizontalPadding)
                .frame(width: size * 0.74)
        }
        .frame(width: size, height: size)
    }
}
