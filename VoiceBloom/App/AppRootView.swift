import Foundation
import SwiftData
import SwiftUI

/// Chooses between onboarding (first launch) and the tab bar, applies the
/// theme, and covers the app while it's locked.
struct AppRootView: View {
    @Environment(AppLock.self) private var appLock
    @Environment(LiveVoiceMonitor.self) private var monitor
    @Query(sort: \UserProfile.createdAt) private var profiles: [UserProfile]
    @State private var hasCheckedLock = false

    /// UI tests launch with this argument to go straight to the tab bar.
    static let skipOnboardingArgument = "-skipOnboarding"

    private var profile: UserProfile? { profiles.first }

    private var showsOnboarding: Bool {
        guard let profile else { return false }
        return !profile.hasCompletedOnboarding && !ProcessInfo.processInfo.arguments.contains(Self.skipOnboardingArgument)
    }

    var body: some View {
        Group {
            if let profile, showsOnboarding {
                OnboardingView(profile: profile)
            } else {
                RootTabView()
            }
        }
        .overlay {
            if appLock.isLocked {
                LockScreenView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(profile?.theme.colorScheme)
        .onAppear {
            guard !hasCheckedLock else { return }
            hasCheckedLock = true
            appLock.isEnabled = profile?.faceIDLockEnabled ?? false
            appLock.lockIfEnabled()
            if let profile {
                monitor.applyReferences(profile.personalReferences)
            }
        }
        .onChange(of: profile?.faceIDLockEnabled) { _, enabled in
            appLock.isEnabled = enabled ?? false
        }
    }
}

/// Covers everything until Face ID (or the passcode) unlocks the app.
private struct LockScreenView: View {
    @Environment(AppLock.self) private var appLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThickMaterial)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("VoiceBloom is locked")
                    .font(.title2.weight(.semibold))
                Button {
                    Task { await appLock.authenticate() }
                } label: {
                    Label("Unlock with \(AppLock.methodName)", systemImage: "faceid")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(appLock.isAuthenticating)
                if let message = appLock.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .task {
            // Face ID only works while the app is on screen.
            if scenePhase == .active {
                await appLock.authenticate()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await appLock.authenticate() }
            }
        }
    }
}

extension AppTheme {
    /// nil follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
