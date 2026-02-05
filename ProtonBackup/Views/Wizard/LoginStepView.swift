import SwiftUI

/// Login step: authenticate with Proton Drive credentials.
struct LoginStepView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var wizardState: WizardState

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var testingConnection = false
    @State private var connectionSuccess = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.badge.key")
                .font(.system(size: 40))
                .foregroundColor(.protonPurple)

            Text("Sign in to Proton Drive")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Your credentials are stored securely in the macOS Keychain and never logged.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            VStack(spacing: 12) {
                TextField("Proton username or email", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disabled(isLoading || wizardState.isAuthenticated)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .disabled(isLoading || wizardState.isAuthenticated)
                    .onSubmit {
                        signIn()
                    }
            }
            .frame(maxWidth: 320)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.statusRed)
                    .frame(maxWidth: 350)
            }

            if wizardState.isAuthenticated {
                Label("Signed in as \(wizardState.username)", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.statusGreen)

                Button("Test Connection") {
                    testConnection()
                }
                .disabled(testingConnection)

                if connectionSuccess {
                    Label("Connection verified", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.statusGreen)
                }
            } else {
                Button {
                    signIn()
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 80)
                    } else {
                        Text("Sign In")
                            .frame(width: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.protonPurple)
                .disabled(username.isEmpty || password.isEmpty || isLoading)
            }

            Spacer()
        }
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                _ = try await appState.authService.authenticate(
                    username: username,
                    password: password
                )

                wizardState.isAuthenticated = true
                wizardState.username = username
                isLoading = false

                appState.logService.log(.info, category: .auth, message: "Successfully signed in as \(username)")
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                appState.logService.log(.error, category: .auth,
                                         message: "Sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    private func testConnection() {
        testingConnection = true
        connectionSuccess = false

        Task {
            do {
                let success = try await appState.authService.testConnection()
                connectionSuccess = success
                if !success {
                    errorMessage = "Connection test failed. Please check your credentials."
                }
            } catch {
                errorMessage = "Connection test error: \(error.localizedDescription)"
            }
            testingConnection = false
        }
    }
}
