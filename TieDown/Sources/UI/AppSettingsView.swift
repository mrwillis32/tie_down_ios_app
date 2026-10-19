import SwiftUI
import UserNotifications

struct AppSettingsView: View {
    @EnvironmentObject private var lock: BiometricLock
    @EnvironmentObject private var terminal: TerminalManager
    @EnvironmentObject private var auth: AuthService
    @StateObject private var push = PushManager.shared
    @State private var tapToPayError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: lockBinding) {
                    Label("Require \(lock.biometryName)", systemImage: lock.biometryName == "Touch ID" ? "touchid" : "faceid")
                }
                .disabled(!lock.isAvailable)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks TieDown when you return to it after 30 seconds away.")
            }

            Section("Notifications") {
                HStack {
                    Label("Push notifications", systemImage: "bell.badge")
                    Spacer()
                    Text(pushStatus).foregroundStyle(.secondary)
                }
                if push.authorization == .denied {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else if push.authorization == .notDetermined {
                    Button("Turn On Notifications") { Task { await push.requestAndRegister() } }
                }
            }

            if auth.session?.portal == .staff {
                Section {
                    HStack {
                        Label("Tap to Pay on iPhone", systemImage: "wave.3.right.circle")
                        Spacer()
                        if terminal.isConnecting {
                            ProgressView()
                        } else {
                            Text(terminal.connectedReader == nil ? "Not connected" : "Ready")
                                .foregroundStyle(terminal.connectedReader == nil ? Color.secondary : Color.green)
                        }
                    }
                    if terminal.connectedReader == nil {
                        Button("Set Up Tap to Pay") {
                            tapToPayError = nil
                            Task {
                                do { try await terminal.prepare() } catch { tapToPayError = error.localizedDescription }
                            }
                        }
                        .disabled(terminal.isConnecting)
                    }
                    if let message = tapToPayError ?? terminal.statusMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Payments")
                } footer: {
                    Text("Accept contactless cards and Apple Pay right on this iPhone. Requires iPhone XS or later.")
                }
            }

            Section("About") {
                LabeledContent("Version", value: "\(UserAgent.appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                if AppEnvironment.current != .production {
                    LabeledContent("Environment", value: AppEnvironment.current.rawValue)
                }
                Link("Privacy Policy", destination: URL(string: "https://tiedown.us/privacy")!)
            }
        }
        .navigationTitle("App Settings")
        .task { await push.refreshAuthorization() }
    }

    private var pushStatus: String {
        switch push.authorization {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        default: "Not set"
        }
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { lock.isEnabled },
            set: { newValue in
                if newValue {
                    Task { _ = await lock.enable() }
                } else {
                    lock.isEnabled = false
                }
            }
        )
    }
}

struct LockView: View {
    @EnvironmentObject private var lock: BiometricLock
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 20) {
                BrandMark(size: 64)
                Text("TieDown is locked").font(.title3.bold())
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(lock.biometryName)", systemImage: "lock.open")
                        .frame(minWidth: 220, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button("Sign Out", role: .destructive) {
                    Task { await model.signOut() }
                }
                .font(.footnote)
            }
        }
        .task { await lock.unlock() }
    }
}
