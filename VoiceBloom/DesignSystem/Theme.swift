import SwiftUI
import UIKit

/// App colors. Each one has light and dark variants in Assets.xcassets.
///
/// The palette is based on the Okabe–Ito colorblind-safe set: the pitch line
/// (blue) and the target zone (bluish green) stay distinguishable for the common
/// kinds of color blindness, and meaning is always repeated with text or shape.
@MainActor
enum Theme {
    static let pitchLine = Color("PitchLine")
    static let targetZone = Color("TargetZone")
    static let warning = Color("Warning")
    static let backgroundTint = Color("BackgroundTint")
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let cornerRadius: CGFloat = 22
}

/// Soft tinted backdrop used behind the main screens.
struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Theme.backgroundTint, Theme.groupedBackground],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }
}

private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                Theme.cardBackground,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            )
    }
}

extension View {
    /// Rounded card used for meters and panels.
    func cardStyle() -> some View {
        modifier(CardModifier())
    }
}
