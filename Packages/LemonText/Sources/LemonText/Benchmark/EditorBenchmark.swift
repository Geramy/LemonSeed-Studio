import Darwin
import Foundation
import os
import QuartzCore
import UIKit

/// Measures the editor against the plan's gate: time to first screen, scrolling frame rate, typing latency
/// and memory, on a real document such as the SQLite amalgamation.
///
/// Every phase is wrapped in an `OSSignposter` interval (subsystem `LemonText`, category `Benchmark`) so the
/// same run can be inspected in Instruments.
@MainActor
public final class EditorBenchmark {
    public struct Distribution: Codable, Sendable, Hashable {
        public var count: Int
        public var mean: Double
        public var p50: Double
        public var p95: Double
        public var p99: Double
        public var max: Double

        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            count = sorted.count
            mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
            func percentile(_ fraction: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let index = min(Int((Double(sorted.count - 1) * fraction).rounded(.up)), sorted.count - 1)
                return sorted[index]
            }
            p50 = percentile(0.5)
            p95 = percentile(0.95)
            p99 = percentile(0.99)
            max = sorted.last ?? 0
        }
    }

    public struct ScrollResult: Codable, Sendable, Hashable {
        public var name: String
        public var durationSeconds: Double
        public var frames: Int
        public var averageFPS: Double
        /// Display refresh rate the run asked for and the one the display link reported.
        public var targetFPS: Double
        public var displayMaximumFPS: Int
        /// Main-thread time spent scrolling and laying out per frame, in milliseconds.
        public var frameWorkMilliseconds: Distribution
        /// Frames whose interval exceeded 1.5 display intervals.
        public var droppedFrames: Int
        public var pointsPerSecond: Double
    }

    public struct Result: Codable, Sendable, Hashable {
        public var fileName: String
        public var utf16Length: Int
        public var bytes: Int
        public var lineCount: Int
        public var language: String
        public var device: String
        public var system: String
        public var isSimulator: Bool
        public var readFileMilliseconds: Double
        public var prepareMilliseconds: Double
        public var installAndFirstLayoutMilliseconds: Double
        public var openToFirstScreenMilliseconds: Double
        public var openToHighlightedMilliseconds: Double
        public var scroll: [ScrollResult]
        /// Keystroke to laid-out glyph: insertText through the full input path, layout and a Core Animation commit.
        public var typingMilliseconds: Distribution
        public var deleteMilliseconds: Distribution
        public var jumpMilliseconds: Distribution
        public var memoryBeforeMB: Double
        public var memoryAfterOpenMB: Double
        public var memoryAfterHighlightMB: Double
        public var memoryPeakMB: Double
        public var date: Date
    }

    private let controller: LemonTextViewController
    private let signposter = OSSignposter(subsystem: "LemonText", category: "Benchmark")
    private var peakMemory: Double = 0

    public init(controller: LemonTextViewController) {
        self.controller = controller
    }

    /// Runs every phase. The controller must be on screen.
    public func run(fileURL: URL, progress: (@MainActor (String) -> Void)? = nil) async throws -> Result {
        let memoryBefore = Self.memoryFootprintMB()
        peakMemory = memoryBefore
        progress?("Reading \(fileURL.lastPathComponent)")
        let readStart = ContinuousClock.now
        let data = try Data(contentsOf: fileURL)
        let text = String(decoding: data, as: UTF8.self)
        let readDuration = ContinuousClock.now - readStart
        let language = LanguageDetector.language(forFileName: fileURL.lastPathComponent, contents: String(text.prefix(4096)))

        progress?("Opening")
        let openInterval = signposter.beginInterval("Open")
        let openStart = ContinuousClock.now
        let metrics: EditorLoadMetrics = await withCheckedContinuation { continuation in
            controller.load(text: text, language: language) { metrics in
                continuation.resume(returning: metrics)
            }
        }
        let firstScreen = ContinuousClock.now - openStart
        signposter.endInterval("Open", openInterval)
        let memoryAfterOpen = sampleMemory()

        progress?("Waiting for syntax highlighting")
        let highlightInterval = signposter.beginInterval("Highlight")
        while controller.isHighlighting {
            try? await Task.sleep(for: .milliseconds(5))
            _ = sampleMemory()
        }
        let highlighted = ContinuousClock.now - openStart
        signposter.endInterval("Highlight", highlightInterval)
        await nextFrames(10)
        let memoryAfterHighlight = sampleMemory()

        var scrolls: [ScrollResult] = []
        progress?("Scrolling (steady)")
        scrolls.append(await scroll(name: "steady 2,400 pt/s from the top", startFraction: 0, pointsPerSecond: 2_400, seconds: 4))
        progress?("Scrolling (fast flick)")
        scrolls.append(await scroll(name: "fast 9,000 pt/s through the middle", startFraction: 0.45, pointsPerSecond: 9_000, seconds: 4))

        progress?("Random jumps")
        let jumps = await measureJumps(count: 40)

        progress?("Typing")
        let typing = await measureTyping(iterations: 300)

        _ = sampleMemory()
        return Result(fileName: fileURL.lastPathComponent,
                      utf16Length: metrics.utf16Length,
                      bytes: data.count,
                      lineCount: metrics.lineCount,
                      language: language.displayName,
                      device: UIDevice.current.model + " " + Self.modelIdentifier(),
                      system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                      isSimulator: Self.isSimulator,
                      readFileMilliseconds: readDuration.milliseconds,
                      prepareMilliseconds: metrics.prepareDuration.milliseconds,
                      installAndFirstLayoutMilliseconds: metrics.firstScreenDuration.milliseconds,
                      openToFirstScreenMilliseconds: firstScreen.milliseconds,
                      openToHighlightedMilliseconds: highlighted.milliseconds,
                      scroll: scrolls,
                      typingMilliseconds: typing.insert,
                      deleteMilliseconds: typing.delete,
                      jumpMilliseconds: jumps,
                      memoryBeforeMB: memoryBefore,
                      memoryAfterOpenMB: memoryAfterOpen,
                      memoryAfterHighlightMB: memoryAfterHighlight,
                      memoryPeakMB: peakMemory,
                      date: Date())
    }

    // MARK: - Scrolling

    private func scroll(name: String, startFraction: CGFloat, pointsPerSecond: Double, seconds: Double) async -> ScrollResult {
        let textView = controller.codeTextView
        let maxOffset = max(textView.contentSize.height - textView.bounds.height, 0)
        textView.contentOffset = CGPoint(x: 0, y: maxOffset * startFraction)
        textView.layoutIfNeeded()
        await nextFrames(5)
        let interval = signposter.beginInterval("Scroll", "\(name)")
        let driver = ScrollDriver(textView: textView, pointsPerSecond: pointsPerSecond, duration: seconds)
        let samples = await driver.run()
        signposter.endInterval("Scroll", interval)
        _ = sampleMemory()
        let expected = 1.0 / Double(max(samples.maximumFPS, 1))
        let dropped = samples.intervals.filter { $0 > expected * 1.5 }.count
        let duration = samples.intervals.reduce(0, +)
        return ScrollResult(name: name,
                            durationSeconds: duration,
                            frames: samples.intervals.count,
                            averageFPS: duration > 0 ? Double(samples.intervals.count) / duration : 0,
                            targetFPS: 120,
                            displayMaximumFPS: samples.maximumFPS,
                            frameWorkMilliseconds: Distribution(samples.work.map { $0 * 1000 }),
                            droppedFrames: dropped,
                            pointsPerSecond: pointsPerSecond)
    }

    private func measureJumps(count: Int) async -> Distribution {
        let textView = controller.codeTextView
        let maxOffset = max(textView.contentSize.height - textView.bounds.height, 0)
        var generator = SplitMix64(seed: 0x1E70_5EED)
        var samples: [Double] = []
        for _ in 0 ..< count {
            let fraction = Double(generator.next() % 10_000) / 10_000
            let interval = signposter.beginInterval("Jump")
            let start = ContinuousClock.now
            textView.contentOffset = CGPoint(x: 0, y: maxOffset * fraction)
            textView.layoutIfNeeded()
            CATransaction.flush()
            samples.append((ContinuousClock.now - start).milliseconds)
            signposter.endInterval("Jump", interval)
            await nextFrames(2)
        }
        return Distribution(samples)
    }

    // MARK: - Typing

    private func measureTyping(iterations: Int) async -> (insert: Distribution, delete: Distribution) {
        let textView = controller.codeTextView
        // Type in the middle of the document, at the end of a line inside a function body.
        let middleLine = textView.lineCount / 2
        var targetLine = middleLine
        while targetLine < textView.lineCount - 1, let range = textView.range(ofLine: targetLine), range.length < 8 {
            targetLine += 1
        }
        controller.goToLine(targetLine + 1)
        guard let lineRange = textView.range(ofLine: targetLine) else {
            return (Distribution([]), Distribution([]))
        }
        textView.selectedRange = NSRange(location: lineRange.location + lineRange.length, length: 0)
        _ = textView.becomeFirstResponder()
        await nextFrames(5)
        var inserts: [Double] = []
        var deletes: [Double] = []
        let characters = Array("int lemon = 42; /* keystroke */")
        for index in 0 ..< iterations {
            let character = String(characters[index % characters.count])
            let interval = signposter.beginInterval("Keystroke")
            let start = ContinuousClock.now
            textView.insertText(character)
            textView.layoutIfNeeded()
            CATransaction.flush()
            inserts.append((ContinuousClock.now - start).milliseconds)
            signposter.endInterval("Keystroke", interval)
            await nextFrames(1)
        }
        for _ in 0 ..< iterations {
            let interval = signposter.beginInterval("Delete")
            let start = ContinuousClock.now
            textView.deleteBackward()
            textView.layoutIfNeeded()
            CATransaction.flush()
            deletes.append((ContinuousClock.now - start).milliseconds)
            signposter.endInterval("Delete", interval)
            await nextFrames(1)
        }
        return (Distribution(inserts), Distribution(deletes))
    }

    // MARK: - Helpers

    private func sampleMemory() -> Double {
        let current = Self.memoryFootprintMB()
        peakMemory = Swift.max(peakMemory, current)
        return current
    }

    private func nextFrames(_ count: Int) async {
        for _ in 0 ..< count {
            await FrameWaiter().wait()
        }
    }

    /// The process's physical footprint, the number jetsam uses.
    public static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Scrolls a view at a constant speed on every display frame and records frame intervals and work.
@MainActor
private final class ScrollDriver: NSObject {
    struct Samples {
        var intervals: [Double] = []
        var work: [Double] = []
        var maximumFPS = 60
    }

    private let textView: UIScrollView
    private let pointsPerSecond: Double
    private let duration: Double
    private var link: CADisplayLink?
    private var samples = Samples()
    private var startTime: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?
    private var continuation: CheckedContinuation<Samples, Never>?
    private var direction: CGFloat = 1

    init(textView: UIScrollView, pointsPerSecond: Double, duration: Double) {
        self.textView = textView
        self.pointsPerSecond = pointsPerSecond
        self.duration = duration
    }

    func run() async -> Samples {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        samples.maximumFPS = textView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        if startTime == nil {
            startTime = link.timestamp
        }
        if let lastTimestamp {
            samples.intervals.append(link.timestamp - lastTimestamp)
        }
        let delta = lastTimestamp.map { link.timestamp - $0 } ?? link.duration
        lastTimestamp = link.timestamp
        let workStart = CACurrentMediaTime()
        let maxOffset = max(textView.contentSize.height - textView.bounds.height, 0)
        var y = textView.contentOffset.y + CGFloat(pointsPerSecond * delta) * direction
        if y >= maxOffset {
            y = maxOffset
            direction = -1
        } else if y <= 0 {
            y = 0
            direction = 1
        }
        textView.contentOffset = CGPoint(x: 0, y: y)
        textView.layoutIfNeeded()
        samples.work.append(CACurrentMediaTime() - workStart)
        if let startTime, link.timestamp - startTime >= duration {
            link.invalidate()
            self.link = nil
            continuation?.resume(returning: samples)
            continuation = nil
        }
    }
}

/// Resumes on the next display frame.
@MainActor
private final class FrameWaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(fire))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func fire() {
        link?.invalidate()
        link = nil
        continuation?.resume()
        continuation = nil
    }
}

/// A small deterministic random number generator so benchmark runs are repeatable.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension Duration {
    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
