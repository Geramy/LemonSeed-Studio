// The registry: atomic persistence, recovery, reconciliation with
// Documents/Models, verification and draft links.

import Foundation
import Testing
@testable import StudioModels

/// A two-model catalog with small files, so pre-placed directories are cheap.
func smallCatalog(mainFiles: [String: Data], draftFiles: [String: Data]) -> ModelCatalog {
    func files(_ d: [String: Data]) -> [ModelFile] {
        d.keys.sorted().map { ModelFile(path: $0, size: Int64(d[$0]!.count), sha256: sha256Hex(d[$0]!)) }
    }
    return ModelCatalog(models: [
        CatalogEntry(id: "tiny-q4", name: "Tiny Q4", summary: "", role: .main, source: .huggingFace,
                     repository: "test/tiny-q4", revision: String(repeating: "a", count: 40),
                     architecture: "qwen3.5", quantization: .affine(bits: 4, groupSize: 64), mtpLayers: 0,
                     drafts: ["tiny-draft"], files: files(mainFiles)),
        CatalogEntry(id: "tiny-draft", name: "Tiny draft", summary: "", role: .dflash2Draft, source: .localOnly,
                     architecture: "dflash2", quantization: .affine(bits: 8, groupSize: 64), mtpLayers: 0,
                     files: files(draftFiles)),
    ])
}

func place(_ files: [String: Data], in dir: URL) throws {
    for (path, data) in files {
        let url = dir.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

@Suite("Registry")
struct RegistryTests {
    let mainFiles = ["config.json": Data(#"{"a":1}"#.utf8), "weights/model.safetensors": testBytes(4096, seed: 1)]
    let draftFiles = ["config.json": Data(#"{"d":1}"#.utf8), "model.safetensors": testBytes(2048, seed: 2)]

    func record(_ id: String) -> ModelRecord {
        ModelRecord(id: id, name: id, role: .main, origin: .huggingFace, repository: "x/\(id)",
                    revision: "main", files: [ModelRecord.File(ModelFile(path: "a", size: 1))], state: .installed)
    }

    @Test func writesAreAtomicAndSurviveACorruptMainFile() async throws {
        let scratch = try Scratch()
        let registry = ModelRegistry(location: scratch.location)
        try await registry.upsert(record("one"))
        try await registry.upsert(record("two"))
        try await registry.update("two") { $0.lastUsedAt = Date(timeIntervalSince1970: 1000) }
        let reloaded = ModelRegistry(location: scratch.location)
        #expect(await reloaded.all().map(\.id) == ["one", "two"])
        #expect(await reloaded.record("two")?.lastUsedAt == Date(timeIntervalSince1970: 1000))

        // A damaged registry.json falls back to the backup and is kept for inspection.
        try Data("{ not json".utf8).write(to: scratch.location.registryURL)
        let recovered = ModelRegistry(location: scratch.location)
        #expect(await recovered.all().map(\.id) == ["one", "two"])
        let kept = try FileManager.default.contentsOfDirectory(atPath: scratch.location.supportRoot.path)
        #expect(kept.contains { $0.hasPrefix("registry.unreadable-") })
    }

    @Test func reconcileAdoptsPreplacedDirectoriesAndMarksMissingOnes() async throws {
        let scratch = try Scratch()
        let location = scratch.location
        try location.prepare()
        let catalog = smallCatalog(mainFiles: mainFiles, draftFiles: draftFiles)
        // As devicectl would leave them: the catalog id, and a renamed copy found by sizes.
        try place(mainFiles, in: location.directory(for: "tiny-q4"))
        try place(draftFiles, in: location.directory(for: "my-draft"))
        try place(["config.json": Data("{}".utf8)], in: location.directory(for: "something-else"))
        try place(["x": Data("1".utf8)], in: location.modelsRoot.appending(path: ".partial/ignored"))

        let registry = ModelRegistry(location: location)
        let report = try await registry.reconcile(catalog: catalog)
        #expect(Set(report.added) == ["tiny-q4", "my-draft", "something-else"])
        let main = try #require(await registry.record("tiny-q4"))
        #expect(main.origin == .preplaced && main.catalogID == "tiny-q4" && main.state == .installed)
        #expect(main.files.allSatisfy { $0.verification == .unverified })
        #expect(await registry.record("my-draft")?.catalogID == "tiny-draft")
        #expect(main.linkedDraftID == "my-draft")
        #expect(await registry.record("something-else")?.catalogID == nil)
        #expect(ModelStoreLocation.isExcludedFromBackup(location.directory(for: "tiny-q4")))

        // Removing a directory marks it missing; the record stays.
        try FileManager.default.removeItem(at: location.directory(for: "my-draft"))
        try FileManager.default.removeItem(at: location.directory(for: "tiny-q4").appending(path: "config.json"))
        let second = try await registry.reconcile(catalog: catalog)
        #expect(second.missing == ["my-draft"])
        #expect(second.incomplete == ["tiny-q4"])
        #expect(await registry.record("my-draft")?.state == .missing)
        #expect(await registry.record("tiny-q4")?.state == .incomplete)

        // Putting it back restores it.
        try place(draftFiles, in: location.directory(for: "my-draft"))
        let third = try await registry.reconcile(catalog: catalog)
        #expect(third.restored == ["my-draft"])
        #expect(await registry.record("my-draft")?.state == .installed)
    }

    @Test func verificationCatchesAlteredFiles() async throws {
        let scratch = try Scratch()
        let location = scratch.location
        try location.prepare()
        let catalog = smallCatalog(mainFiles: mainFiles, draftFiles: draftFiles)
        let dir = location.directory(for: "tiny-q4")
        try place(mainFiles, in: dir)
        let registry = ModelRegistry(location: location)
        _ = try await registry.reconcile(catalog: catalog)
        let record = try #require(await registry.record("tiny-q4"))

        var files = await ModelVerifier.verify(files: record.files, in: dir)
        #expect(files.allSatisfy { $0.verification == .verified && $0.stamp != nil })

        var damaged = mainFiles["weights/model.safetensors"]!
        damaged[10] ^= 1
        try damaged.write(to: dir.appending(path: "weights/model.safetensors"))
        files = await ModelVerifier.verify(files: files, in: dir)
        #expect(files.first { $0.path == "weights/model.safetensors" }?.verification == .mismatch)
        #expect(files.first { $0.path == "config.json" }?.verification == .verified)
    }

    @Test func libraryLaunchArgumentsUseTheLinkedDraft() async throws {
        let scratch = try Scratch()
        let location = scratch.location
        let catalog = smallCatalog(mainFiles: mainFiles, draftFiles: draftFiles)
        try location.prepare()
        try place(mainFiles, in: location.directory(for: "tiny-q4"))
        try place(draftFiles, in: location.directory(for: "tiny-draft"))
        let library = await ModelLibrary(catalog: catalog, location: location,
                                         downloads: DownloaderConfiguration(session: .foreground),
                                         tokenStore: HubTokenStore(service: "studiomodels-tests-\(UUID())"))
        await library.start()
        let args = try #require(await library.launchArguments(for: "tiny-q4"))
        let q4 = location.directory(for: "tiny-q4").path, draft = location.directory(for: "tiny-draft").path
        #expect(args.prefix(5) == ["--model", q4, "--dflash2=on", "--dflash2-model", draft])
        await library.link(main: "tiny-q4", draft: nil)
        #expect(await library.launchArguments(for: "tiny-q4")?.contains("--dflash2=on") == false)
    }
}

/// The real models from this Mac, as devicectl would place them, against the
/// bundled catalog. Gated because it hashes about 22 GB:
///
///   STUDIO_MODELS_MAC_MODELS=~/Documents/Development/mac_amdgpu/build/models swift test --filter MacModelTests
@Suite("Mac models against the catalog")
struct MacModelTests {
    @Test func preplacedCopiesAreRecognizedAndVerify() async throws {
        guard let root = ProcessInfo.processInfo.environment["STUDIO_MODELS_MAC_MODELS"] else { return }
        let source = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        let scratch = try Scratch()
        let location = scratch.location
        try location.prepare()
        let fm = FileManager.default
        // copyItem clones on APFS: instant, no extra space.
        for id in ["qwen38-27b-q4", "qwen38-27b-dflash2-q8"] {
            try fm.copyItem(at: source.appending(path: id).resolvingSymlinksInPath(), to: location.directory(for: id))
        }
        let registry = ModelRegistry(location: location)
        let report = try await registry.reconcile(catalog: .bundled())
        #expect(Set(report.added) == ["qwen38-27b-q4", "qwen38-27b-dflash2-q8"])
        let q4 = try #require(await registry.record("qwen38-27b-q4"))
        #expect(q4.catalogID == "qwen38-27b-q4" && q4.state == .installed)
        #expect(q4.linkedDraftID == "qwen38-27b-dflash2-q8")
        #expect(q4.traits?.isCompatible == true)
        for id in ["qwen38-27b-q4", "qwen38-27b-dflash2-q8"] {
            let record = try #require(await registry.record(id))
            let files = await ModelVerifier.verify(files: record.files, in: location.directory(for: id))
            #expect(files.allSatisfy { $0.verification == .verified }, "\(id): \(files.map { ($0.path, $0.verification) })")
        }
    }
}
