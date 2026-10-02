import Foundation
import LocalAuthentication
import Observation

/// Optional Face ID / passcode lock (SPEC section 13).
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    private(set) var errorMessage: String?
    /// Mirrors the profile setting.
    var isEnabled = false {
        didSet {
            if !isEnabled {
                isLocked = false
            }
        }
    }

    /// "Face ID", "Touch ID", "Optic ID" or "Passcode".
    static var methodName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Passcode"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// False when the device has no passcode set (the lock can't work).
    static var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Locks when the app goes to the background (if enabled).
    func lockIfEnabled() {
        if isEnabled {
            isLocked = true
        }
    }

    /// Asks for Face ID (falling back to the passcode).
    /// - Returns: True when the user authenticated.
    @discardableResult
    func authenticate(reason: String = "Unlock Chirp") async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        errorMessage = nil
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode on this device: the lock can't protect anything.
            errorMessage = "Set a passcode in Settings to use the app lock."
            isLocked = false
            return false
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                isLocked = false
            }
            return success
        } catch {
            errorMessage = "Not unlocked. Tap Unlock to try again."
            return false
        }
    }
}
