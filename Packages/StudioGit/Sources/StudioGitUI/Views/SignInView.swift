public import SwiftUI
public import Forge

/// Sign in to GitHub, GitHub Enterprise, GitLab.com or a self-hosted GitLab
/// with the device flow (a code to enter in the browser) or a personal
/// access token.
public struct SignInView: View {
    @Bindable var model: SignInModel
    var onSignedIn: (ForgeAccount) -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.gitTheme) private var theme

    public init(model: SignInModel, onSignedIn: @escaping (ForgeAccount) -> Void = { _ in }) {
        self.model = model
        self.onSignedIn = onSignedIn
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .waitingForApproval(let authorization):
                DeviceCodeView(authorization: authorization, hostName: model.host?.kind.displayName ?? "", cancel: model.cancel)
            case .signedIn(let account):
                signedIn(account)
            default:
                form
            }
        }
        .navigationTitle("Add Account")
        .onChange(of: model.phase) { _, phase in
            if case .signedIn(let account) = phase { onSignedIn(account) }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Service", selection: $model.target) {
                    ForEach(SignInModel.Target.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.target.needsURL {
                    TextField(model.target == .gitHubEnterprise ? "https://github.example.com" : "https://gitlab.example.com",
                              text: $model.serverURL)
                        .plainTextEntry()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                }
            } footer: {
                if model.target == .selfHostedGitLab {
                    Text("Device sign-in needs GitLab 17.9 or later. Older servers: use a personal access token.")
                }
            }

            Section {
                Button {
                    model.startDeviceFlow()
                } label: {
                    HStack {
                        Label("Sign in with \(model.host?.kind.displayName ?? "browser")", systemImage: "person.badge.key")
                        Spacer()
                        if model.phase == .requestingCode { ProgressView() }
                    }
                }
                .disabled(model.clientID == nil || model.host == nil || model.phase == .requestingCode)
                if model.host != nil, model.clientID == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No OAuth client ID is set for this server. Register an OAuth app with the device flow enabled and paste its client ID here.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("OAuth client ID", text: $model.clientIDDraft).plainTextEntry()
                            Button("Save") { model.saveClientID() }
                                .disabled(model.clientIDDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            } header: {
                Text("Recommended")
            } footer: {
                Text("You get a short code to enter on the website. No password is typed in this app.")
            }

            Section {
                SecureField("Personal access token", text: $model.personalAccessToken)
                    .plainTextEntry()
                HStack {
                    if let host = model.host {
                        Button("Create a Token…") { openURL(host.personalAccessTokenURL) }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("Sign In") { model.signInWithToken() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.personalAccessToken.isEmpty || model.host == nil || model.phase == .signingIn)
                }
            } header: {
                Text("Personal Access Token")
            } footer: {
                Text(tokenScopes)
            }

            if case .failed(let message) = model.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button("Try Again") { model.reset() }
                }
            }
            if model.phase == .signingIn {
                Section { HStack { ProgressView(); Text("Signing in…") } }
            }
        }
    }

    private var tokenScopes: String {
        switch model.target {
        case .github, .gitHubEnterprise:
            return "Scopes: repo, read:org, workflow, write:public_key, write:ssh_signing_key. Stored in the Keychain on this device only."
        case .gitlab, .selfHostedGitLab:
            return "Scopes: api, read_user, write_repository. Stored in the Keychain on this device only."
        }
    }

    private func signedIn(_ account: ForgeAccount) -> some View {
        ContentUnavailableView {
            Label("Signed in as \(account.user.login)", systemImage: "checkmark.circle.fill")
        } description: {
            Text(account.host.hostname)
        } actions: {
            Button("Add Another Account") { model.reset() }
        }
    }
}

/// The device-flow code screen.
public struct DeviceCodeView: View {
    let authorization: DeviceAuthorization
    let hostName: String
    let cancel: () -> Void
    @State private var copied = false
    @Environment(\.openURL) private var openURL
    @Environment(\.gitTheme) private var theme

    public init(authorization: DeviceAuthorization, hostName: String, cancel: @escaping () -> Void) {
        self.authorization = authorization
        self.hostName = hostName
        self.cancel = cancel
    }

    public var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 52))
                .foregroundStyle(theme.accent)
            VStack(spacing: 8) {
                Text("Enter this code on \(hostName)").font(.title2.weight(.semibold))
                Text(authorization.verificationURI.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(authorization.userCode)
                .font(.system(size: 54, weight: .bold, design: .monospaced))
                .kerning(6)
                .textSelection(.enabled)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Code \(authorization.userCode.map(String.init).joined(separator: " "))")
            HStack(spacing: 12) {
                Button {
                    Pasteboard.copy(authorization.userCode)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.bordered)
                Button {
                    Pasteboard.copy(authorization.userCode)
                    openURL(authorization.verificationURIComplete ?? authorization.verificationURI)
                } label: {
                    Label("Copy and Open \(hostName)", systemImage: "safari").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for you to approve…").foregroundStyle(.secondary)
            }
            Text("The code expires \(authorization.expiresAt.formatted(.relative(presentation: .named))).")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
