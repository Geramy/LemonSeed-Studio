// StudioModelsUI: the Models screen.
//
// What is installed, partly downloaded or missing; what the catalog
// recommends; storage; and a way into Hugging Face search. Standalone: give
// it a ModelLibrary and present it anywhere.
//
//   ModelsView(library: library)

import StudioModels
import SwiftUI

public struct ModelsView: View {
    @Bindable var library: ModelLibrary
    let embedInNavigation: Bool
    @State private var showingToken = false
    @State private var pendingDelete: ModelRecord?

    public init(library: ModelLibrary, embedInNavigation: Bool = true) {
        self.library = library
        self.embedInNavigation = embedInNavigation
    }

    public var body: some View {
        if embedInNavigation {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            if let error = library.lastError {
                Section {
                    ErrorBanner(message: error) { library.lastError = nil }
                }
            }
            Section {
                StorageSummaryView(library: library)
            }
            if !library.records.isEmpty {
                Section("On this iPad") {
                    ForEach(sortedRecords) { record in
                        InstalledModelRow(library: library, record: record, onDelete: { pendingDelete = record })
                    }
                }
            }
            let recommended = library.catalog.models.filter { library.record(forCatalog: $0.id) == nil }
            if !recommended.isEmpty {
                Section {
                    ForEach(recommended) { entry in
                        CatalogRow(library: library, entry: entry)
                    }
                } header: {
                    Text("Recommended")
                } footer: {
                    Text("Models download in the background, resume after interruptions and are checked against their published SHA-256 before they appear here.")
                }
            }
            Section {
                NavigationLink {
                    HubSearchView(library: library)
                } label: {
                    Label("Find models on Hugging Face", systemImage: "magnifyingglass")
                }
            } footer: {
                Text("Only checkpoints LSE can load are listed: Qwen3.5-family MLX safetensors, dense or MoE, affine-quantized or BF16.")
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Hugging Face token", systemImage: "key") { showingToken = true }
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
            }
        }
        .refreshable { await library.refresh() }
        .sheet(isPresented: $showingToken) { HubTokenView(library: library) }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "model")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible
        ) {
            Button("Delete \(ByteCountFormatter.string(fromByteCount: pendingDelete?.totalBytes ?? 0, countStyle: .file))",
                   role: .destructive) {
                if let id = pendingDelete?.id { Task { await library.delete(id) } }
                pendingDelete = nil
            }
        } message: {
            Text("The files are removed from this iPad. Download it again or copy it from a Mac to restore it.")
        }
        .task { await library.start() }
    }

    private var sortedRecords: [ModelRecord] {
        library.records.sorted { a, b in
            if a.role != b.role { return a.role == .main }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Storage

struct StorageSummaryView: View {
    let library: ModelLibrary
    @State private var used: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Text("\(Format.bytes(used)) used by models")
                    .foregroundStyle(.secondary)
            }
            if let available = library.availableBytes {
                let total = Double(used + available)
                ProgressView(value: total > 0 ? Double(used) / total : 0)
                    .tint(.yellow)
                Text("\(Format.bytes(available)) available on this iPad")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task(id: library.records) {
            let root = library.location.modelsRoot
            used = await Task.detached { ModelStoreLocation.allocatedSize(of: root) }.value
        }
    }
}

// MARK: - Installed and partial models

struct InstalledModelRow: View {
    let library: ModelLibrary
    let record: ModelRecord
    let onDelete: () -> Void
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.name).font(.headline)
                    BadgeRow(badges: badges)
                }
                Spacer()
                StateBadge(record: record)
            }
            if let progress = library.progress[record.id], record.state == .downloading || record.state == .paused {
                TransferProgressView(progress: progress, paused: record.state == .paused)
            }
            if let verifying = library.verifying[record.id] {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: verifying.fraction)
                    Text("Verifying \(verifying.currentFile ?? "")… \(Format.percent(verifying.fraction))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if case .failed(let message) = record.state {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if record.role == .main && record.state == .installed {
                DraftPicker(library: library, record: record)
            }
            if record.role == .dflash2Draft && record.traits?.quantization?.kind == .unquantized {
                Label(library.hasLSEConversion(record) ? "Q8 conversion ready"
                      : "LSE converts this to Q8 the first time it loads it",
                      systemImage: library.hasLSEConversion(record) ? "checkmark.seal" : "wand.and.stars")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            actions
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingDetails) { ModelDetailView(library: library, record: record) }
        .contextMenu {
            Button("Details", systemImage: "info.circle") { showingDetails = true }
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var badges: [String] {
        var b = [record.role.label, record.architectureLabel]
        if let q = record.traits?.quantization { b.append(q.label) }
        b.append(Format.bytes(record.totalBytes))
        if (record.traits?.mtpLayers ?? 0) > 0 {
            b.append(record.files.contains { $0.path.hasPrefix("mtp/") } ? "MTP" : "MTP declared")
        }
        if record.origin == .preplaced { b.append("Copied in") }
        return b
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch record.state {
            case .downloading, .queued, .verifying:
                Button("Pause", systemImage: "pause.fill") { Task { await library.pause(record.id) } }
                Button("Cancel", systemImage: "xmark", role: .destructive) { Task { await library.cancel(record.id) } }
            case .paused:
                Button("Resume", systemImage: "play.fill") { Task { await library.resume(record.id) } }
                Button("Cancel", systemImage: "xmark", role: .destructive) { Task { await library.cancel(record.id) } }
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task {
                        // An installed model that failed verification is repaired;
                        // a download that failed is resumed.
                        if FileManager.default.fileExists(atPath: library.directory(of: record).path) {
                            await library.repair(record.id)
                        } else {
                            await library.resume(record.id)
                        }
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            case .installed:
                Button(record.isVerified ? "Verify again" : "Verify", systemImage: "checkmark.shield") {
                    library.verify(record.id)
                }
                .disabled(library.verifying[record.id] != nil)
                Button("Details", systemImage: "info.circle") { showingDetails = true }
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            case .incomplete, .missing:
                if record.repository != nil {
                    Button("Repair", systemImage: "arrow.down.circle") { Task { await library.repair(record.id) } }
                }
                Button("Forget", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}

struct DraftPicker: View {
    let library: ModelLibrary
    let record: ModelRecord

    var body: some View {
        let drafts = library.installedDrafts.filter { draft in
            guard let mine = record.traits, let theirs = draft.traits else { return true }
            return mine.accepts(draft: theirs)
        }
        Picker(selection: Binding(
            get: { record.linkedDraftID },
            set: { id in Task { await library.link(main: record.id, draft: id) } }
        )) {
            Text("None (no DFlash2)").tag(String?.none)
            ForEach(drafts) { draft in
                Text(draft.name).tag(Optional(draft.id))
            }
        } label: {
            Label("DFlash2 draft", systemImage: "bolt.horizontal")
        }
        .font(.subheadline)
    }
}

struct TransferProgressView: View {
    let progress: DownloadProgress
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: progress.fraction)
            HStack {
                Text("\(Format.bytes(progress.receivedBytes)) of \(Format.bytes(progress.totalBytes))")
                Spacer()
                if paused {
                    Text("Paused")
                } else if progress.bytesPerSecond > 0 {
                    Text("\(Format.bytes(Int64(progress.bytesPerSecond)))/s")
                    if let eta = progress.eta { Text("· \(Format.duration(eta)) left") }
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Catalog entries not on the device

struct CatalogRow: View {
    let library: ModelLibrary
    let entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.headline)
                    BadgeRow(badges: [entry.role.label, entry.architecture, entry.quantization.label,
                                      Format.bytes(entry.totalBytes)])
                }
                Spacer()
                if entry.isDownloadable {
                    Button("Download", systemImage: "arrow.down.circle.fill") {
                        Task { await library.download(catalogID: entry.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .foregroundStyle(.black)
                }
            }
            Text(entry.summary).font(.footnote).foregroundStyle(.secondary)
            if entry.role == .main, let draft = entry.drafts?.compactMap({ library.catalog.entry(id: $0) })
                .first(where: \.isDownloadable) {
                Text("Includes \(draft.name), \(Format.bytes(draft.totalBytes)).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !entry.isDownloadable {
                Text("Copy it from a Mac into Documents/Models/\(entry.id)/; it is verified when found.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Details

struct ModelDetailView: View {
    let library: ModelLibrary
    let record: ModelRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Source") {
                    LabeledContent("Repository", value: record.repository ?? "—")
                    LabeledContent("Revision", value: record.revision.map { String($0.prefix(12)) } ?? "—")
                    LabeledContent("Folder", value: "Models/\(record.directoryName)")
                    LabeledContent("Added", value: record.addedAt.formatted(date: .abbreviated, time: .shortened))
                    if let used = record.lastUsedAt {
                        LabeledContent("Last used", value: used.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let traits = record.traits {
                    Section("Checkpoint") {
                        LabeledContent("Architecture", value: traits.architectureLabel)
                        LabeledContent("Weights", value: traits.quantization?.label ?? "—")
                        if let h = traits.hiddenSize { LabeledContent("Hidden size", value: "\(h)") }
                        if let n = traits.numLayers { LabeledContent("Layers", value: "\(n)") }
                        LabeledContent("MTP layers", value: "\(traits.mtpLayers)")
                        ForEach(traits.problems, id: \.self) { Text($0).foregroundStyle(.red) }
                    }
                }
                if record.role == .main, let args = library.launchArguments(for: record.id) {
                    Section("LSE launch") {
                        Text(args.joined(separator: " "))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section("Files") {
                    ForEach(record.files, id: \.path) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.path).font(.subheadline)
                                Text(file.sha256.map { "sha256 \($0.prefix(16))…" } ?? "no digest yet")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.bytes(file.size)).font(.caption).foregroundStyle(.secondary)
                            VerificationIcon(state: file.verification)
                        }
                    }
                }
            }
            .navigationTitle(record.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Small pieces

struct BadgeRow: View {
    let badges: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct StateBadge: View {
    let record: ModelRecord

    var body: some View {
        let (symbol, color): (String, Color) = switch record.state {
        case .installed: record.isVerified ? ("checkmark.seal.fill", .green) : ("checkmark.circle", .secondary)
        case .downloading, .queued, .verifying: ("arrow.down.circle", .blue)
        case .paused: ("pause.circle", .orange)
        case .incomplete, .missing: ("exclamationmark.triangle", .orange)
        case .failed: ("xmark.octagon", .red)
        }
        Label(record.state == .installed && record.isVerified ? "Verified" : record.state.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }
}

struct VerificationIcon: View {
    let state: ModelRecord.Verification

    var body: some View {
        switch state {
        case .verified: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .unverified: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .mismatch: Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
        case .missing: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.footnote)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func percent(_ x: Double) -> String { x.formatted(.percent.precision(.fractionLength(0))) }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        f.unitsStyle = .abbreviated
        return f.string(from: max(1, seconds)) ?? ""
    }
}
