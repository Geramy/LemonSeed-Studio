# StudioModels

Model management for LemonSeed Studio. It covers the curated catalog, a persistent registry, Hugging Face search filtered to what LemonSeed Engine (LSE) loads, background downloads with SHA-256 verification, and LSE launch presets.

- `StudioModels`: the core. It depends only on Foundation (plus CryptoKit, Security and Network).
- `StudioModelsUI`: the SwiftUI Models screen and Hugging Face search. It is standalone.

## Catalog

| id | source | pinned at | size |
|---|---|---|---|
| `qwen38-27b-q4` | `lmstudio-community/Qwen3.8-27B-MLX-4bit` | `6067b15cf581666a4aecf6af3afaba4bb5efc20c` | 16.07 GB, 8 files |
| `qwen38-27b-dflash2` | `incoai/Qwen3.8-27B-DFlash2` (BF16 source) | `dedf8df68adfb1afeaf7b7480c0a0243108177b4` | 3.85 GB |
| `qwen38-27b-dflash2-q8` | local only (Q8 converted from the above) | — | 2.04 GB |

- **Pinning:** every file is pinned by size and SHA-256 in `Sources/StudioModels/Resources/Catalog.json`.
- **How the Q4 repo was identified:** the local shards' SHA-256 values match the repo's LFS oids exactly, and so do the small files fetched at that commit.
- **DFlash2 draft:** downloads as the BF16 source. LSE converts it to MLX affine Q8/group64 the first time `--dflash2-model` opens it.
  - The result is cached in `lse-q8g64/` inside the draft directory.
  - The output is byte-identical to `convert_dflash2_q8.py`: `model.safetensors` sha256 `cc3b5742…14188`, 2,044,950,184 bytes.
  - The Q8 entry exists so that a copy pushed from a Mac is recognized and verified.

The LSE preset (`LSELaunchPreset.standard`):

```
--model <q4> --dflash2=on --dflash2-model <draft> --pool hrx:0 --dialect loom
--kv-cache-dtype bf16 --kv-len 32768 --temperature 0.6 --batch-size 1024 --ubatch-size 1024
```

`<draft>` can be either the BF16 source or the Q8 directory.

## API

```swift
let library = ModelLibrary.standard()        // once, at launch
await library.start()                        // reconcile Documents/Models, resume downloads
await library.download(catalogID: "qwen38-27b-q4")   // also fetches its DFlash2 draft and links it
library.launchArguments(for: "qwen38-27b-q4")        // [String] for LSE, with the linked draft
await library.pause(id); await library.resume(id); await library.cancel(id); await library.delete(id)
library.verify(id)                           // re-hash against the pinned digests
await library.link(main: id, draft: draftID) // pair a model with a DFlash2 draft (nil: none)
library.hubToken = "hf_…"                    // Keychain, this device only
let results = try await library.search.search("Qwen3.8 MLX")   // [HubSearchResult]
results.filter(HubSearchFilters(mtp: true, dflash2: true, layout: .dense, bits: 4).matches)
await library.download(result, draft: result.drafts.first, includeMTP: true)
```

Lower level, each usable on its own:

- `ModelCatalog`
- `ModelRegistry` (actor)
- `ModelDownloader` (actor)
- `HubClient`
- `CompatibleModelSearch`
- `ModelInspector`
- `ModelVerifier`
- `LSELaunchPreset`

## Storage and the registry

- **Model files:** `Documents/Models/<id>/` holds the installed models. The directories are excluded from iCloud backup. They live in Documents, never in Caches, so the system never purges them.
- **Downloads in progress:** they assemble in `Documents/Models/.partial/<id>/`, on the same volume. Installing is then a directory rename.
- **The registry:** `Application Support/StudioModels/registry.json`.
  - Each entry records the model's id and repo plus revision, and each file's size, SHA-256 or git blob id, and verification stamp.
  - It also holds the architecture, quantization, MTP layers, linked draft, state, and the added and last-used dates.
  - The file is written atomically and mirrored to `registry.json.bak`. An unreadable file is kept under a dated name and the backup is loaded instead.
- **On launch:**
  - Directories the registry doesn't know are adopted. They are matched to the catalog by name, by `hf-origin.json`, or by file sizes.
  - Missing models are marked missing, never dropped.
  - Interrupted downloads resume from the chunk lists recorded in the registry.

## Downloads

- **Session:** a background `URLSession` with identifier `com.geramyloveless.LemonSeedStudio.models`. It survives suspension and relaunch.
- **Chunking:** files over 256 MiB are fetched as independent HTTP `Range` chunks. A chunk interrupted mid-transfer resumes from URLSession resume data.
- **Parallelism:** at most 4 connections per host.
- **Before starting:** free space is checked. A BF16 DFlash2 draft also reserves room for LSE's Q8 conversion.
- **Verification:** SHA-256 is computed while the file assembles, in order. Files without a published SHA-256 (small non-LFS files) are checked against their git blob id.
- **Hugging Face token:** it is attached only to requests for `huggingface.co`. When the session asks about a redirect to the CDN, the token is removed; a suspended app's background session may follow redirects on its own, so this is not guaranteed.

## Hugging Face search

- **What is shown:** only checkpoints LSE loads, decided by LSE's own rules (see `ModelInspector.swift`). Tags are not trusted.
- **Per candidate:** the search fetches `config.json` and the tensor names (the index, or the safetensors header via two range requests) at the pinned commit. Responses are cached per commit.
- **Main models:** Qwen3.5-family MLX safetensors, dense or MoE, affine 2/3/4/5/6/8-bit with group 32/64/128, or unquantized. mxfp4, nvfp4, mxfp8 and GGUF are rejected, with the reason shown.
- **MTP facet:** follows LSE: `text_config.mtp_num_hidden_layers`, then a module in `mtp/` or a `-MTP` sibling repo with matching geometry. A sibling module downloads into `mtp/`, where LSE looks for it.
- **DFlash2 facet:** published drafts (`DFlash2DraftModel`) that pass LSE's geometry check:
  - `hidden_size` and `vocab_size` match;
  - `num_target_layers` equals the model's `num_hidden_layers`.

  Drafts that share the model's base model rank first.

## Using it in ProofOfLife

In `Engine/ProofOfLife/project.yml`, add the package and link both products to `LemonSeedStudio`:

```yaml
packages:
  StudioModels:
    path: ../../Packages/StudioModels
# targets.LemonSeedStudio.dependencies:
      - package: StudioModels
        product: StudioModels
      - package: StudioModels
        product: StudioModelsUI
```

In `LemonSeedStudioApp.swift`, create the library at launch, forward background-session events, and show the screen:

```swift
import StudioModels
import StudioModelsUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        LemonSeedStudioApp.models.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}

// in LemonSeedStudioApp:
@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
@MainActor static let models = ModelLibrary.standard()
// in the scene: ModelsView(library: Self.models), with .task { await Self.models.start() }
```

To make `Documents/Models` visible in the Files app as well, set `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` to `YES` in `App/Info.plist`.

## Copying models from the Mac (development)

`Tools/push-models-to-ipad.sh` copies this Mac's model directories into the app container with `devicectl`. Each one is equivalent to:

```sh
xcrun devicectl device copy to --device 0AFDDB50-F0FD-531C-9AAF-9FBFA68A8D5A \
  --domain-type appDataContainer --domain-identifier com.geramyloveless.LemonSeedStudio \
  --source ~/Documents/Development/mac_amdgpu/build/models/qwen38-27b-q4 \
  --destination Documents/Models/qwen38-27b-q4

xcrun devicectl device copy to --device 0AFDDB50-F0FD-531C-9AAF-9FBFA68A8D5A \
  --domain-type appDataContainer --domain-identifier com.geramyloveless.LemonSeedStudio \
  --source ~/Documents/Development/mac_amdgpu/build/models/qwen38-27b-dflash2-q8 \
  --destination Documents/Models/qwen38-27b-dflash2-q8
```

- **The BF16 source:** `push-models-to-ipad.sh dflash2` pushes the BF16 source from the HF cache, resolving its blob symlinks and adding `hf-origin.json`.
- **Checking the result:** `push-models-to-ipad.sh --list` shows what landed.
- **On the iPad:** open Models (or relaunch). The directories are adopted and linked; tap Verify to hash them against the catalog.

## Tests

`swift test` runs on macOS and needs no network.

- **Downloads:** run against a local server that mimics the Hub: redirect, `Range`, ETag, throttling and fault injection.
- **Search:** replays recorded API responses from `Tests/StudioModelsTests/Fixtures/hub`.

Gated runs:

```sh
STUDIO_MODELS_MAC_MODELS=~/Documents/Development/mac_amdgpu/build/models swift test --filter MacModelTests
STUDIO_MODELS_LIVE=1 swift test --filter LiveHubDownloadTests        # real Hub, small files
STUDIO_MODELS_RECORD_HUB=1 swift test --filter HubSearchTests         # re-record search fixtures
```

- **`MacModelTests`:** clones the Mac's model directories and verifies them against the catalog.
