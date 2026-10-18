import PennyBarCore
import SwiftUI

/// Editable copy of an account plus its token. Generic over providers: everything
/// provider-specific comes from the descriptor and `scopes(token:)`.
struct AccountDraft: Identifiable {
    let id: UUID
    let provider: any UsageProvider
    let isNew: Bool
    var name: String
    var token: String
    var scopeID: String
    var isEnabled: Bool
    var budget: Decimal?

    init(provider: any UsageProvider, account: Account? = nil, token: String = "") {
        self.id = account?.id ?? UUID()
        self.provider = provider
        self.isNew = account == nil
        self.name = account?.name ?? ""
        self.token = token
        self.scopeID = account?.scopeID ?? ""
        self.isEnabled = account?.isEnabled ?? true
        self.budget = account?.budget
    }

    func account(fallbackName: String) -> Account {
        Account(
            id: id,
            providerID: provider.descriptor.id,
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? fallbackName : name,
            scopeID: scopeID.trimmingCharacters(in: .whitespaces),
            isEnabled: isEnabled,
            budget: budget.flatMap { $0 > 0 ? $0 : nil }
        )
    }
}

// MARK: - Add flow

/// Pick a provider, then fill in its editor, in one sheet.
struct AddAccountFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AccountDraft?

    // No animation when switching steps: the sheet window resizes outside SwiftUI's animation,
    // so a cross-fade shows both steps at the wrong size for a frame.
    var body: some View {
        if let draft {
            AccountEditor(draft: draft, onBack: { self.draft = nil })
        } else {
            ProviderPicker { provider in
                draft = AccountDraft(provider: provider)
            } onCancel: {
                dismiss()
            }
        }
    }
}

struct ProviderPicker: View {
    @Environment(AppModel.self) private var model
    let onPick: (any UsageProvider) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add an Account")
                    .font(.title3.weight(.semibold))
                Text("Choose the service to connect. You can add several accounts per service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(model.registry.providers, id: \.descriptor.id) { provider in
                    ProviderCard(descriptor: provider.descriptor) { onPick(provider) }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        // Same width as the editor, so stepping between them only changes the sheet's height.
        .frame(width: 480)
    }
}

private struct ProviderCard: View {
    let descriptor: ProviderDescriptor
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProviderBadge(descriptor: descriptor, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName)
                        .font(.headline)
                    Text(descriptor.totalKind == .billed ? "Billed amounts" : "Estimated from usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(isHovering ? 0.8 : 0.4), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovering ? descriptor.tint.opacity(0.6) : .clear, lineWidth: 1.5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Editor

struct AccountEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: AccountDraft
    var onBack: (() -> Void)?

    @State private var revealToken = false
    @State private var scopes: [ProviderScope] = []
    @State private var scopeState: LoadState<Int> = .idle
    @State private var testState: LoadState<UsageSnapshot> = .idle
    @State private var saveError: String?
    @State private var confirmingRemoval = false

    enum LoadState<Value> {
        case idle
        case loading
        case loaded(Value)
        case failed(String)
    }

    private var descriptor: ProviderDescriptor { draft.provider.descriptor }
    /// The credential to use, or "" while incomplete. Multi-part credentials need every part filled in.
    private var trimmedToken: String {
        let token = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard descriptor.credentialParts.count > 1 else { return token }
        return tokenParts.contains(where: \.isEmpty) ? "" : tokenParts.joined(separator: ":")
    }

    /// The stored credential split into the descriptor's parts, trimmed.
    private var tokenParts: [String] {
        let count = descriptor.credentialParts.count
        var parts = draft.token.split(separator: ":", maxSplits: max(count - 1, 0), omittingEmptySubsequences: false).map(String.init)
        parts += Array(repeating: "", count: max(count - parts.count, 0))
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func tokenPart(_ index: Int) -> Binding<String> {
        Binding(
            get: { tokenParts[index] },
            set: { value in
                var parts = tokenParts
                // Colons separate the parts, so they can't appear inside one.
                parts[index] = value.replacing(":", with: "")
                draft.token = parts.allSatisfy(\.isEmpty) ? "" : parts.joined(separator: ":")
            }
        )
    }
    private var trimmedScope: String { draft.scopeID.trimmingCharacters(in: .whitespaces) }
    private var selectedScopeName: String? { scopes.first { $0.id == draft.scopeID }?.name }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 4)

            Form {
                tokenSection
                scopeSection
                connectionSection
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()
            buttons
                .padding(16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Remove \(draft.name)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text("Its token is deleted from the Keychain. This doesn't revoke the token on the provider.")
        }
        // Look up scopes shortly after the token stops changing, so pasting is enough.
        .task(id: trimmedToken) {
            guard !trimmedToken.isEmpty else {
                scopes = []
                scopeState = .idle
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadScopes()
        }
        // Then check the connection whenever the token or scope settles.
        .task(id: "\(trimmedToken)|\(trimmedScope)") {
            guard !trimmedToken.isEmpty, !trimmedScope.isEmpty else {
                testState = .idle
                return
            }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await test()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderBadge(descriptor: descriptor, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.isNew ? "Connect \(descriptor.displayName)" : "Edit \(draft.name)")
                    .font(.title3.weight(.semibold))
                Text(descriptor.tokenHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var tokenSection: some View {
        Section {
            if descriptor.credentialParts.count > 1 {
                ForEach(Array(descriptor.credentialParts.enumerated()), id: \.offset) { index, label in
                    // Only the last part is the secret; earlier parts (such as an ID) stay visible.
                    credentialField(label, text: tokenPart(index), isSecret: index == descriptor.credentialParts.count - 1)
                }
            } else {
                credentialField(descriptor.tokenLabel, text: $draft.token, isSecret: true)
            }
        } footer: {
            HStack {
                Text("Stored in your Keychain.")
                Spacer()
                Link("Create a token ↗", destination: descriptor.tokenURL)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func credentialField(_ label: String, text: Binding<String>, isSecret: Bool) -> some View {
        HStack(spacing: 6) {
            // Only an entered value is monospaced; the label and prompt keep the body font.
            let prompt = Text(isSecret ? "Paste here" : "Required")
            Group {
                if isSecret && !revealToken {
                    SecureField(text: text, prompt: prompt) { Text(label).font(.body) }
                } else {
                    TextField(text: text, prompt: prompt) { Text(label).font(.body) }
                }
            }
            .font(text.wrappedValue.isEmpty ? .body : .body.monospaced())
            .multilineTextAlignment(.trailing)
            if isSecret {
                Button {
                    revealToken.toggle()
                } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealToken ? "Hide token" : "Show token")
            }
        }
    }

    private var scopeSection: some View {
        Section {
            if scopes.count > 1 || (scopes.count == 1 && trimmedScope != scopes[0].id) {
                Picker(descriptor.scopeLabel, selection: $draft.scopeID) {
                    ForEach(scopes) { scope in
                        Text(scope.name).tag(scope.id)
                    }
                }
            } else if let scope = scopes.first {
                LabeledContent(descriptor.scopeLabel, value: scope.name)
            } else {
                TextField("\(descriptor.scopeLabel) ID", text: $draft.scopeID, prompt: Text("Paste the ID"))
            }
            TextField("Name in menu", text: $draft.name, prompt: Text(selectedScopeName ?? descriptor.displayName))
            BudgetField(title: "Budget per period", value: $draft.budget)
            Toggle("Show in menu", isOn: $draft.isEnabled)
        } footer: {
            Group {
                switch scopeState {
                case .loading:
                    Text("Looking up \(descriptor.scopeLabel.lowercased())s…")
                case .failed(let message):
                    Text("Couldn't list \(descriptor.scopeLabel.lowercased())s: \(message) Enter the ID manually.")
                case .loaded(0):
                    Text("This token can't list \(descriptor.scopeLabel.lowercased())s. Enter the ID manually.")
                default:
                    EmptyView()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        Section {
            HStack(spacing: 8) {
                switch testState {
                case .idle:
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.tertiary)
                    Text("Enter a token to check the connection")
                        .foregroundStyle(.secondary)
                case .loading:
                    ProgressView().controlSize(.small)
                    Text("Checking connection…")
                        .foregroundStyle(.secondary)
                case .loaded(let snapshot):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                    Spacer()
                    CostText(money: snapshot.total, kind: snapshot.totalKind)
                        .foregroundStyle(.secondary)
                    Text("this period")
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed = testState {
                    Spacer()
                    Button("Retry") { Task { await test() } }
                }
            }
            .frame(minHeight: 22)
        }
    }

    private var buttons: some View {
        HStack {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            } else if !draft.isNew {
                Button("Remove Account…", role: .destructive) { confirmingRemoval = true }
            }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(draft.isNew ? "Add Account" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedToken.isEmpty || trimmedScope.isEmpty)
        }
    }

    // MARK: Actions

    private func loadScopes() async {
        scopeState = .loading
        do {
            let found = try await draft.provider.scopes(token: trimmedToken)
            scopes = found
            scopeState = .loaded(found.count)
            if !found.contains(where: { $0.id == draft.scopeID }), let first = found.first, draft.isNew {
                draft.scopeID = first.id
            }
        } catch {
            scopes = []
            scopeState = .failed(error.localizedDescription)
        }
    }

    private func test() async {
        testState = .loading
        do {
            testState = .loaded(try await draft.provider.snapshot(token: trimmedToken, scopeID: trimmedScope, now: .now))
        } catch is CancellationError {
            // A newer token or scope replaced this check.
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func remove() {
        if let account = model.accounts.first(where: { $0.id == draft.id }) {
            model.delete(account)
        }
        dismiss()
    }

    private func save() {
        do {
            try model.save(draft.account(fallbackName: selectedScopeName ?? descriptor.displayName), token: trimmedToken)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
