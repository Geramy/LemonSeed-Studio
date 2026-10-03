// StudioTelemetry: what the GPU screen shows without live data.
//
// Each state explains what is missing and what fixes it (PLAN 2.12.4), and
// quotes the driver's own status line. Nothing is shown as a zero.

import SwiftUI

public struct GPUEmptyStateView: View {
    public let state: TelemetryState
    @Environment(\.colorScheme) private var scheme

    public init(state: TelemetryState) {
        self.state = state
    }

    private struct Copy {
        let symbol: String
        let title: String
        let body: String
        let driverLine: String?
    }

    private var copy: Copy {
        switch state.availability {
        case .driverNotEnabled:
            return Copy(symbol: "puzzlepiece.extension",
                        title: "Enable the LemonSeed driver",
                        body: "Turn it on in Settings › General › Drivers › LemonSeed Studio. The GPU monitor reads the driver's read-only observer; nothing runs on the GPU until you start it.",
                        driverLine: nil)
        case .noDevice:
            return Copy(symbol: "cable.connector.horizontal",
                        title: "No GPU connected",
                        body: "Connect the GPU enclosure over Thunderbolt. Using a dock? Connect the GPU to a Thunderbolt downstream port. If it is connected, the driver may not be enabled in Settings › General › Drivers.",
                        driverLine: "no \(LinuxABI.serviceName) service in the I/O Registry")
        case .notRunning(let status):
            return Copy(symbol: "moon.zzz",
                        title: "GPU attached, no session yet",
                        body: "The driver sees the GPU, but upstream amdgpu is not running in a GPU session, so there is nothing to read. Telemetry starts as soon as a session opens (Start GPU, the agent or Kernel Lab). The monitor never opens one itself.",
                        driverLine: status)
        case .unsupported(let status):
            return Copy(symbol: "arrow.triangle.2.circlepath",
                        title: "Driver update needed",
                        body: "This driver build answers the observer but not its Linux reads. Update the LemonSeed driver to read GPU telemetry.",
                        driverLine: status)
        case .error(let message):
            return Copy(symbol: "exclamationmark.triangle",
                        title: "Can't read the GPU",
                        body: "The observer connection failed. Unplugging and reconnecting the GPU usually clears it; the editor, builds and Git are unaffected.",
                        driverLine: message)
        case .starting, .live:
            return Copy(symbol: "cpu", title: "Reading the GPU…", body: "", driverLine: nil)
        }
    }

    public var body: some View {
        let theme = TelemetryTheme.forScheme(scheme)
        let copy = copy
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(theme.lemon.opacity(scheme == .dark ? 0.14 : 0.22)).frame(width: 132, height: 132)
                Circle().strokeBorder(theme.lemon.opacity(0.55), lineWidth: 1).frame(width: 96, height: 96)
                Image(systemName: copy.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(theme.ink)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)
            Text(copy.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Text(copy.body)
                .font(.system(size: 15))
                .foregroundStyle(theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            VStack(spacing: 6) {
                if let line = copy.driverLine {
                    sourceLine("driver", line)
                }
                if let build = state.snapshot.build, build > 0 {
                    sourceLine("runtime", "ABI \(build)")
                }
                sourceLine("source", state.sourceName)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.hairline))
            .frame(maxWidth: 560)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceLine(_ label: String, _ text: String) -> some View {
        let theme = TelemetryTheme.forScheme(scheme)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundStyle(theme.inkMuted).frame(width: 52, alignment: .trailing)
            Text(text).font(TelemetryFont.source).foregroundStyle(theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
