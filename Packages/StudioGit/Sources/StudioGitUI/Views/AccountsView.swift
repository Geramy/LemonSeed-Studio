public import SwiftUI
import GitKit
import Forge

/// Signed-in accounts, the commit identity, and SSH keys.
public struct AccountsView: View {
    @Bindable var services: GitServices
    @State private var accounts: [ForgeAccount] = []
    @State private var showSignIn = false
    @State private var signInModel: SignInModel?
    @State private var errorMessage: String?

    public init(services: GitServices) {
        self.services = services
    }

    public var body: some View {
        Form {
            Section("Accounts") {
                if accounts.isEmpty {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                }
                ForEach(accounts) { account in
                    HStack(spacing: 12) {
                        AsyncImage(url: account.user.avatarURL) { image in
                            image.resizable()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(account.user.name ?? account.user.login).font(.body.weight(.medium))
                            Text("\(account.user.login) · \(account.host.hostname) · \(account.method == .oauthDevice ? "OAuth" : "Token")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Sign Out", role: .destructive) { signOut(account) }
                    }
                    .contextMenu {
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { signOut(account) }
                    }
                }
                Button("Add Account…", systemImage: "plus") {
                    signInModel = SignInModel(accounts: services.accounts)
                    showSignIn = true
                }
            }
            Section {
                TextField("Name", text: $services.authorName)
                TextField("Email", text: $services.authorEmail).plainTextEntry()
            } header: {
                Text("Commit Identity")
            } footer: {
                Text("Used as author and committer. Leave empty to use the repository's user.name and user.email.")
            }
            Section {
                NavigationLink("SSH Keys") { SSHKeysView(services: services) }
                Toggle("Sign Commits with SSH Key", isOn: $services.signCommits)
                    .disabled(services.defaultSSHKeyID == nil)
            } footer: {
                Text("Signed commits show as Verified on GitHub and GitLab once the key is uploaded as a signing key.")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Accounts")
        .task { await reload() }
        .sheet(isPresented: $showSignIn, onDismiss: { Task { await reload() } }) {
            NavigationStack {
                if let signInModel {
                    SignInView(model: signInModel) { _ in Task { await reload() } }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { signInModel.cancel(); showSignIn = false }
                            }
                        }
                }
            }
        }
    }

    private func reload() async {
        accounts = await services.accounts.accounts()
    }

    private func signOut(_ account: ForgeAccount) {
        Task {
            do { try await services.accounts.signOut(account.id) } catch { errorMessage = "\(error)" }
            await reload()
        }
    }
}

/// Generate, copy and upload SSH keys.
public struct SSHKeysView: View {
    @Bindable var services: GitServices
    @State private var keys: [SSHKeyInfo] = []
    @State private var accounts: [ForgeAccount] = []
    @State private var newLabel = ""
    @State private var newKind: SSHKeyKind = SecureEnclaveSSHKey.isAvailable ? .secureEnclave : .ed25519
    @State private var message: String?
    @State private var uploading: UUID?
    @Environment(\.gitTheme) private var theme

    public init(services: GitServices) {
        self.services = services
    }

    public var body: some View {
        Form {
            Section {
                ForEach(keys) { key in keyRow(key) }
                if keys.isEmpty { Text("No SSH keys yet.").foregroundStyle(.secondary) }
            } header: {
                Text("Keys on This iPad")
            }
            Section {
                TextField("Label (e.g. Studio iPad)", text: $newLabel)
                Picker("Type", selection: $newKind) {
                    Text("Secure Enclave (P-256)").tag(SSHKeyKind.secureEnclave)
                    Text("Ed25519").tag(SSHKeyKind.ed25519)
                }
                Button("Generate Key", systemImage: "key.fill") { generate() }
                    .disabled(newKind == .secureEnclave && !SecureEnclaveSSHKey.isAvailable)
            } header: {
                Text("New Key")
            } footer: {
                Text(newKind == .secureEnclave
                     ? "The private key is created inside the Secure Enclave and can never leave this iPad, even for backups. If the iPad is erased, the key is gone; upload a new one."
                     + (SecureEnclaveSSHKey.isAvailable ? "" : " Not available on this device.")
                     : "Ed25519 is stored in the Keychain (this device only). It can be exported to use elsewhere.")
            }
            if let message {
                Section { Text(message).font(.callout) }
            }
        }
        .navigationTitle("SSH Keys")
        .task { await reload() }
    }

    private func keyRow(_ key: SSHKeyInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: key.kind == .secureEnclave ? "lock.shield.fill" : "key.fill")
                    .foregroundStyle(theme.accent)
                Text(key.label).font(.body.weight(.medium))
                if services.defaultSSHKeyID == key.id {
                    Text("Default").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.accent.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(key.kind.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Copy Public Key", systemImage: "doc.on.doc") {
                    Pasteboard.copy(key.openSSHPublicKey)
                    message = "Public key copied."
                }
                Menu {
                    ForEach(accounts) { account in
                        Section(account.displayName) {
                            Button("Authentication") { upload(key, to: account, usage: .authentication) }
                            Button("Signing") { upload(key, to: account, usage: .signing) }
                            Button("Authentication and Signing") { upload(key, to: account, usage: .authenticationAndSigning) }
                        }
                    }
                    if accounts.isEmpty { Text("Sign in to an account first") }
                } label: {
                    Label(uploading == key.id ? "Uploading…" : "Upload", systemImage: "icloud.and.arrow.up")
                }
                if services.defaultSSHKeyID != key.id {
                    Button("Make Default") { services.defaultSSHKeyID = key.id }
                }
                Spacer()
                Button(role: .destructive) { delete(key) } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete key")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func reload() async {
        keys = (try? await services.sshKeys.keys()) ?? []
        accounts = await services.accounts.accounts()
        if services.defaultSSHKeyID == nil { services.defaultSSHKeyID = keys.first?.id }
    }

    private func generate() {
        let label = newLabel.isEmpty ? "LemonSeed Studio" : newLabel
        Task {
            do {
                let key = try await services.sshKeys.generate(newKind, label: label)
                if services.defaultSSHKeyID == nil { services.defaultSSHKeyID = key.id }
                newLabel = ""
                message = "Created \(key.kind.displayName) key \(key.fingerprint)."
            } catch {
                message = "\(error)"
            }
            await reload()
        }
    }

    private func upload(_ key: SSHKeyInfo, to account: ForgeAccount, usage: ForgeSSHKey.Usage) {
        uploading = key.id
        Task {
            defer { uploading = nil }
            do {
                try await services.accounts.client(for: account).addSSHKey(title: key.label, publicKey: key.openSSHPublicKey, usage: usage)
                message = "Uploaded to \(account.displayName)."
            } catch {
                message = "Upload failed: \(error)"
            }
        }
    }

    private func delete(_ key: SSHKeyInfo) {
        Task {
            try? await services.sshKeys.delete(key.id)
            if services.defaultSSHKeyID == key.id { services.defaultSSHKeyID = nil }
            await reload()
        }
    }
}
