import Foundation
import Observation

/// A rolling window of GPU samples with derived statistics.
@MainActor
@Observable
final class TelemetryHistory {
    struct Sample: Hashable, Sendable {
        let date: Date
        let load: Double
        let junctionTemperature: Measurement<UnitTemperature>
    }

    private(set) var samples: [Sample] = []
    let window: Duration

    init(window: Duration = .seconds(60)) {
        self.window = window
    }

    var averageLoad: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.load).reduce(0, +) / Double(samples.count)
    }

    var peakTemperature: Measurement<UnitTemperature>? {
        samples.map(\.junctionTemperature).max()
    }

    func append(_ sample: Sample) {
        samples.append(sample)
        let cutoff = sample.date.addingTimeInterval(-TimeInterval(window.components.seconds))
        samples.removeAll { $0.date < cutoff }
    }

    func stream(every interval: Duration) -> AsyncStream<Sample> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    let sample = Sample(date: .now, load: .random(in: 0 ... 100),
                                        junctionTemperature: .init(value: 61, unit: .celsius))
                    continuation.yield(sample)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
