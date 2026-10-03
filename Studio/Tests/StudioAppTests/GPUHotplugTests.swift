import XCTest
import StudioAgent
@testable import LemonSeedStudio

/// A fake engine whose device can be pulled out from under it: while a
/// generation streams, `unplug()` makes it fail the way LSE does when the
/// GPU is removed (the request ends with a device-lost error, lse_status
/// reports power lost with cause 13). Every call that reaches it after the
/// loss is counted, so a test can prove nothing touched the dead engine.
final class FakeEngine: EngineHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var unplugged = false
    private var cancelled = false
    private(set) var closed = false
    private(set) var callsAfterLoss = 0
    private(set) var chunksSent = 0

    func unplug() { lock.withLock { unplugged = true } }
    private var isUnplugged: Bool { lock.withLock { unplugged } }
    private func noteCall() { lock.withLock { if unplugged { callsAfterLoss += 1 } } }

    static let lostBody = Data(#"{"error":{"message":"hrx: HSA_STATUS_ERROR_FATAL: device lost (the GPU was removed)","type":"server_error"}}"#.utf8)

    func request(method: String, path: String, body: Data?,
                 handler: @escaping @Sendable (EngineEvent) -> Void) throws -> UInt64 {
        noteCall()
        if isUnplugged { throw URLError(.notConnectedToInternet) }
        lock.withLock { cancelled = false }
        let thread = Thread { [self] in
            for _ in 0..<2000 {
                if lock.withLock({ cancelled }) {
                    handler(.error(status: 499, body: Data(#"{"error":{"message":"cancelled"}}"#.utf8)))
                    return
                }
                if isUnplugged {
                    handler(.error(status: 500, body: Self.lostBody))
                    return
                }
                let chunk = Data(#"{"choices":[{"delta":{"content":"tok "},"index":0}]}"#.utf8)
                handler(.chunk(chunk))
                lock.withLock { chunksSent += 1 }
                Thread.sleep(forTimeInterval: 0.01)
            }
            handler(.done)
        }
        thread.start()
        return 1
    }

    func cancel(_ id: UInt64) {
        noteCall()
        lock.withLock { cancelled = true }
    }

    /// Closing after the loss is allowed and expected (lse_close tolerates
    /// the removed device).
    func close() { lock.withLock { closed = true } }

    func status() -> [String: Any] {
        noteCall()
        let lost = isUnplugged
        return ["power": ["state": lost ? "lost" : "active", "cause": lost ? 13 : 0],
                "requests": ["active": 0]]
    }

    func closeSession(_ id: String) -> Bool { noteCall(); return true }
    func prepareLowPower(drainMilliseconds: UInt32) -> EnginePowerResult { noteCall(); return .init(state: .suspended) }
    func resumeFromLowPower() -> EnginePowerResult { noteCall(); return .init(state: .active) }
}

final class FakeEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FakeEngine] = []
    var opened: [FakeEngine] { lock.withLock { all } }

    var opener: EngineOpener {
        EngineOpener(isAvailable: true, version: "fake", supportsPower: true, supportsSessions: true,
                     open: { [self] _ in
                         try await Task.sleep(for: .milliseconds(50))
                         let e = FakeEngine()
                         lock.withLock { all.append(e) }
                         return e
                     },
                     loadStatus: { [:] })
    }
}

@MainActor
final class GPUHotplugTests: XCTestCase {
    final class Flag: @unchecked Sendable { var value = true }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    func testUnplugMidGenerationThenReplug() async throws {
        let engines = FakeEngines()
        let engine = EngineService(opener: engines.opener)
        let power = EnginePower()
        let present = Flag()
        var telemetry: [Bool] = []
        let launch = EngineLaunch(modelID: "fake-q4", modelName: "Fake Q4", modelDirectory: URL(fileURLWithPath: "/tmp/fake"))
        power.configure(engine: engine, servicePresent: { present.value }, currentLaunch: { launch },
                        telemetryActive: { telemetry.append($0) })

        engine.start(launch)
        await waitFor("the engine to open") { engine.phase == .ready }
        let first = try XCTUnwrap(engines.opened.first)

        // A generation streams through the agent's transport.
        let transport = engine.chatTransport()
        let generation = Task.detached { () -> (chunks: Int, failed: Bool) in
            var chunks = 0
            do {
                for try await _ in transport.stream(method: "POST", path: "chat/completions", body: Data("{}".utf8)) {
                    chunks += 1
                }
                return (chunks, false)
            } catch {
                return (chunks, true)
            }
        }
        await waitFor("the generation to stream") { first.chunksSent >= 5 }

        // The GPU is pulled out: the device is lost and the driver's
        // service terminates.
        first.unplug()
        present.value = false
        power.driverServiceChanged(present: false)

        let outcome = await generation.value
        XCTAssertTrue(outcome.failed, "the generation in flight ends with the loss")
        XCTAssertGreaterThanOrEqual(outcome.chunks, 5)

        await waitFor("the engine to close and wait") { engine.phase == .waiting(EnginePower.disconnectedMessage) }
        XCTAssertTrue(power.disconnected)
        XCTAssertEqual(power.state, .lost)
        XCTAssertTrue(first.closed, "the engine is closed cleanly")
        XCTAssertEqual(telemetry, [false], "telemetry pauses")
        XCTAssertEqual(engine.statusLine, EnginePower.disconnectedMessage)

        // Nothing reaches the dead engine: requests answer device_lost at
        // once, status and the power poll use what was last known, starting
        // waits for the GPU.
        let refused = try engine.box.perform(method: "POST", path: "chat/completions", body: Data("{}".utf8)) { _ in true }
        XCTAssertEqual(refused.status, 503)
        XCTAssertEqual(EngineBox.refusalCode(refused), "device_lost")
        _ = engine.status()
        power.refresh()
        engine.closeSession("chat-1")
        engine.start(launch)
        XCTAssertEqual(engine.phase, .waiting(EnginePower.disconnectedMessage))
        XCTAssertEqual(engines.opened.count, 1, "no engine opens while the GPU is away")
        XCTAssertEqual(first.callsAfterLoss, 0, "no call reached the engine after the loss")

        // Plugged back in: the service returns and the engine loads again.
        present.value = true
        power.driverServiceChanged(present: true)
        await waitFor("the engine to load again") { engine.phase == .ready }
        XCTAssertFalse(power.disconnected)
        XCTAssertEqual(engines.opened.count, 2)
        XCTAssertEqual(telemetry, [false, true], "telemetry resumes")
        XCTAssertEqual(engine.launch, launch, "the same configuration loads")

        // The failed request's late loss report (about the first engine)
        // does not reload the new one.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(engines.opened.count, 2, "a stale loss report does not reload the new engine")
        XCTAssertFalse(power.recovering)

        // And it serves again.
        let second = try XCTUnwrap(engines.opened.last)
        let answer = Task.detached { () -> Int in
            var n = 0
            for try await _ in transport.stream(method: "POST", path: "chat/completions", body: Data("{}".utf8)) {
                n += 1
                if n == 3 { break }
            }
            return n
        }
        let served = try await answer.value
        XCTAssertEqual(served, 3)
        XCTAssertFalse(second.closed)
        XCTAssertEqual(first.callsAfterLoss, 0)
    }

    /// Lost to a sleep (power lost, cause other than 13, service still
    /// there): the engine reloads at once instead of waiting.
    func testLossWithTheServicePresentReloads() async throws {
        let engines = FakeEngines()
        let engine = EngineService(opener: engines.opener)
        let power = EnginePower()
        let launch = EngineLaunch(modelID: "fake-q4", modelName: "Fake Q4", modelDirectory: URL(fileURLWithPath: "/tmp/fake"))
        power.configure(engine: engine, servicePresent: { true }, currentLaunch: { launch }, telemetryActive: { _ in })
        engine.start(launch)
        await waitFor("the engine to open") { engine.phase == .ready }
        power.recoverFromLoss(reason: "slept", cause: 2)
        await waitFor("the reload") { engines.opened.count == 2 && engine.phase == .ready }
        XCTAssertFalse(power.disconnected)
        XCTAssertTrue(engines.opened[0].closed)
    }

    /// A request fails with the device lost before the driver's terminate
    /// notification arrives: the app waits briefly, sees the service go, and
    /// treats it as an unplug rather than reloading into a missing GPU.
    func testUnexplainedLossThenServiceGoesIsADisconnect() async throws {
        let engines = FakeEngines()
        let engine = EngineService(opener: engines.opener)
        let power = EnginePower()
        let present = Flag()
        let launch = EngineLaunch(modelID: "fake-q4", modelName: "Fake Q4", modelDirectory: URL(fileURLWithPath: "/tmp/fake"))
        power.configure(engine: engine, servicePresent: { present.value }, currentLaunch: { launch }, telemetryActive: { _ in })
        engine.start(launch)
        await waitFor("the engine to open") { engine.phase == .ready }
        let first = try XCTUnwrap(engines.opened.first)
        let transport = engine.chatTransport()
        let generation = Task.detached { () -> Bool in
            do { for try await _ in transport.stream(method: "POST", path: "chat/completions", body: Data("{}".utf8)) {} ; return false }
            catch { return true }
        }
        await waitFor("streaming") { first.chunksSent >= 3 }
        first.unplug()
        let failed = await generation.value
        XCTAssertTrue(failed)
        // The terminate notification comes a little later.
        try await Task.sleep(for: .milliseconds(300))
        present.value = false
        power.driverServiceChanged(present: false)
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(power.disconnected)
        XCTAssertEqual(engines.opened.count, 1, "no reload into a missing GPU")
        XCTAssertEqual(engine.phase, .waiting(EnginePower.disconnectedMessage))
        XCTAssertEqual(first.callsAfterLoss, 0)
    }

    /// Power lost with cause 13 while the driver's service still exists:
    /// disconnected, and it stays so until the service goes and comes back.
    func testCause13WaitsForTheServiceToComeBack() async throws {
        let engines = FakeEngines()
        let engine = EngineService(opener: engines.opener)
        let power = EnginePower()
        let present = Flag()
        let launch = EngineLaunch(modelID: "fake-q4", modelName: "Fake Q4", modelDirectory: URL(fileURLWithPath: "/tmp/fake"))
        power.configure(engine: engine, servicePresent: { present.value }, currentLaunch: { launch }, telemetryActive: { _ in })
        engine.start(launch)
        await waitFor("the engine to open") { engine.phase == .ready }
        power.recoverFromLoss(reason: "lse_status: power lost, cause 13", cause: EnginePower.causeDeviceRemoved)
        await waitFor("the close") { engine.phase == .waiting(EnginePower.disconnectedMessage) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(power.disconnected)
        XCTAssertEqual(engines.opened.count, 1)
        present.value = false
        power.driverServiceChanged(present: false)
        present.value = true
        power.driverServiceChanged(present: true)
        await waitFor("the reload") { engine.phase == .ready }
        XCTAssertEqual(engines.opened.count, 2)
        XCTAssertFalse(power.disconnected)
    }
}
