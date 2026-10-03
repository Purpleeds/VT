import SwiftUI
import UIKit

/// Lets single screens (the Pitch Track game, SPEC section 22.2) rotate to
/// landscape while the rest of the app stays portrait.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    /// Allows landscape (or goes back to portrait only).
    static func allowLandscape(_ allowed: Bool) {
        let newMask: UIInterfaceOrientationMask = allowed ? .allButUpsideDown : .portrait
        guard newMask != mask else { return }
        mask = newMask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            if !allowed {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}
