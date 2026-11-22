import SwiftUI

/// The app's shared motion: soft, short and never bouncy. Everything here stands still when Reduce Motion is on.
enum Motion {
    /// Most state changes: a genre picked, a tab switched, a card appearing.
    static let gentle = Animation.smooth(duration: 0.32)
    /// Small feedback, like a hover.
    static let quick = Animation.smooth(duration: 0.18)

    /// `gentle`, or nothing when the person asked for less motion.
    static func gentle(_ reduce: Bool) -> Animation? { reduce ? nil : gentle }
}

// MARK: - Skeletons

/// A placeholder block in the shape of the content that's on its way.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var corner: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(.primary.opacity(0.08))
            .frame(width: width, height: height)
            .shimmer()
    }
}

/// A row of placeholder cards, for shelves while they load.
struct SkeletonShelf: View {
    var count = 5
    var cardWidth: CGFloat = 152
    var cardHeight: CGFloat = 228
    var corner: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: cardWidth, height: cardHeight, corner: corner)
                    SkeletonBlock(width: cardWidth * 0.8, height: 12, corner: 4)
                    SkeletonBlock(width: cardWidth * 0.5, height: 10, corner: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// A soft light sweep across a placeholder. Still when Reduce Motion is on.
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    /// The loading sweep used by skeleton placeholders.
    func shimmer() -> some View { modifier(Shimmer()) }
}

// MARK: - Hover and appearance

/// Cards lift a little under the pointer. Mac only; nothing moves when Reduce Motion is on.
private struct HoverLift: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var scale: CGFloat
    /// The card's own copy of "pointer is over me" (for its border), fed by this one hover area.
    var external: Binding<Bool>? = nil

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.28 : 0), radius: hovering ? 14 : 0, y: hovering ? 8 : 0)
            .animation(Motion.quick, value: hovering)
            #if os(macOS)
            .onHover { hovering = $0; if external?.wrappedValue != $0 { external?.wrappedValue = $0 } }
            #else
            // iPad pointer: only the card's own border follows it (nothing lifts off Mac).
            .onHover { if external?.wrappedValue != $0 { external?.wrappedValue = $0 } }
            #endif
    }
}

/// Content fades and rises into place the first time it appears.
private struct AppearFade: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    var delay: Double

    /// `enabled: false` shows the content at once, for cards that come into view while scrolling (every fade is an
    /// animation the whole screen is redrawn for on each frame, so a long scroll through shelves added up).
    init(delay: Double, enabled: Bool) {
        self.delay = delay
        _shown = State(initialValue: !enabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true } else { withAnimation(Motion.gentle.delay(delay)) { shown = true } }
            }
    }
}

extension View {
    /// A small lift and shadow under the pointer.
    func hoverLift(_ scale: CGFloat = 1.03) -> some View { modifier(HoverLift(scale: scale)) }
    /// The same, for a card that also needs to know it is hovered: one hover area instead of two.
    func hoverLift(_ scale: CGFloat = 1.03, hovering: Binding<Bool>) -> some View { modifier(HoverLift(scale: scale, external: hovering)) }
    /// Fade and rise into place on first appearance.
    func appearFade(delay: Double = 0, enabled: Bool = true) -> some View { modifier(AppearFade(delay: delay, enabled: enabled)) }
}
