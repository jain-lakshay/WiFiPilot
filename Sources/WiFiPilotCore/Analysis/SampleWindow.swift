import Foundation

/// Time-bounded rolling window of numeric samples.
///
/// Used everywhere a metric needs "recent behaviour" rather than "everything since
/// launch": the windows are pruned by age as well as by count, so memory stays flat
/// and a stale 40-minute-old spike can never influence a decision.
public struct SampleWindow: Sendable, Equatable, Codable {
    public struct Sample: Sendable, Equatable, Codable {
        public var timestamp: Date
        public var value: Double

        public init(timestamp: Date, value: Double) {
            self.timestamp = timestamp
            self.value = value
        }
    }

    public let duration: TimeInterval
    public let capacity: Int
    public private(set) var samples: [Sample]

    public init(duration: TimeInterval = 60, capacity: Int = 900) {
        self.duration = max(1, duration)
        self.capacity = max(2, capacity)
        self.samples = []
    }

    public mutating func add(_ value: Double, at timestamp: Date) {
        guard value.isFinite else { return }
        samples.append(Sample(timestamp: timestamp, value: value))
        prune(relativeTo: timestamp)
    }

    /// Drops samples older than `duration` before `reference`, then enforces `capacity`.
    public mutating func prune(relativeTo reference: Date) {
        let cutoff = reference.addingTimeInterval(-duration)
        if let firstValid = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValid > 0 { samples.removeFirst(firstValid) }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public mutating func removeAll() { samples.removeAll(keepingCapacity: true) }

    public var values: [Double] { samples.map(\.value) }
    public var count: Int { samples.count }
    public var isEmpty: Bool { samples.isEmpty }
    public var latest: Double? { samples.last?.value }
    public var latestTimestamp: Date? { samples.last?.timestamp }
    public var mean: Double? { values.mean }
    public var standardDeviation: Double? { values.standardDeviation }

    public var coefficientOfVariation: Double? {
        guard let mean, let standardDeviation, mean > 0 else { return nil }
        return standardDeviation / mean
    }

    public func percentile(_ p: Double) -> Double? { values.percentile(p) }
}

/// Exponentially weighted moving average with a bias-corrected start.
///
/// The first sample becomes the value, so a fresh monitor does not report an
/// artificially low average while it "warms up".
public struct ExponentialMovingAverage: Sendable, Equatable, Codable {
    public let alpha: Double
    public private(set) var value: Double?
    public private(set) var count: Int

    public init(alpha: Double = 0.3) {
        self.alpha = min(1, max(0.01, alpha))
        self.value = nil
        self.count = 0
    }

    @discardableResult
    public mutating func add(_ sample: Double) -> Double {
        guard sample.isFinite else { return value ?? 0 }
        count += 1
        if let current = value {
            value = current + alpha * (sample - current)
        } else {
            value = sample
        }
        return value ?? sample
    }

    public mutating func reset() {
        value = nil
        count = 0
    }

    public var isWarmedUp: Bool { count > 0 }
}
