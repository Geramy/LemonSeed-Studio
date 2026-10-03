// StudioModelsUI: Hugging Face search for models LSE can load.

import StudioModels
import SwiftUI

public struct HubSearchView: View {
    let library: ModelLibrary
    @State private var query = "Qwen3.8 MLX"
    @State private var results: [HubSearchResult] = []
    @State private var filters = HubSearchFilters()
    @State private var searching = false
    @State private var error: String?
    @State private var selected: HubSearchResult?

    public init(library: ModelLibrary) { self.library = library }

    public var body: some View {
        List {
            Section {
                FilterChips(filters: $filters)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            if let error {
                Section { ErrorBanner(message: error) { self.error = nil } }
            }
            Section {
                if searching {
                    HStack { ProgressView(); Text("Searching and checking each model's files…") }
                } else if shown.isEmpty {
                    Text(results.isEmpty ? "Search for a model, e.g. Qwen3.8 27B MLX." : "Nothing matches these filters.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { result in
                    Button { selected = result } label: { SearchResultRow(result: result, library: library) }
                        .buttonStyle(.plain)
                }
            } footer: {
                if !results.isEmpty {
                    Text("\(shown.count) of \(results.count) results. Compatibility is read from each model's config and tensor names, not its tags.")
                }
            }
        }
        .navigationTitle("Hugging Face")
        .searchable(text: $query, prompt: "Search models")
        .onSubmit(of: .search) { Task { await run() } }
        .task { if results.isEmpty { await run() } }
        .sheet(item: $selected) { result in
            SearchResultDetail(library: library, result: result)
        }
    }

    private var shown: [HubSearchResult] { results.filter(filters.matches) }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await library.search.search(text)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FilterChips: View {
    @Binding var filters: HubSearchFilters

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tri("MTP", value: $filters.mtp)
                tri("DFlash2", value: $filters.dflash2)
                chip("Dense", on: filters.layout == .dense) { filters.layout = filters.layout == .dense ? nil : .dense }
                chip("MoE", on: filters.layout == .moe) { filters.layout = filters.layout == .moe ? nil : .moe }
                ForEach([4, 6, 8, 0], id: \.self) { bits in
                    chip(bits == 0 ? "BF16" : "Q\(bits)", on: filters.bits == bits) {
                        filters.bits = filters.bits == bits ? nil : bits
                    }
                }
                chip("≤ 24 GB", on: filters.maxBytes != nil) {
                    filters.maxBytes = filters.maxBytes == nil ? 24_000_000_000 : nil
                }
                chip("Show incompatible", on: filters.includeIncompatible) { filters.includeIncompatible.toggle() }
            }
        }
    }

    /// Any → with → without → any.
    private func tri(_ name: String, value: Binding<Bool?>) -> some View {
        let label = switch value.wrappedValue {
        case nil: name
        case true?: "\(name) ✓"
        case false?: "No \(name)"
        }
        return chip(label, on: value.wrappedValue != nil) {
            value.wrappedValue = switch value.wrappedValue {
            case nil: true
            case true?: false
            case false?: nil
            }
        }
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(on ? .black : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct SearchResultRow: View {
    let result: HubSearchResult
    let library: ModelLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.repository).font(.headline).lineLimit(1)
                if result.gated { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                Spacer()
                CompatibilityBadge(compatible: result.isCompatible)
            }
            BadgeRow(badges: badges)
            if let problem = result.traits.problems.first {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var badges: [String] {
        var b = [result.traits.architectureLabel, result.traits.quantization?.label ?? "?", Format.bytes(result.sizeBytes)]
        switch result.mtp {
        case .available: b.append("MTP")
        case .notFound: b.append("MTP declared, no module")
        case .unsupported: b.append("MTP unsupported")
        case .none: break
        }
        b.append(result.drafts.isEmpty ? "No DFlash2" : "DFlash2 ×\(result.drafts.count)")
        b.append("↓ \(result.downloads.formatted(.number.notation(.compactName)))")
        if library.record(CompatibleModelSearch.localID(result.repository)) != nil { b.append("On iPad") }
        return b
    }
}

struct CompatibilityBadge: View {
    let compatible: Bool

    var body: some View {
        Label(compatible ? "LSE compatible" : "Not loadable",
              systemImage: compatible ? "checkmark.circle.fill" : "xmark.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(compatible ? .green : .secondary)
    }
}

struct SearchResultDetail: View {
    let library: ModelLibrary
    let result: HubSearchResult
    @State private var draftID: String?
    @State private var includeMTP = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Commit", value: String(result.revision.prefix(12)))
                    LabeledContent("Architecture", value: result.traits.architectureLabel)
                    LabeledContent("Weights", value: result.traits.quantization?.label ?? "—")
                    LabeledContent("Download", value: Format.bytes(totalBytes))
                    ForEach(result.traits.problems, id: \.self) { Text($0).foregroundStyle(.red) }
                }
                if !result.drafts.isEmpty {
                    Section {
                        Picker("DFlash2 draft", selection: $draftID) {
                            Text("None").tag(String?.none)
                            ForEach(result.drafts) { draft in
                                Text("\(draft.repository) · \(Format.bytes(draft.sizeBytes))").tag(Optional(draft.id))
                            }
                        }
                    } footer: {
                        if let draft = chosenDraft, draft.convertsOnLoad {
                            Text("This draft is BF16; LSE converts it to Q8 the first time it loads it.")
                        }
                    }
                }
                if case .available(let repo, let inRepo) = result.mtp, !inRepo {
                    Section {
                        Toggle("Include the MTP module", isOn: $includeMTP)
                    } footer: {
                        Text("From \(repo), stored in mtp/ beside the model where LSE looks for it.")
                    }
                }
                Section {
                    Button {
                        Task {
                            await library.download(result, draft: chosenDraft, includeMTP: includeMTP)
                            dismiss()
                        }
                    } label: {
                        Label("Download \(Format.bytes(totalBytes))", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!result.isCompatible)
                }
            }
            .navigationTitle(result.repository)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { draftID = result.drafts.first?.id }
        }
    }

    private var chosenDraft: DraftCandidate? { result.drafts.first { $0.id == draftID } }

    private var totalBytes: Int64 {
        result.sizeBytes + (chosenDraft?.sizeBytes ?? 0)
            + (includeMTP ? result.mtpFiles.reduce(0) { $0 + $1.size } : 0)
    }
}

struct HubTokenView: View {
    let library: ModelLibrary
    @State private var token = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("hf_…", text: $token)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text("Needed only for gated or private repositories. Stored in this iPad's Keychain and sent only to huggingface.co.")
                }
                if library.hubToken != nil {
                    Button("Remove token", role: .destructive) {
                        library.hubToken = nil
                        dismiss()
                    }
                }
            }
            .navigationTitle("Hugging Face token")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.hubToken = token
                        dismiss()
                    }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
