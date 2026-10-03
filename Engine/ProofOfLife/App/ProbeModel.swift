import Foundation
import Combine
import UIKit
import os

let probeLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "probe")

struct ProbeResult: Identifiable {
    enum Outcome { case ok, failed, info }

    let id = UUID()
    let step: String
    let outcome: Outcome
    let detail: String

    var line: String {
        let mark: String
        switch outcome {
        case .ok: mark = "OK  "
        case .failed: mark = "FAIL"
        case .info: mark = "    "
        }
        return "[\(mark)] \(step): \(detail)"
    }
}

/// Driver presence, kept current by IOKit match/terminate notifications.
struct DriverState {
    var embeddedDext: String = "checking"
    var service: String = "checking"
    var serviceFound = false
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published private(set) var state = DriverState()
    @Published private(set) var results: [ProbeResult] = []
    @Published private(set) var probing = false
    @Published private(set) var lastProbe: Date?

    private var notifyPort: IONotificationPortRef?
    private var notifyIterators: [io_iterator_t] = []

    init() {
        state.embeddedDext = Self.describeEmbeddedDext()
        probeLog.log("app start; embedded dext: \(self.state.embeddedDext, privacy: .public)")
        refresh()
        watchService()
        if Self.autoProbe {
            // Remote runs: probe once the service lookup has settled, then
            // publish the report on stdout and in Documents for collection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                if self.state.serviceFound { self.probe() } else { self.publishReport() }
            }
        }
    }

    static let autoProbe = ProcessInfo.processInfo.arguments.contains("--auto-probe")

    /// Writes the report to Documents/probe-report.txt and stdout.
    func publishReport() {
        let text = report + "\n"
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: docs.appendingPathComponent("probe-report.txt"), atomically: true, encoding: .utf8)
        }
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    // MARK: Driver state

    static func describeEmbeddedDext() -> String {
        let folder = Bundle.main.bundleURL.appendingPathComponent("SystemExtensions")
        let url = folder.appendingPathComponent("\(MLG.dextBundleID).dext")
        guard let bundle = Bundle(url: url) else {
            let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return present.isEmpty ? "missing (no SystemExtensions folder content)"
                                   : "missing; found \(present.joined(separator: ", "))"
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(MLG.dextBundleID) \(version) (\(build))"
    }

    func refresh() {
        let (found, kr) = DriverLookup.find()
        if let found {
            state.serviceFound = true
            state.service = String(format: "running: %@ registry 0x%llx (%d match%@), server %@",
                                   found.className, found.registryID, found.matchCount,
                                   found.matchCount == 1 ? "" : "es", found.serverDescription)
            IOObjectRelease(found.service)
        } else if kr != KERN_SUCCESS {
            state.serviceFound = false
            state.service = "lookup failed: \(describeIOReturn(kr))"
        } else {
            state.serviceFound = false
            state.service = "not running (driver off in Settings, or no AMD GPU attached)"
        }
        probeLog.log("driver service: \(self.state.service, privacy: .public)")
    }

    private func watchService() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator to re-arm the notification.
            while case let service = IOIteratorNext(iterator), service != 0 {
                IOObjectRelease(service)
            }
            guard let refcon else { return }
            let model = Unmanaged<ProbeModel>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { model.refresh() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(port, type,
                                                      IOServiceNameMatching(MLG.serviceName),
                                                      callback, context, &iterator)
            if kr == KERN_SUCCESS {
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                notifyIterators.append(iterator)
            } else {
                probeLog.error("matching notification failed: \(describeIOReturn(kr), privacy: .public)")
            }
        }
    }

    // MARK: Probe

    func probe() {
        guard !probing else { return }
        probing = true
        results = []
        probeLog.log("probe begin")
        Task.detached(priority: .userInitiated) {
            let collected = ProbeRun.run { result in
                probeLog.log("\(result.line, privacy: .public)")
            }
            await MainActor.run {
                self.results = collected
                self.probing = false
                self.lastProbe = Date()
                probeLog.log("probe end: \(collected.filter { $0.outcome == .failed }.count) failure(s)")
                self.refresh()
                if Self.autoProbe { self.publishReport() }
            }
        }
    }

    // MARK: Report

    var report: String {
        let device = UIDevice.current
        var lines: [String] = []
        let app = Bundle.main
        let version = app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("LemonSeed Studio proof of life \(version) (\(build))")
        lines.append("Device: \(Self.machine()) \(device.systemName) \(device.systemVersion)")
        if let lastProbe {
            lines.append("Probe: \(ISO8601DateFormatter().string(from: lastProbe))")
        }
        lines.append("Embedded dext: \(state.embeddedDext)")
        lines.append("Driver service: \(state.service)")
        lines.append("")
        if results.isEmpty {
            lines.append("(no probe run yet)")
        } else {
            lines.append(contentsOf: results.map(\.line))
        }
        return lines.joined(separator: "\n")
    }

    func copyReport() {
        UIPasteboard.general.string = report
        probeLog.log("report copied (\(self.results.count) result lines)")
    }

    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

/// The probe itself: identity and BARs only. It never calls InitDevice or
/// any selector that reaches the GPU's registers.
enum ProbeRun {
    static func run(emit: (ProbeResult) -> Void) -> [ProbeResult] {
        var results: [ProbeResult] = []
        func add(_ step: String, _ outcome: ProbeResult.Outcome, _ detail: String) {
            let result = ProbeResult(step: step, outcome: outcome, detail: detail)
            results.append(result)
            emit(result)
        }
        func failed(_ step: String, _ kr: kern_return_t) {
            add(step, .failed, describeIOReturn(kr))
        }

        let (found, lookup) = DriverLookup.find()
        guard let found else {
            add("Find service \"\(MLG.serviceName)\"", .failed,
                lookup == KERN_SUCCESS ? "no matching service" : describeIOReturn(lookup))
            return results
        }
        defer { IOObjectRelease(found.service) }
        add("Find service \"\(MLG.serviceName)\"", .ok,
            String(format: "%@ registry 0x%llx, %d match(es), server %@", found.className,
                   found.registryID, found.matchCount, found.serverDescription))

        // Session client (type 0).
        let (sessionClient, openKR) = UserClient.open(found.service, type: .session)
        var observer: UserClient?
        if let session = sessionClient {
            add("Open session client (type 0)", .ok, String(format: "connection 0x%x", session.connection))

            let (pingKR, ping) = session.call(.ping, outputs: 1)
            if pingKR == KERN_SUCCESS, let value = ping.first {
                add("Ping (0)", value == MLG.pingMagic ? .ok : .failed,
                    String(format: "0x%llx%@", value, value == MLG.pingMagic ? "" : " (expected 0xa117ab1e)"))
            } else { failed("Ping (0)", pingKR) }

            let (idKR, id) = session.call(.getIdentity, outputs: 9)
            if idKR == KERN_SUCCESS, id.count >= 7 {
                var text = String(format: "%04llx:%04llx at %02llx:%02llx.%llu, class 0x%06llx rev 0x%02llx",
                                  id[3], id[4], id[0], id[1], id[2], id[5], id[6])
                if id.count >= 9 {
                    text += String(format: ", subsystem %04llx:%04llx", id[7], id[8])
                }
                add("GetIdentity (1)", .ok, text)
            } else { failed("GetIdentity (1)", idKR) }

            for bar in UInt64(0)..<6 {
                let (barKR, info) = session.call(.getBARInfo, [bar], outputs: 3)
                if barKR == KERN_SUCCESS, info.count >= 3 {
                    add("GetBARInfo (2) BAR\(bar)", .ok,
                        "\(formatBytes(info[1])), \(MLG.barType(info[2])), memoryIndex \(info[0])")
                } else if UInt32(bitPattern: barKR) == 0xE000_02F0 { // kIOReturnNotFound
                    add("GetBARInfo (2) BAR\(bar)", .info, "not present (\(describeIOReturn(barKR)))")
                } else { failed("GetBARInfo (2) BAR\(bar)", barKR) }
            }

            for bar in UInt64(0)..<6 {
                let (rebarKR, info) = session.call(.getReBARInfo, [bar], outputs: 6)
                if rebarKR == KERN_SUCCESS, info.count >= 6 {
                    add("GetReBARInfo (41) BAR\(bar)", .ok,
                        String(format: "cap offset 0x%llx cap 0x%llx ctl 0x%llx supported 0x%llx selected %@ assigned %@",
                               info[0], info[1], info[2], info[3],
                               formatBytes(info[4]), formatBytes(info[5])))
                } else { failed("GetReBARInfo (41) BAR\(bar)", rebarKR) }
            }

            let (buildKR, build) = session.call(.runtimeBuild, outputs: 4)
            if buildKR == KERN_SUCCESS, build.count >= 3 {
                var text = String(format: "magic 0x%llx ABI %llu build %llu", build[0], build[1], build[2])
                if build.count >= 4 { text += " (compiled build \(build[3]))" }
                add("RuntimeBuild (43) [session]", .ok, text)
            } else { failed("RuntimeBuild (43) [session]", buildKR) }
        } else {
            failed("Open session client (type 0)", openKR)
        }

        // Observer client (type 1): cached state only.
        let (observerClient, observerKR) = UserClient.open(found.service, type: .observer)
        observer = observerClient
        if let observer {
            add("Open observer client (type 1)", .ok, String(format: "connection 0x%x", observer.connection))
            readSessionState(observer, label: "while session open", add: add, failed: failed)

            let (statusKR, status) = observer.call(.queryInfo, [MLG.queryProbeStatus], outputs: 5)
            if statusKR == KERN_SUCCESS, status.count >= 5 {
                add("QueryInfo probe status (0x4c50524f)", .ok,
                    "attempted \(status[0]) modules-running \(status[1]) result \(Int64(bitPattern: status[2])) "
                    + "transport-fault \(status[3]) fault-offset 0x\(String(status[4], radix: 16))")
            } else { failed("QueryInfo probe status (0x4c50524f)", statusKR) }

            let (buildKR, build) = observer.call(.runtimeBuild, outputs: 3)
            if buildKR == KERN_SUCCESS, build.count >= 3 {
                add("RuntimeBuild (43) [observer]", .ok,
                    String(format: "magic 0x%llx ABI %llu build %llu", build[0], build[1], build[2]))
            } else { failed("RuntimeBuild (43) [observer]", buildKR) }
        } else {
            failed("Open observer client (type 1)", observerKR)
        }

        if let session = sessionClient {
            let kr = session.close()
            if kr == KERN_SUCCESS { add("Close session client", .ok, "closed") }
            else { failed("Close session client", kr) }
            if let observer {
                // The dext finishes the session close asynchronously.
                Thread.sleep(forTimeInterval: 0.5)
                readSessionState(observer, label: "after session close", add: add, failed: failed)
            }
        }
        if let observer {
            let kr = observer.close()
            if kr == KERN_SUCCESS { add("Close observer client", .ok, "closed") }
            else { failed("Close observer client", kr) }
        }
        return results
    }

    private static func readSessionState(_ observer: UserClient, label: String,
                                         add: (String, ProbeResult.Outcome, String) -> Void,
                                         failed: (String, kern_return_t) -> Void) {
        let step = "QueryInfo session state (0x4c534553) \(label)"
        let (kr, s) = observer.call(.queryInfo, [MLG.querySessionState], outputs: MLG.sessionStateWords)
        guard kr == KERN_SUCCESS, s.count >= MLG.sessionStateWords else { return failed(step, kr) }
        add(step, .ok,
            "v\(s[0]) flags 0x\(String(s[1], radix: 16)) [\(MLG.describeFlags(s[1]))], "
            + "quarantine \(MLG.name(MLG.quarantineCauses, s[2])) code \(Int64(bitPattern: s[3])) step \(s[4]), "
            + "isolation \(Int64(bitPattern: s[5])), release \(MLG.name(MLG.releaseBlockers, s[6])), "
            + "generation \(s[7]), participants \(s[8])")
    }
}
