import Foundation
import Synchronization
@testable import StudioTelemetry

/// A manually advanced monotonic clock.
final class TestClock: Sendable {
    private let ns = Mutex<UInt64>(1_000_000_000)

    var now: UInt64 { ns.withLock { $0 } }
    func advance(seconds: Double) { ns.withLock { $0 += UInt64(seconds * 1e9) } }
    func advance(microseconds: UInt32) { ns.withLock { $0 += UInt64(microseconds) * 1000 } }
    var closure: NanosecondClock { { [self] in self.now } }
}

enum Fixtures {
    static var names: [String] { ObserverFixture.bundledNames }

    static func load(_ name: String) throws -> ObserverFixture { try ObserverFixture.bundled(name) }

    /// A transport over a fixture whose clock only moves when told to; the
    /// GRBM spacing sleep advances it, as real time would.
    static func transport(_ fixture: ObserverFixture, scenario: FixtureScenario = .live,
                          clock: TestClock) -> LinuxTransport {
        let directory = FixtureObserverDirectory(fixture: fixture, scenario: scenario, clock: clock.closure)
        return LinuxTransport(directory: directory, clock: clock.closure,
                              sleepMicroseconds: { clock.advance(microseconds: $0) })
    }

    /// Text files of a frame (fixture files are stored untrimmed).
    static func text(_ frame: ObserverFixture.Frame, _ path: String) -> String? {
        guard case .text(let t)? = frame.files[path] else { return nil }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hwmonDir(_ fixture: ObserverFixture) -> String? {
        fixture.listings["hwmon"]?.split(separator: "\n")
            .first { $0.hasPrefix("d hwmon") }.map { "hwmon/" + $0.dropFirst(2) }
    }

    /// The recordings the tests replay. Until they are captured
    /// (Tools/capture_fixtures.sh) the suites that need them are disabled and
    /// the inventory test reports the gap as a known issue.
    static let required = ["r9700-idle"]

    /// A fixture with no recorded payloads, for the paths that answer before
    /// any file is read (no device, driver not running, older dext).
    static let empty = ObserverFixture(name: "empty", device: .init(service: "MacLinuxGPU", registryID: 0x1000))
    static var haveRecordings: Bool { required.allSatisfy(names.contains) }
}
