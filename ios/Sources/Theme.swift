import SwiftUI
import UIKit

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

/// Blurred, dimmed artwork that fills the screen behind Now Playing (§12 materials,
/// ambient artwork). Falls back to a calm gradient when there's no cover.
struct AmbientBackground: View {
    let url: URL?
    var body: some View {
        ZStack {
            Color.black
            ArtworkView(url: url)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 32)
                .overlay(.ultraThinMaterial)            // reliable frost over the photo
                .overlay(
                    LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.75)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(Color.black.opacity(0.15))     // keep white text legible
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}
