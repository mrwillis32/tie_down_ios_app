import SafariServices
import SwiftUI

struct LoginView: View {
    let notice: String?

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var network: NetworkMonitor

    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var safariURL: URL?
    @State private var environment = AppEnvironment.current
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isSubmitting
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    BrandMark(size: 64)
                    Text("Welcome to TieDown")
                        .font(.title.bold())
                    Text("Sign in to manage your operation on the go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)

                if !network.isOnline {
                    Label("You're offline", systemImage: "wifi.slash")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                }

                if let message = errorMessage ?? notice {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(
                            (errorMessage == nil ? Color.secondary : Color.red).opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }

                VStack(spacing: 14) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .email)
                        .onSubmit {
                            // Moving focus inside onSubmit leaves the SecureField half-focused and
                            // it drops the first keystroke; hand focus over on the next run loop.
                            DispatchQueue.main.async { focused = .password }
                        }
                        .fieldStyle()
                        .id(Field.email)

                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused, equals: .password)
                        .onSubmit(submit)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    .fieldStyle()

                    Button(action: submit) {
                        ZStack {
                            Text("Sign In").opacity(isSubmitting ? 0 : 1)
                            if isSubmitting { ProgressView().tint(.white) }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                    .disabled(!canSubmit)
                    .id(Self.submitAnchor)

                    Button("Forgot password?") {
                        safariURL = AppEnvironment.current.appBaseURL.appendingPathComponent("forgot-password")
                    }
                    .font(.footnote.weight(.medium))
                }

                Spacer(minLength: 24)

                HStack(spacing: 4) {
                    Text("New customer?").foregroundStyle(.secondary)
                    Button("Create an account") {
                        safariURL = AppEnvironment.current.appBaseURL.appendingPathComponent("customer-signup")
                    }
                }
                .font(.footnote)
                .padding(.bottom, AppEnvironment.canSwitch ? 8 : 24)

                if AppEnvironment.canSwitch {
                    serverPicker.padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: focused) { _, field in
            guard field != nil else { return }
            // On iPad landscape and small iPhones the keyboard covers the password field and the
            // Sign In button. Once the keyboard is up, scroll so both fields and the button show.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.submitAnchor, anchor: .bottom)
                }
            }
        }
        }
        .sheet(item: $safariURL) { url in
            SafariView(url: url).ignoresSafeArea()
        }
    }

    private static let submitAnchor = "sign-in-button"

    /// Test builds only: choose which TieDown servers to sign in to. Remembered across launches.
    private var serverPicker: some View {
        Menu {
            Picker("Server", selection: $environment) {
                ForEach(AppEnvironment.allCases) { env in
                    Text("\(env.displayName) — \(env.apiBaseURL.host() ?? "")").tag(env)
                }
            }
        } label: {
            Label("Server: \(environment.displayName)", systemImage: "server.rack")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .onChange(of: environment) { _, newValue in
            AppEnvironment.select(newValue)
            errorMessage = nil
        }
        .accessibilityHint("Changes which TieDown servers this test build connects to")
    }

    private func submit() {
        guard canSubmit else { return }
        focused = nil
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await auth.signIn(email: email, password: password)
                password = ""
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private extension View {
    func fieldStyle() -> some View {
        padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}
