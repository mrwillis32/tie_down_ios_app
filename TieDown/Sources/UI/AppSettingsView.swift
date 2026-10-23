import SwiftUI
import UserNotifications

struct AppSettingsView: View {
    @EnvironmentObject private var lock: BiometricLock
    @EnvironmentObject private var terminal: TerminalManager
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var printers: PrinterManager
    @StateObject private var push = PushManager.shared

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
                    NavigationLink {
                        CardReaderSettingsView()
                    } label: {
                        HStack {
                            Label("Card Readers", systemImage: "creditcard.and.123")
                            Spacer()
                            Text(terminal.connectedReaderName ?? "Not connected")
                                .foregroundStyle(terminal.connectedReader == nil ? Color.secondary : Color.green)
                                .lineLimit(1)
                        }
                    }
                    NavigationLink {
                        PrinterSettingsView()
                    } label: {
                        HStack {
                            Label("Printers", systemImage: "printer")
                            Spacer()
                            Text(printers.defaultPrinter?.name ?? "None")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Point of Sale")
                } footer: {
                    Text("Tap to Pay, Bluetooth card readers, and AirPrint, network or Bluetooth receipt printers.")
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
