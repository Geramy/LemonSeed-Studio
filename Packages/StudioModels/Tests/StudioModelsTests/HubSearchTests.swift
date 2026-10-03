// Hugging Face search, offline: every response comes from Fixtures/hub,
// recorded from huggingface.co. To re-record (network needed):
//
//   STUDIO_MODELS_RECORD_HUB=1 swift test --filter HubSearchTests
//
// then commit Fixtures/hub. Without the variable no request leaves the machine.

import Foundation
import Testing
@testable import StudioModels

@Suite("Hub search", .serialized)
struct HubSearchTests {
    static let query = "Qwen3.8-27B MLX"
    static let limit = 25
    static var recording: Bool { ProcessInfo.processInfo.environment["STUDIO_MODELS_RECORD_HUB"] == "1" }

    /// Runs the search the way the app does, recording when asked.
    static func searchResults() async throws -> [HubSearchResult] {
        if recording {
            let recorder = RecordingTransport(directory: Fixtures.sourceDirectory().appending(path: "hub"))
            let search = CompatibleModelSearch(client: HubClient(transport: recorder))
            let results = try await search.search(query, limit: limit)
            try recorder.finish()
            return results
        }
        let transport = try FixtureTransport(directory: Fixtures.root.appending(path: "hub"))
        let search = CompatibleModelSearch(client: HubClient(transport: transport))
        return try await search.search(query, limit: limit)
    }

    @Test func theCatalogModelIsFoundWithItsDraft() async throws {
        let results = try await Self.searchResults()
        let q4 = try #require(results.first { $0.repository == "lmstudio-community/Qwen3.8-27B-MLX-4bit" })
        #expect(q4.isCompatible, "\(q4.traits.problems)")
        #expect(q4.revision == "6067b15cf581666a4aecf6af3afaba4bb5efc20c")
        #expect(q4.traits.layout == .dense && q4.traits.quantization == .affine(bits: 4, groupSize: 64))
        #expect(q4.sizeBytes > 16_000_000_000)
        // The shards carry their LFS SHA-256, identical to the catalog's pins.
        let catalog = ModelCatalog.bundled().entry(id: "qwen38-27b-q4")!
        for pinned in catalog.files where pinned.size > 1_000_000 {
            #expect(q4.files.first { $0.path == pinned.path }?.sha256 == pinned.sha256, "\(pinned.path)")
        }
        let draft = try #require(q4.drafts.first)
        #expect(q4.drafts.contains { $0.repository == "incoai/Qwen3.8-27B-DFlash2" })
        #expect(draft.traits.numTargetLayers == 64 && draft.traits.hiddenSize == 5120)
        let incoai = try #require(q4.drafts.first { $0.repository == "incoai/Qwen3.8-27B-DFlash2" })
        #expect(incoai.convertsOnLoad)
        #expect(incoai.files.map(\.path) == ["config.json", "model.safetensors"])
    }

    @Test func onlyLoadableCheckpointsPassTheDefaultFilter() async throws {
        let results = try await Self.searchResults()
        let shown = results.filter(HubSearchFilters().matches)
        #expect(!shown.isEmpty)
        for result in shown {
            #expect(result.isCompatible)
            #expect(result.files.contains { $0.path.hasSuffix(".safetensors") })
            #expect(!result.files.contains { $0.path.hasSuffix(".gguf") })
            #expect(["qwen3.5", "qwen3.5-moe"].contains(result.traits.architectureLabel))
        }
        // Incompatible ones come back only when asked for, with reasons.
        for result in results where !result.isCompatible {
            #expect(!result.traits.problems.isEmpty)
            #expect(HubSearchFilters(includeIncompatible: true).matches(result))
        }
    }

    @Test func facetsFilterWithoutNewRequests() async throws {
        let results = try await Self.searchResults()
        let withDraft = results.filter(HubSearchFilters(dflash2: true).matches)
        let without = results.filter(HubSearchFilters(dflash2: false).matches)
        #expect(withDraft.allSatisfy { !$0.drafts.isEmpty } && without.allSatisfy { $0.drafts.isEmpty })
        #expect(withDraft.count + without.count == results.filter(HubSearchFilters().matches).count)
        let q4 = results.filter(HubSearchFilters(bits: 4).matches)
        #expect(q4.allSatisfy { $0.traits.quantization?.bits == 4 })
        #expect(results.filter(HubSearchFilters(layout: .moe).matches).allSatisfy { $0.traits.layout == .moe })
        let mtp = results.filter(HubSearchFilters(mtp: true).matches)
        #expect(mtp.allSatisfy { $0.mtp.isAvailable })
        for result in mtp {
            if case .available(let repo, false) = result.mtp {
                #expect(CompatibleModelSearch.mtpCompanionNames(result.repository).contains(repo))
                #expect(result.mtpFiles.allSatisfy { $0.path.hasPrefix("mtp/") && $0.sourceRepository == repo })
            }
        }
        let small = results.filter(HubSearchFilters(maxBytes: 18_000_000_000).matches)
        #expect(small.allSatisfy { $0.sizeBytes <= 18_000_000_000 })
    }

    @Test func downloadRequestsPinTheSearchedCommit() async throws {
        let results = try await Self.searchResults()
        let q4 = try #require(results.first { $0.repository == "lmstudio-community/Qwen3.8-27B-MLX-4bit" })
        let request = CompatibleModelSearch.downloadRequest(for: q4)
        #expect(request.id == "lmstudio-community--Qwen3.8-27B-MLX-4bit")
        #expect(request.revision == q4.revision)
        #expect(!request.files.contains { $0.path == "README.md" || $0.path == ".gitattributes" })
        #expect(request.files.contains { $0.path == "tokenizer.json" && $0.sha256 != nil })
        #expect(request.files.contains { $0.path == "config.json" && $0.gitBlobSHA1 != nil })
        let draft = try #require(q4.drafts.first { $0.repository == "incoai/Qwen3.8-27B-DFlash2" })
        let draftRequest = CompatibleModelSearch.downloadRequest(for: draft)
        #expect(draftRequest.role == .dflash2Draft && draftRequest.extraBytes > 2_000_000_000)
    }

    @Test func familyNamesAndAffinity() {
        #expect(CompatibleModelSearch.familyName("lmstudio-community/Qwen3.8-27B-MLX-4bit") == "qwen3.8-27b")
        #expect(CompatibleModelSearch.familyName("incoai/Qwen3.8-27B-DFlash2") == "qwen3.8-27b")
        #expect(CompatibleModelSearch.familyName("mlx-community/Qwen3.6-35B-A3B-4bit") == "qwen3.6-35b-a3b")
    }
}
