import SwiftUI

/// Friendly placeholder for tabs that later build stages fill in.
struct ComingSoonView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(message)
            }
            .background { AppBackground() }
            .navigationTitle(title)
        }
    }
}
