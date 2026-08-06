import SwiftUI
import UIKit

enum AppLayout {
    static let pageInset: CGFloat = 20
    /// The integrated dock is about 132 pt while the mini-player is present.
    /// Scroll containers
    /// do not reliably inherit that custom inset, so reserve it explicitly plus
    /// 16 pt of breathing room for the final row/shelf.
    static let scrollEndPadding: CGFloat = 148
    static let dockSpacing: CGFloat = 8
    static let dockBottomPadding: CGFloat = 4
}

enum AppTheme {
    static let accent = Color.indigo
    static let accentSecondary = Color.indigo.opacity(0.85) // used for pressed/secondary accent states
    static let cardRadius: CGFloat = 16
    static let compactRadius: CGFloat = 12
    static let controlHeight: CGFloat = 50

    static let screenBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedSurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator)
    /// Single source for placeholder artwork tint
    static let placeholderArtwork = Color(uiColor: .secondarySystemFill)

    static func glassTint(for colorScheme: ColorScheme) -> Color {
        Color(uiColor: .systemBackground)
            .opacity(colorScheme == .dark ? 0.30 : 0.20)
    }
}

// MARK: - Haptics (reserved for meaningful moments — §13 utility)

enum Haptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    static func prepare() {
        lightGenerator.prepare(); rigidGenerator.prepare()
        softGenerator.prepare(); selectionGenerator.prepare()
        notificationGenerator.prepare()
    }

    static func light()  { lightGenerator.impactOccurred(); lightGenerator.prepare() }
    static func rigid()  { rigidGenerator.impactOccurred(); rigidGenerator.prepare() }
    static func soft()   { softGenerator.impactOccurred(); softGenerator.prepare() }
    static func select() { selectionGenerator.selectionChanged(); selectionGenerator.prepare() }
    static func success(){ notificationGenerator.notificationOccurred(.success); notificationGenerator.prepare() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.snappy, value: configuration.isPressed)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: AppTheme.controlHeight)
                .background(
                    isEnabled
                        ? AppTheme.accent.opacity(colorScheme == .dark ? 0.30 : 0.42)
                        : Color(uiColor: .tertiarySystemFill).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: AppTheme.compactRadius, style: .continuous)
                )
                .glassEffect(
                    .regular
                        .tint(isEnabled ? AppTheme.accent.opacity(0.72) : AppTheme.glassTint(for: colorScheme))
                        .interactive(isEnabled),
                    in: .rect(cornerRadius: AppTheme.compactRadius)
                )
                .opacity(configuration.isPressed ? 0.88 : 1)
        } else {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: AppTheme.controlHeight)
                .background(
                    isEnabled
                        ? (configuration.isPressed ? AppTheme.accent.opacity(0.78) : AppTheme.accent)
                        : Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: AppTheme.compactRadius, style: .continuous)
                )
                .opacity(configuration.isPressed ? 0.9 : 1)
        }
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: AppTheme.controlHeight)
                .background(
                    AppTheme.glassTint(for: colorScheme).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: AppTheme.compactRadius, style: .continuous)
                )
                .glassEffect(
                    .regular
                        .tint(AppTheme.glassTint(for: colorScheme))
                        .interactive(isEnabled),
                    in: .rect(cornerRadius: AppTheme.compactRadius)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
        } else {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: AppTheme.controlHeight)
                .background(
                    configuration.isPressed ? AppTheme.elevatedSurface : AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: AppTheme.compactRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.compactRadius, style: .continuous)
                        .stroke(AppTheme.separator.opacity(0.45), lineWidth: 0.5)
                }
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

struct SectionTitle: View {
    let title: String
    var action: String? = nil
    var actionHandler: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .tracking(-0.2)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let action, let actionHandler {
                Button(action, action: actionHandler)
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Color(uiColor: UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)))
            Image("SnagLogo")
                .resizable()
                .scaledToFit()
                .scaleEffect(1.5)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: size * 0.16, y: size * 0.07)
        .accessibilityHidden(true)
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
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(
                    AppTheme.glassTint(for: colorScheme).opacity(0.48),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassEffect(
                    .regular.tint(AppTheme.glassTint(for: colorScheme)),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

extension View {
    func balancedGlassCard() -> some View {
        modifier(BalancedGlassCard(cornerRadius: 18))
    }

    /// A quiet, non-reactive glass surface for dense playback controls. The
    /// controls provide their own pressed feedback, so the whole console should
    /// not distort when a single button is touched.
    @ViewBuilder
    func playerControlSurface(cornerRadius: CGFloat = 30) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(
                    Color(uiColor: .systemBackground).opacity(0.22),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
    }


    @ViewBuilder
    func groupedSurface(cornerRadius: CGFloat = AppTheme.cardRadius) -> some View {
        if #available(iOS 26.0, *) {
            modifier(BalancedGlassCard(cornerRadius: cornerRadius))
        } else {
            self
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(AppTheme.separator.opacity(0.35), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    func groupedGlassEffects(spacing: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    @ViewBuilder
    func appScreenBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.background(AppScreenBackdrop())
        } else {
            self
                .background(AppTheme.screenBackground.ignoresSafeArea())
                .toolbarBackground(AppTheme.screenBackground, for: .navigationBar)
        }
    }
}

private struct AppScreenBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AppTheme.screenBackground
            RadialGradient(
                colors: [
                    AppTheme.accent.opacity(colorScheme == .dark ? 0.10 : 0.07),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.018 : 0.16),
                    .clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}
