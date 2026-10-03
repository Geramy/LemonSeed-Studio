// Copied from Engine/ProofOfLife/App/BringUp.swift for the Diagnostics screen.
#if LEMONSEED_DEVICE
import Foundation

/// The linux-firmware files the app bundles: exactly the entries of
/// mac_linuxgpu firmware/firmware.lock, laid out under Firmware/ the way
/// /lib/firmware is ("amdgpu/<name>.bin"), checked against the lock's SHA-256
/// at build time (scripts/bundle-firmware.sh). The servicer serves whatever
/// upstream requests from here; a name that is not present is reported
/// missing and upstream sees -ENOENT, as on Linux and macOS.
enum BundledFirmware {
    static var root: URL {
        Bundle.main.bundleURL.appendingPathComponent("Firmware", isDirectory: true)
    }

    struct Summary {
        var files = 0
        var bytes: UInt64 = 0
        var tag = "?"
        var commit = "?"
    }

    static func summary() -> Summary? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return nil }
        var summary = Summary()
        for case let url as URL in walker where url.lastPathComponent != "firmware.lock" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            summary.files += 1
            summary.bytes += UInt64(values?.fileSize ?? 0)
        }
        if let lock = try? String(contentsOf: root.appendingPathComponent("firmware.lock"), encoding: .utf8) {
            for line in lock.split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2 else { continue }
                if fields[0] == "tag" { summary.tag = String(fields[1]) }
                if fields[0] == "commit" { summary.commit = String(fields[1].prefix(12)) }
            }
        }
        return summary.files > 0 ? summary : nil
    }
}

/// mac_linuxgpu's user-space firmware servicer (host/fw_mailbox_service.c,
/// host/fw_mailbox_iokit.c) on one session connection.
final class FirmwareServicer: @unchecked Sendable {
    private let handle: OpaquePointer

    private init(handle: OpaquePointer) { self.handle = handle }

    /// mlg_fw_service_start_connection: maps the dext's mailbox
    /// (MLG_FW_MAILBOX_MEMORY_TYPE) and starts the polling thread. Returns
    /// the servicer or the negative errno.
    static func start(connection: io_connect_t, root: URL) -> (FirmwareServicer?, Int32) {
        var service: OpaquePointer?
        let ret = root.path.withCString { mlg_fw_service_start_connection(UInt32(connection), $0, &service) }
        guard ret == 0, let service else { return (nil, ret) }
        return (FirmwareServicer(handle: service), 0)
    }

    /// Files answered with data and requests for files that were not found.
    /// Read while the servicer thread runs; diagnostic only.
    var served: UInt64 { mlg_fw_service_served(handle) }
    var missing: UInt64 { mlg_fw_service_missing(handle) }

    private var stopped = false

    /// Detach (the dext then fails further requests at once), join the thread
    /// and unmap. Called once, from the thread that owns the bring-up.
    func stop() {
        guard !stopped else { return }
        stopped = true
        mlg_fw_service_stop(handle)
    }
}

/// A blocking call on its own thread that the caller waits for with a
/// timeout. A user-client call cannot be cancelled; when the wait times out
/// the call keeps running and `abandon` hands its result, and the cleanup
/// that must follow it (stopping the servicer, closing the client), to a
/// closure that runs on that thread when the driver finally answers. Nothing
/// is ever closed underneath a call that is still in flight.
final class Outstanding<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: T?
    private var late: ((T) -> Void)?

    init(_ name: String, _ body: @escaping () -> T) {
        let thread = Thread { [self] in
            let value = body()
            lock.lock()
            result = value
            let handler = late
            lock.unlock()
            done.signal()
            handler?(value)
        }
        thread.name = name
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// The result, or nil if the call has not returned within `timeout`.
    func wait(_ timeout: TimeInterval) -> T? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        done.signal() // keep it signalled for later waits
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Run `handler` with the result once the call returns (at once if it
    /// returned in the meantime).
    func abandon(_ handler: @escaping (T) -> Void) {
        lock.lock()
        if let result {
            lock.unlock()
            handler(result)
            return
        }
        late = handler
        lock.unlock()
    }
}

struct BringUpConfig {
    /// How long to wait for InitDevice before reporting it hung.
    var initTimeout: TimeInterval = 300
    /// How long to wait for a cached-state read or a client open/close.
    var readTimeout: TimeInterval = 15

    static func fromArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> BringUpConfig {
        var config = BringUpConfig()
        for argument in arguments where argument.hasPrefix("--bringup-timeout=") {
            if let seconds = TimeInterval(argument.dropFirst("--bringup-timeout=".count)), seconds > 0 {
                config.initTimeout = seconds
            }
        }
        return config
    }
}

/// What a bring-up hands back to the model as it goes.
struct BringUpSink: @unchecked Sendable {
    /// One result line; `checkpoint` asks for the report file to be rewritten.
    var emit: (ProbeResult, _ checkpoint: Bool) -> Void
    /// Transient progress for the UI and stdout.
    var progress: (String) -> Void
    /// The driver log read after InitDevice.
    var driverLog: (KernelLogRead) -> Void
    /// Called once, when nothing the bring-up started is still in flight.
    /// `late` is true when that happened after `run` returned.
    var settled: (_ late: Bool) -> Void
}

/// Device initialization: the macOS host's `init` sequence
/// (MacLinuxGPUHost.initDevice in mac_linuxgpu host/MacLinuxGPUHostApp.swift)
/// with the same selectors, followed by the reads the host and
/// scripts/read-driver-log.py make:
///
///   observer (type 1)  QueryInfo 'LSES': refuse to initialize a quarantined driver
///   session  (type 0)  Ping, QueryInfo 'LPRO'
///   servicer           mlg_fw_service_start_connection(session, <bundle>/Firmware)
///   session            InitDevice (9): the upstream amdgpu PCI probe
///   servicer           served/missing counters, mlg_fw_service_stop
///   session            QueryInfo 'LPRO', 'LSES'; IOServiceClose
///   observer           QueryInfo 'LPRO', 'LSES', 'LLOG' (driver log); IOServiceClose
///
/// It never uses a selector that kills or resets the dext. A call that does
/// not return in time is reported and left to finish; the session is closed
/// on the calling thread once it does.
enum BringUpRun {
    private static let busy: Set<UInt32> = [0xE000_02D5, 0xE000_02C5] // kIOReturnBusy, kIOReturnExclusiveAccess

    /// Returns when the bring-up finished or a call timed out. In the second
    /// case `sink.settled(true)` follows later.
    static func run(config: BringUpConfig, sink: BringUpSink) {
        let clock = ContinuousClock()
        let begin = clock.now
        func elapsed(_ from: ContinuousClock.Instant) -> String {
            let d = clock.now - from
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            return ms < 1000 ? String(format: "%.1f ms", ms) : String(format: "%.2f s", ms / 1000)
        }
        func add(_ step: String, _ outcome: ProbeResult.Outcome, _ detail: String, checkpoint: Bool = false) {
            sink.emit(ProbeResult(step: step, outcome: outcome, detail: detail), checkpoint)
        }
        func failed(_ step: String, _ kr: kern_return_t) { add(step, .failed, describeIOReturn(kr)) }

        // Firmware.
        let root = BundledFirmware.root
        if let fw = BundledFirmware.summary() {
            add("Bundled firmware", .ok,
                "\(fw.files) files, \(formatBytes(fw.bytes)), linux-firmware \(fw.tag) (\(fw.commit)) at \(root.path)")
        } else {
            add("Bundled firmware", .failed,
                "no files under \(root.path); every request will be reported missing")
        }

        sink.progress("Finding the driver")
        let (found, lookup) = DriverLookup.find()
        guard let found else {
            add("Find service \"\(MLG.serviceName)\"", .failed,
                lookup == KERN_SUCCESS ? "no matching service" : describeIOReturn(lookup))
            return sink.settled(false)
        }
        defer { IOObjectRelease(found.service) }
        add("Find service \"\(MLG.serviceName)\"", .ok,
            String(format: "registry 0x%llx, server %@", found.registryID, found.serverDescription))

        // Preflight: never initialize a quarantined driver, and let a session
        // that is still closing (the probe's) finish first.
        sink.progress("Checking the driver session state")
        let service = found.service
        IOObjectRetain(service)
        let preflight = Outstanding<(kern_return_t, [UInt64]?)>("bringup.preflight") {
            defer { IOObjectRelease(service) }
            let (observer, kr) = UserClient.open(service, type: .observer)
            guard let observer else { return (kr, nil) }
            var last: (kern_return_t, [UInt64]?) = (KERN_SUCCESS, nil)
            for _ in 0..<20 {
                last = observer.sessionState()
                guard let state = last.1, state[1] & MLG.flagClosing != 0 else { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            _ = observer.close()
            return last
        }
        guard let pre = preflight.wait(config.readTimeout) else {
            add("Preflight session state", .failed,
                "observer did not answer within \(Int(config.readTimeout)) s; the driver is busy. Not initializing.")
            preflight.abandon { _ in sink.settled(true) }
            return
        }
        let (preKR, preState) = pre
        if let preState {
            add("Preflight session state", .ok, MLG.describeSessionState(preState))
            if let advice = MLG.quarantineAdvice(preState) {
                add("Initialize", .failed, "not attempted: \(advice)", checkpoint: true)
                return sink.settled(false)
            }
        } else {
            add("Preflight session state", .info, "unavailable (\(describeIOReturn(preKR))); continuing")
        }

        // Session client, with retries while the previous session finishes closing.
        sink.progress("Opening the session client")
        var session: UserClient?
        var openKR: kern_return_t = KERN_SUCCESS
        for attempt in 0..<20 {
            (session, openKR) = UserClient.open(found.service, type: .session)
            if session != nil || !busy.contains(UInt32(bitPattern: openKR)) { break }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.5) }
        }
        guard let session else {
            failed("Open session client (type 0)", openKR)
            return sink.settled(false)
        }
        add("Open session client (type 0)", .ok, String(format: "connection 0x%x", session.connection))

        let (pingKR, ping) = session.call(.ping, outputs: 1)
        if pingKR == KERN_SUCCESS, ping.first == MLG.pingMagic {
            add("Ping (0)", .ok, String(format: "0x%llx", ping[0]))
        } else if pingKR == KERN_SUCCESS {
            add("Ping (0)", .failed, String(format: "0x%llx (expected 0xa117ab1e)", ping.first ?? 0))
        } else { failed("Ping (0)", pingKR) }

        let (beforeKR, before) = session.probeStatus()
        if let before { add("Probe status before InitDevice", .ok, MLG.describeProbeStatus(before)) }
        else { failed("Probe status before InitDevice", beforeKR) }

        // Firmware servicer.
        sink.progress("Starting the firmware servicer")
        let servicerStart = clock.now
        let (servicer, startErr) = FirmwareServicer.start(connection: session.connection, root: root)
        if servicer != nil {
            add("Firmware servicer start", .ok, "mailbox mapped, root \(root.path), \(elapsed(servicerStart))")
        } else {
            // As on macOS: InitDevice still runs, with the dext's embedded
            // fallback table only.
            add("Firmware servicer start", .failed,
                "error \(startErr) (\(String(cString: strerror(-startErr)))); embedded fallback only")
        }

        // Host window: reserve the GART aperture's size in this process and
        // hand its base to the driver before InitDevice, exactly as the HSA
        // runtime's initializeDevice does. Only a placement hint, released
        // once InitDevice returns.
        var reservation: (UnsafeMutableRawPointer, Int)?
        let (queryKR, query) = session.call(.hostWindow, [0], outputs: 3)
        if queryKR == KERN_SUCCESS, query.count == 3 {
            let bytes = query[1]
            if bytes >= 16384, bytes & (bytes - 1) == 0, bytes <= 1 << 45,
               let raw = mmap(nil, Int(bytes) * 2, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0),
               raw != MAP_FAILED {
                reservation = (raw, Int(bytes) * 2)
                let base = (UInt64(UInt(bitPattern: raw)) + bytes - 1) & ~(bytes - 1)
                if base >= 1 << 32, base < (1 << 47) - bytes {
                    let (setKR, set) = session.call(.hostWindow, [base], outputs: 3)
                    if setKR == KERN_SUCCESS, set.count == 3, set[0] == base, set[1] == bytes {
                        add("Host window (54)", .ok, String(format: "base 0x%llx, %llu MiB", base, bytes >> 20))
                    } else if setKR == KERN_SUCCESS {
                        add("Host window (54)", .failed, String(format: "driver answered base 0x%llx size 0x%llx", set.first ?? 0, set.count > 1 ? set[1] : 0))
                    } else { failed("Host window (54)", setKR) }
                } else {
                    add("Host window (54)", .failed, String(format: "reserved base 0x%llx is outside [4 GiB, 128 TiB)", base))
                }
            } else {
                add("Host window (54)", .failed, String(format: "cannot reserve 0x%llx bytes (errno %d)", bytes, errno))
            }
        } else { failed("Host window query (54)", queryKR) }
        func releaseHostWindow() {
            if let (raw, length) = reservation { munmap(raw, length); reservation = nil }
        }

        // InitDevice.
        add("InitDevice (9)", .info,
            "started; timeout \(Int(config.initTimeout)) s. A hang or panic leaves this as the last line.",
            checkpoint: true)
        let initStart = clock.now
        let initCall = Outstanding<kern_return_t>("bringup.initdevice") {
            session.call(.initDevice, outputs: 0).0
        }
        var initKR: kern_return_t?
        var lastPrint = clock.now
        while initKR == nil, clock.now - initStart < .seconds(config.initTimeout) {
            initKR = initCall.wait(0.25)
            let fw = servicer.map { ", firmware served \($0.served), missing \($0.missing)" } ?? ""
            let line = "InitDevice running \(elapsed(initStart))\(fw)"
            sink.progress(line)
            if clock.now - lastPrint >= .seconds(5) {
                lastPrint = clock.now
                print("[bring-up] \(line)")
            }
        }

        // Everything after InitDevice: also the late path when it timed out.
        func finish(_ kr: kern_return_t, late: Bool) {
            releaseHostWindow()
            let duration = elapsed(initStart)
            if kr == KERN_SUCCESS {
                add("InitDevice (9)", .ok, "upstream PCI probe completed in \(duration)\(late ? " (after the timeout)" : "")")
            } else {
                add("InitDevice (9)", .failed, "\(describeIOReturn(kr)) after \(duration)\(late ? " (after the timeout)" : "")")
            }
            if let servicer {
                let served = servicer.served, missing = servicer.missing
                let stopStart = clock.now
                servicer.stop()
                add("Firmware servicer", missing == 0 && served > 0 ? .ok : .info,
                    "served \(served) file(s), \(missing) not found; stopped in \(elapsed(stopStart))")
            }
            let (afterKR, after) = session.probeStatus()
            if let after { add("Probe status after InitDevice", after[2] == 0 && after[1] != 0 ? .ok : .failed, MLG.describeProbeStatus(after)) }
            else { failed("Probe status after InitDevice", afterKR) }
            let (stateKR, state) = session.sessionState()
            if let state {
                add("Session state after InitDevice", MLG.quarantineAdvice(state) == nil ? .ok : .failed,
                    MLG.describeSessionState(state) + (MLG.quarantineAdvice(state).map { "; \($0)" } ?? ""))
            } else { failed("Session state after InitDevice", stateKR) }
            let closeKR = session.close()
            if closeKR == KERN_SUCCESS { add("Close session client", .ok, "closed", checkpoint: true) }
            else { failed("Close session client", closeKR) }
        }

        // Driver log and cached state through an observer, which reads them
        // without joining or reopening a session.
        func observerReads() -> [(ProbeResult, Bool)] {
            var out: [(ProbeResult, Bool)] = []
            func note(_ step: String, _ outcome: ProbeResult.Outcome, _ detail: String) {
                out.append((ProbeResult(step: step, outcome: outcome, detail: detail), false))
            }
            Thread.sleep(forTimeInterval: 0.5) // the dext finishes a session close asynchronously
            let (observer, kr) = UserClient.open(service, type: .observer)
            guard let observer else {
                note("Open observer client (type 1)", .failed, describeIOReturn(kr))
                return out
            }
            let (pKR, p) = observer.probeStatus()
            if let p { note("Probe status [observer]", .info, MLG.describeProbeStatus(p)) }
            else { note("Probe status [observer]", .failed, describeIOReturn(pKR)) }
            let (sKR, s) = observer.sessionState()
            if let s { note("Session state [observer]", .info, MLG.describeSessionState(s)) }
            else { note("Session state [observer]", .failed, describeIOReturn(sKR)) }
            let readStart = clock.now
            let log = observer.kernelLog()
            sink.driverLog(log)
            if let error = log.error {
                note("Driver log (QueryInfo 0x4c4c4f47)", .failed, "\(error) after \(log.text.utf8.count) bytes")
            } else {
                note("Driver log (QueryInfo 0x4c4c4f47)", .ok,
                     "\(log.text.utf8.count) bytes, offsets \(log.first)..<\(log.next), "
                     + "\(log.errorLines.count) error line(s), read in \(elapsed(readStart))")
            }
            let closeKR = observer.close()
            note("Close observer client", closeKR == KERN_SUCCESS ? .ok : .failed,
                 closeKR == KERN_SUCCESS ? "closed" : describeIOReturn(closeKR))
            if var last = out.popLast() { last.1 = true; out.append(last) }
            return out
        }

        IOObjectRetain(service)
        guard let kr = initKR else {
            add("InitDevice (9)", .failed,
                "did not return within \(Int(config.initTimeout)) s; it is still running in the driver. "
                + "The servicer keeps answering firmware requests, and the session closes when the call returns. "
                + "Do not kill the driver.", checkpoint: true)
            initCall.abandon { kr in
                finish(kr, late: true)
                for (result, checkpoint) in observerReads() { sink.emit(result, checkpoint) }
                IOObjectRelease(service)
                sink.settled(true)
            }
            return
        }
        finish(kr, late: false)

        sink.progress("Reading the driver log")
        let reads = Outstanding<[(ProbeResult, Bool)]>("bringup.observer") {
            defer { IOObjectRelease(service) }
            return observerReads()
        }
        if let results = reads.wait(config.readTimeout + 5) {
            for (result, checkpoint) in results { sink.emit(result, checkpoint) }
            add("Bring-up total", .info, elapsed(begin), checkpoint: true)
            sink.settled(false)
        } else {
            add("Observer reads", .failed,
                "the driver did not answer within \(Int(config.readTimeout + 5)) s; they are added when it does",
                checkpoint: true)
            reads.abandon { results in
                for (result, checkpoint) in results { sink.emit(result, checkpoint) }
                sink.settled(true)
            }
        }
    }
}

#endif
