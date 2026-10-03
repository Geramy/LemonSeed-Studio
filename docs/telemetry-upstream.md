# Upstreaming StudioTelemetry's split into amdgpu_mtopg

StudioTelemetry (`Packages/StudioTelemetry`) runs amdgpu_mtopg's MacLinuxGPU
monitor on iPadOS. To get there it splits two things that amdgpu_mtopg keeps
together: the IOKit transport and the data path, and the AppKit pieces and
the SwiftUI components. The goal is one PR to
[amdgpu_mtopg](https://github.com/lemonade-sdk/amdgpu_mtopg) that makes the
same split, so the Mac app and the Studio share one codebase through the
`third_party/amdgpu_mtopg` submodule. The submodule is not modified here.

Base: amdgpu_mtopg `afe1509`.

## 1. The transport protocol

Today `LinuxTransport` (LinuxDriver.swift) calls `IOServiceOpen(service,
mach_task_self_, 1, &port)` itself and keeps a raw `io_connect_t` per GPU;
`GPUSampler` (GPUDriver.swift) runs `IOServiceGetMatchingServices`.

Proposed (as in `Transport/ObserverConnection.swift`):

```swift
public typealias IOReturnCode = Int32

public struct ObserverReply: Sendable, Equatable {
    public var status: IOReturnCode
    public var words: [UInt64]
    public var bytes: [UInt8]
}

public protocol ObserverConnection: AnyObject {
    func call(selector: UInt32, scalars: [UInt64], input: [UInt8]?,
              outputWords: Int, outputBytes: Int) -> ObserverReply
    func close()
}

public protocol ObserverDirectory: Sendable {
    var sourceName: String { get }
    func devices() -> [ObserverDevice]                 // registry ID + label
    func openObserver(registryID: UInt64) throws -> any ObserverConnection
}
```

- `IOKitObserverDirectory` / `IOKitObserverConnection` hold the only IOKit
  calls: service enumeration by name, `IOServiceOpen(…, 1)` by registry entry
  ID (`IORegistryEntryIDMatching`), `IOConnectCallMethod`, `IOServiceClose`.
  On macOS these can call IOKit directly; StudioTelemetry routes them through
  a four-function C shim (`CMacLinuxGPUObserver`) because iPadOS has the
  IOKitLib headers and `IOKit.tbd` but no IOKit Swift module. The shim
  compiles unchanged for macOS, so mtopg can adopt it as is or keep direct
  calls in a macOS-only file.
- `LinuxTransport` takes a directory and reads by registry ID:
  `read(registry:) -> LinuxSample`. Its call sites change only in name
  (`c.port.call(…)` returning `ObserverReply` instead of the tuple).
  The two scalar-only calls (`IOConnectCallScalarMethod` for selectors 43 and
  21) become `call(…, input: nil, outputBytes: 0)`, which is the same
  `IOConnectCallMethod` underneath.
- The clock (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`) and the GRBM spacing
  `usleep` become injectable (`NanosecondClock`, `sleepMicroseconds`), so
  tests run a stepped clock.
- `kIOReturnNotReadyCode` / `kIOReturnNotPermittedCode` and the "lost"
  codes move into `IOReturnValue`, so nothing above the transport needs IOKit.

With the protocol in place mtopg gains two transports that need no GPU:

- `FixtureObserverConnection` replays a recorded fixture with the dext's own
  reply shapes (chunked SysfsRead with errno/count/length words, DrmInfo
  READ_MMR_REG, NotReady/NotPermitted gating). `check_linux_model.sh` can
  run the real transport, not just the model, offline against it.
- `RecordingObserverConnection` wraps any connection and writes a fixture
  (`FixtureRecorder`), e.g. behind an `MTOPG_RECORD=path` environment
  variable in the Mac app.

The fixture format (`lemonseed.observer-fixture` v1, see
`Transport/ObserverFixture.swift`) is plain JSON: per-second frames of sysfs
files (`text`, `hex` or `errno`), static discovery files, directory listings,
the cached-state selector replies, and raw GRBM_STATUS values with
millisecond timestamps. `Tools/capture_fixture.py` records the same format
from the Mac with mac_linuxgpu's `scripts/read-sysfs.py`.

## 2. The AppKit split

`Views.swift` imports AppKit only for Esc-to-quit (`escToQuit()`,
`NSViewRepresentableBridge`, `EscCatcher`). Everything else in it, and all of
`LinuxViews.swift`, is portable SwiftUI.

Proposed files:

| File | Contents | Platforms |
|---|---|---|
| `MtopgCommon.swift` | `SampleHistory.windowNs` / `maxPoints`, `fmt`, `fmtInt`, `errnoText` (now private to LinuxModel) | all |
| `MtopgComponents.swift` | `Palette`, `Panel`, `TimeSeriesChart`, `Meter`, `SourceCaption` | all |
| `EscToQuit.swift` | `escToQuit()`, `NSViewRepresentableBridge`, `EscCatcher` | macOS |
| `MonitorModel.swift` | MacAMDGPU's `SampleHistory` class body and snapshot, now using `MtopgCommon` | macOS |

`SampleHistory` is both a class (MacAMDGPU history) and the namespace for
the two constants LinuxModel uses. Splitting the constants into an enum
(`MtopgHistoryWindow`, or keep the name and move the class) is the only
rename the split needs.

`LinuxContentView` keeps `.escToQuit()` behind `#if os(macOS)` and replaces
`.help(row.source)` (pointer-only) with a visible source line on platforms
without hover; StudioTelemetry's `Meter` shows the source path under each
sensor row for that reason.

## 3. Model changes worth taking upstream

Small, each independently reviewable:

1. `LinuxSample` as a struct (it is copied field by field today to carry the
   slow tier forward; a value type makes that `var sample = previous` and is
   `Sendable` for free).
2. Name the snapshot's tuples: `SeriesPoint(age:value:)`,
   `UsagePair(used:total:)`, `LabeledText(label:text:)` for the PCIe rows.
   Tuples block `Equatable`/`Sendable` on `LinuxSnapshot`.
3. `LinuxClockRow.levelsSource` (the `pp_dpm_*` file the chips came from).
4. hwmon sensors: factor `hwmonSensorRows(_:hwmon:)` out of
   `makeLinuxSnapshot`, add `LinuxSensorRow.kind`, read `temp*_crit` and use
   it as the temperature scale when the driver reports it (labeled in the
   source), and append the driver's `power1_label` (e.g. "PPT") to the power
   rows. `LinuxPaths.hwmon` gains `temp1..3_crit` and `power1_label`.
5. Record `gpu_metrics`' errno in `errnos` so the clocks caption can say why
   it is missing (upstream drops the failure).

Nothing in the decoder changes: `GPUMetrics`, `GPUMetricsLayout.swift` and
`parseDPMLevels` are byte-for-byte upstream (the generated layout is copied
unchanged, so `gen_gpu_metrics.py` + `git diff --exit-code` still guards it).

## 4. Tests to bring along

StudioTelemetry's tests run the real transport over fixtures recorded from an
R9700 (gfx1201, gpu_metrics v1.3) on mac_linuxgpu build 229:

- every recorded gpu_metrics blob decodes by its header; a changed content
  revision, a short blob or a size field that disagrees are refused;
  all-ones fields read back nil;
- gpu_metrics temperatures agree with hwmon `temp*_input` within 3 °C, frame
  by frame: two independent driver paths, so a wrong offset fails;
- the SMU's `pcie_link_width` agrees with pci-sysfs `current_link_width`;
- every `pp_dpm_*` table parses with exactly one current level; idle sclk
  sits at the deep-sleep level `S`;
- hwmon rows use the driver's labels (edge, junction, mem; PPT) and scales;
- the GPU load equals the GUI_ACTIVE share of the GRBM values replayed;
- not-ready, older-dext and no-device paths report the driver's own words.

For mtopg these fit as a SwiftPM test target next to `check_linux_model.sh`,
or as extra cases in that script fed with a fixture file.

## 5. Suggested PR sequence

1. `MtopgCommon.swift` + `MtopgComponents.swift` + macOS-only `EscToQuit.swift`
   (no behaviour change).
2. `ObserverConnection` / `ObserverDirectory`, `IOKitObserver*`, and
   `LinuxTransport` on top of them (no behaviour change).
3. Fixture format, `FixtureObserverConnection`, `RecordingObserverConnection`,
   `MTOPG_RECORD`, and offline transport checks in CI.
4. The model refinements in section 3.

After that, StudioTelemetry's `Mtopg/` and `Transport/` directories can be
replaced by the submodule's sources, leaving only the Studio's service,
theme and views in the package.
