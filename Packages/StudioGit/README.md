# StudioGit

Git, hosting and source control for LemonSeed Studio (planning/PLAN.md §2.8).

| Module | What it does |
|---|---|
| `Clibgit2` | libgit2 1.9.7 + libssh2 1.11.1 + OpenSSL 3.5.9, built from source as an XCFramework |
| `CGitShim` | C glue: non-variadic `git_libgit2_opts` wrappers, the native Git LFS filter |
| `GitKit` | Swift wrapper: repository actor, staging, commits, branches, merge, rebase, stash, cherry-pick, blame, remotes, clone/fetch/push/pull, submodules, credentials, SSH keys and signing, Git LFS |
| `Forge` | GitHub / GitLab accounts (OAuth device flow, personal tokens, Keychain), REST and GraphQL clients, pull/merge requests, CI, SSH key upload |
| `StudioGitUI` | SwiftUI: sign-in, accounts, SSH keys, repository browser and clone sheet, Source Control panel, conflict resolution, history graph, pull/merge requests |

Screenshots of every screen: `docs/screenshots/git/` (repository root).

## Building libgit2

```sh
Packages/StudioGit/scripts/build-libgit2.sh        # about 2 minutes on an M-series Mac
Packages/StudioGit/scripts/build-libgit2.sh clean
```

Needs Xcode 26, CMake and Perl (Ninja is used when present). The script
downloads pinned, SHA-256-checked release tarballs, builds OpenSSL, libssh2
and libgit2 for iOS device arm64, iOS simulator arm64 and macOS arm64 (the
macOS slice only runs the tests), merges each platform's static libraries
into one object that exports only `git_*` and `libssh2_*` symbols (OpenSSL
stays private, so another OpenSSL elsewhere in the app cannot collide), and
writes `build/Clibgit2.xcframework` with a `Clibgit2` module map. zlib and
iconv come from the SDK. `build/` is gitignored; rerunning is a no-op until
a pin or the script changes. Override `IOS_MIN` (26.2) or `MACOS_MIN` (15.0)
if needed.

Why OpenSSL: libgit2's SecureTransport backend is deprecated, and libssh2 has
no Apple-native crypto backend; its mbedTLS backend lacks Ed25519. One
OpenSSL build serves both. Certificates are checked against the system trust
store first (SecTrust in the certificate callback), then against the bundled
Mozilla CA list.

Licenses: see `THIRD_PARTY.md` at the repository root, including the note on
the LGPL-2.1 LibXDiff code inside libgit2.

## Tests

```sh
scripts/test.sh                  # swift test on the Mac (default, no simulator)
scripts/test.sh GitKitTests      # a filter
scripts/test.sh --ios            # the same suites on the shared iPad simulator, serially
scripts/ssh-test-server.sh       # local sshd: SSH push/clone and commit-signature checks
STUDIOGIT_NETWORK_TESTS=0 scripts/test.sh   # skip github.com / gitlab.com
```

114 tests in 15 suites (plus 5 SSH transport tests under the sshd script):

- local repositories: status, diffs, file/hunk/line staging and unstaging,
  discard, commits, log filters and graph layout, branches, tags, merge
  (fast-forward, merge commit, conflicts), rebase (clean, stop, continue,
  skip, abort), stash, cherry-pick, revert, blame;
- local bare remotes: clone, fetch, push (rejections, force, tags, delete),
  pull by merge and rebase, ahead/behind, submodules, cancellation, resuming
  an interrupted clone;
- network: shallow and resumable HTTPS clones of
  github.com/lemonade-sdk/amdgpu_mtopg, cancel-then-resume, SSH handshake with
  pinned host keys, unknown hosts rejected;
- SSH: key formats, Ed25519 and P-256 signatures, sshsig, OpenSSH private
  key import/export, key store; with the sshd script, push and clone through
  the in-process signers (the Secure Enclave code path), libssh2 PEM keys, and
  `git verify-commit` accepting GitKit's SSH-signed commits;
- Git LFS against an in-memory LFS server;
- Forge against an in-process HTTP stub (device flow, every client call,
  accounts, credentials), plus read-only live calls to GitHub and GitLab;
- UI models against sample repositories and sample forge data.

## Demo app

```sh
Demo/build.sh                     # unsigned simulator build (XcodeGen)
Demo/build.sh run -screen history # install and open a screen on the shared simulator
scripts/screenshots.sh            # refresh docs/screenshots/git
```

Screens: `changes`, `conflict`, `history`, `repositories`, `pulls`,
`devicecode`, `signin`, `accounts`, `keys`. Without a signed-in account the
repository browser and pull requests use `SampleForgeClient` data; after
signing in they use the real account.

## What the owner must configure

No OAuth client secret is used or stored anywhere. Sign-in uses the OAuth
device flow, which needs only a public client ID per forge.

**GitHub** (github.com, and once per GitHub Enterprise Server):

1. Settings → Developer settings → OAuth Apps → New OAuth App (an OAuth
   App, not a GitHub App, so the token carries classic scopes).
2. Homepage URL: the project page. Authorization callback URL: any valid URL
   (unused by the device flow).
3. Tick **Enable Device Flow**, register, and copy the **Client ID**.

**GitLab.com** (and once per self-hosted instance, GitLab 17.9 or later; 17.2
to 17.8 need the `oauth2_device_grant_flow` feature flag):

1. User Settings (or Admin Area for an instance-wide app) → Applications →
   Add new application.
2. Untick **Confidential**; scopes `api`, `read_user`, `write_repository`;
   any redirect URI.
3. Save and copy the **Application ID**.

Then give the IDs to the app, either way:

- build time: the app's Info.plist keys `StudioGitGitHubClientID` and
  `StudioGitGitLabClientID` (used for github.com and gitlab.com);
- run time: the sign-in screen shows a client-ID field when none is set
  (stored per host in UserDefaults; `OAuthAppSettings.setClientID`).

Without a client ID, or on a GitLab older than 17.9, users sign in with a
personal access token (the screen links to the token page and lists the
scopes). GitLab OAuth tokens expire after two hours and are refreshed
automatically with the stored refresh token.

## SSH keys: Secure Enclave or Ed25519

| | Secure Enclave (ECDSA P-256) | Ed25519 (Keychain) |
|---|---|---|
| Private key | generated inside the Secure Enclave, never readable, even by the app | Keychain item, this device only, never synced |
| Portability | none: tied to this iPad; erased with it | can be exported (OpenSSH format) |
| Algorithm | `ecdsa-sha2-nistp256` (the Secure Enclave supports only P-256) | `ssh-ed25519` |
| GitHub / GitLab | accepted for authentication and SSH commit signing | accepted for both |
| Recommended for | the default key on the iPad | using the same key elsewhere |

Both sign in-process: libssh2 calls GitKit's sign callback, so no private key
file ever exists. Keys are uploaded with one tap (authentication, signing, or
both) through the forge APIs. SSH commit signing (`sshsig`, namespace `git`)
is implemented and verified by `git verify-commit` in the sshd test.
Passphrase-protected key files can still be used through libssh2
(`GitCredential.sshPrivateKey`).

## Design notes

- **Threads.** `GitRepository` is an actor on its own serial dispatch queue;
  libgit2 calls never block the cooperative pool. Network operations open a
  second handle on a concurrent transfer queue so status and diffs stay
  responsive during a fetch; the actor reopens its handle afterwards.
  Cancelling the calling Task cancels the transfer (progress callbacks
  return an error).
- **Credentials.** One `CredentialProvider` answers every request
  (`ForgeCredentialProvider` maps host + owner to an account, or the
  repository's remembered `studio.account`). Tokens never leave Forge.
- **Host trust.** Pinned GitHub and GitLab.com host keys; other SSH hosts are
  trust-on-first-use through a confirmation prompt; changed keys are
  rejected.
- **Resumable clone.** The pack protocol cannot resume a half-received pack,
  so clones are staged: init and remote, a depth-1 snapshot, then the rest of
  the history, then LFS, checkout and submodules. Each finished stage is
  recorded in `.git/studio-clone.json`; cloning into the same folder again
  resumes from there and only fetches what is missing. For background
  completion the app wraps `GitRepository.clone` in a
  `BGContinuedProcessingTask` and passes a background `URLSession` for LFS.
- **Partial staging** rewrites the index blob directly from the selected
  diff lines, so hunk and line staging share one implementation.
- **Incremental status.** `StatusOptions.paths` limits status to the paths
  the file watcher reports.

### Git LFS

libgit2 does not run external filter processes, so GitKit implements LFS:

- a native `filter=lfs` filter registered with libgit2: clean stores the
  content in `.git/lfs/objects` and writes the pointer; smudge replaces a
  pointer with local content and leaves the pointer when the object is not
  local yet;
- a batch-API client (basic transfers): one batch per checkout, concurrent
  transfers, downloads resumed with HTTP Range from `.git/lfs/incomplete`,
  hash and size verification, uploads only of what the server lacks, verify
  actions, Basic auth from the credential provider;
- endpoints from `remote.<name>.lfsurl`, `lfs.url`, `.lfsconfig`, or derived
  from HTTPS/SSH remote URLs;
- clone prefetches the checkout's objects before checkout; push uploads the
  pushed branch's objects first; `lfsPull` / `lfsPush` on demand.

Limits: the filter buffers one file in memory (fine for typical assets, not
for multi-GB files; a streaming filter is the next step); push uploads the
objects referenced by the branch tip, not every commit in the pushed range;
no lock API; SSH remotes use the derived HTTPS endpoint with HTTPS
credentials (`git-lfs-authenticate` over SSH is not implemented).

## Plugging into the app shell

The app shell's `GitProviding` (StudioCore) maps onto this package in a few
lines: `status(for:)` opens `GitRepository.open(at:search: true)` and fills
`GitStatusSummary` from `head()`, `currentBranch()` (ahead/behind) and
`status()`; `makeSourceControlView(context:)` returns
`AnyView(SourceControlView(model: SourceControlModel(repository:services:)))`
with one shared `GitServices.standard()`. The design package themes every
Git view with `.gitTheme(_:)`.

## Known gaps

- Interactive rebase (reorder/squash/fixup) and partial staging of binary
  files are not implemented; rebase is non-interactive with continue, skip
  and abort.
- Partial clone (`--filter=blob:none`) is not available in libgit2; shallow
  clone and deepening are.
- GPG (rnp) signing is not implemented; SSH signing is.
- ASWebAuthenticationSession web-flow sign-in is not implemented; device flow
  and personal tokens are.
