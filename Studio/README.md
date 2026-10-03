# LemonSeed Studio (iPad app)

The IDE: the workspace shell (StudioCore, StudioDesign), the LemonText
editor, StudioAgent's AI panel on the in-process engine, StudioModels,
StudioGit, StudioTelemetry's GPU monitor and the terminal.

## Building

```sh
./build.sh                    # simulator build (no GPU driver, no engine)
./build.sh test               # app, UI and package tests on the simulator
./build.sh device             # device build with the embedded driver (compile check)
DEVICE=<CoreDevice id> ./build.sh install
DEVICE=<CoreDevice id> ./build.sh launch
```

Device builds embed the mac_linuxgpu DriverKit extension
(`com.geramyloveless.LemonSeedStudio.AMDGpuDriver`, built from
`MAC_LINUXGPU_DIR`), the linux-firmware set the HSA runtime serves from the
app bundle, and LSEKit (`Engine/LSEKit/LSE.xcframework`; refresh it with
`Engine/LSEKit/update-xcframework.sh`). Keep the driver's CFBundleVersion at
1: iPadOS stops launching a driver whose version changes. A new driver build
at the same version starts once the GPU is reconnected.

## Development remote control

Debug builds run a small HTTP server so the Mac can drive the app
(Settings › Developer › Remote control, on by default in debug builds;
compiled out of release builds):

- port 8765 on the Wi-Fi interface only (never cellular), advertised with
  Bonjour as `_lemonseed-dev._tcp`;
- every request needs the per-launch token, shown in Settings › Developer
  and written to `Documents/devserver.json`;
- the first launch asks for Local Network access on the iPad: allow it.

`scripts/studioctl` (Python, standard library) finds the iPad, reads the
token with `devicectl device copy from`, and wraps the API:

```sh
export STUDIO_DEVICE=<CoreDevice id>      # or let it pick the paired iPad
scripts/studioctl status
scripts/studioctl nav ai                  # explorer, ai, models, models-manager, gpu,
                                          # gpu-monitor, engine, diagnostics, load-settings,
                                          # source-control, search, terminal, settings
scripts/studioctl screenshot ai.png
scripts/studioctl shots ./screens         # every main screen
scripts/studioctl tree --grep engine      # accessibility hierarchy
scripts/studioctl tap engine.reload       # by accessibility identifier (or --label, --point x,y)
scripts/studioctl type "hello" --into agent.composer
scripts/studioctl key p --mod cmd         # Studio commands by shortcut, or keys into the focused input
scripts/studioctl drag sidebar.resize 120 # sidebar width (panel.resize for the panel)
scripts/studioctl rotate portrait
scripts/studioctl engine status           # lse_status, with device memory
scripts/studioctl engine reload --wait
scripts/studioctl request GET /v1/models
scripts/studioctl request POST /v1/chat/completions '{"model":"qwen-q4","messages":[{"role":"user","content":"hi"}],"max_tokens":64}' --stream
scripts/studioctl chat "What does src/main.c print?" --thinking low --session new
scripts/studioctl sessions
scripts/studioctl session delete <id>     # also asks the engine to drop its KV session
scripts/studioctl logs -f                 # app and engine log
scripts/studioctl driver --report         # driver state and the probe report
scripts/studioctl record-fixture r9700-idle --out ../Packages/StudioTelemetry/Sources/StudioTelemetry/Resources/Fixtures/r9700-idle.json
```

The HTTP API behind it (JSON; streams are server-sent events):

| Route | |
|---|---|
| `GET /status` | app, workspace, sidebar, engine and driver summary |
| `GET /ui/tree[?all=1]`, `GET /ui/find?id=` | accessibility elements of the key window: id, label, value, frame, traits |
| `POST /ui/tap {id\|label\|point}` | activates the element (VoiceOver's action) or the control at a point |
| `POST /ui/type {text, id?}`, `POST /ui/key {key, modifiers}` | text and keys into the first responder; shortcuts run Studio commands |
| `POST /ui/scroll {id?, dx, dy}`, `POST /ui/drag {id, dx, dy}`, `POST /ui/rotate` | scrolling, the resize handles, orientation |
| `GET /ui/screenshot[?delay=]` | PNG of the key window |
| `POST /nav {screen, sidebarWidth?}` | one of the main screens |
| `GET /engine/status`, `POST /engine/{start,stop,reload}` | the engine |
| `POST /engine/request {method, path, body}` | raw `lse_request`; streamed when the body has `"stream": true` |
| `POST /chat/send {text, session?, thinking?, mode?}` | a message in the AI panel, streamed: reasoning, text, tool and done events |
| `GET /chat/sessions`, `POST /chat/new`, `POST /chat/session/{close,delete} {id}` | chats |
| `GET /logs?since=`, `GET /driver/status` | logs, driver state |
| `POST /fixtures/record {name, seconds}`, `GET /file?path=` | StudioTelemetry fixtures; files under Documents |

The app never starts engine work on its own for testing: everything above
happens on request.
