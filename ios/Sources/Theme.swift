import SwiftUI
import UIKit

enum AppLayout {
    static let pageInset: CGFloat = 16
    /// The integrated dock is about 132 pt while the mini-player is present.
    /// Scroll containers
    /// do not reliably inherit that custom inset, so reserve it explicitly plus
    /// 16 pt of breathing room for the final row/shelf.
    static let scrollEndPadding: CGFloat = 148
    static let dockSpacing: CGFloat = 8
    static let dockBottomPadding: CGFloat = 4
}

// MARK: - Haptics (reserved for meaningful moments — §13 utility)

enum Haptics {
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func rigid()  { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func soft()   { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success(){ UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

// MARK: - Motion

extension Animation {
    /// Critically damped, snappy — the house default (apple-design §4).
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 1.0)
    /// A little overshoot — only for momentum-carrying interactions.
    static let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.8)
    /// Geometry-preserving navigation and surface changes.
    static let settled = Animation.easeInOut(duration: 0.26)
}

/// Press feedback on pointer-down, springs back on release (§1, §3).
struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.snappy, value: configuration.isPressed)
    }
}

// MARK: - Artwork building blocks

/// Square, correctly-clipped artwork — fixes the grid bleed. The image fills and
/// is clipped to the square frame instead of dictating its own size.
struct SquareArtwork: View {
    let url: URL?
    var corner: CGFloat = 14
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ArtworkView(url: url) }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Blurred, dimmed artwork that fills the screen behind Now Playing.
struct AmbientBackground: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            ArtworkView(url: url)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 32)
                .overlay(colorScheme == .dark ? .ultraThinMaterial : .regularMaterial)
                .overlay(
                    LinearGradient(colors: [
                        Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.22 : 0.36),
                        Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.72 : 0.82)
                    ],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

/// Neutral Liquid Glass with enough density to remain legible over artwork.
private struct BalancedGlassCard: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension View {
    func balancedGlassCard() -> some View {
        modifier(BalancedGlassCard())
    }
}
