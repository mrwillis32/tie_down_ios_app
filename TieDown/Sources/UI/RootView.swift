import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var lock: BiometricLock

    var body: some View {
        ZStack {
            switch auth.state {
            case .loading:
                SplashView()
            case let .signedOut(message):
                LoginView(notice: message)
                    .transition(.opacity)
            case .signedIn:
                MainTabView()
                    .transition(.opacity)
            }

            if lock.isLocked, auth.session != nil {
                LockView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.state)
        .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
        .alert("Use \(lock.biometryName) to unlock TieDown?", isPresented: $model.showFaceIDOffer) {
            Button("Turn On") { Task { _ = await lock.enable() } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("You can change this anytime in More › App Settings.")
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Color("BrandNavy").ignoresSafeArea()
            VStack(spacing: 16) {
                BrandMark(size: 72)
                ProgressView().tint(.white)
            }
        }
    }
}

/// The TieDown "T" mark (matches apps/app/public/favicon.svg).
struct BrandMark: View {
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .overlay(
                Text("T")
                    .font(.system(size: size * 0.66, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}
