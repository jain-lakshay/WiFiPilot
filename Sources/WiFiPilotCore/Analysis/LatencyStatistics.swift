import Foundation

/// Temporal latency-variation statistics measured across *successive probes to the
/// same endpoint*.
///
/// Jitter is intentionally not derived from differences between different hosts in a
/// single round: that is a comparison of two paths, not variation over time. The
/// estimator keeps:
/// - a smoothed mean absolute successive difference (RFC 3550 style: `J += (|D| - J)/16`),
/// - a rolling window of raw latencies, from which an unsmoothed window jitter and a
///   standard deviation are available,
/// - the average latency, kept strictly separate from the jitter value.
public struct JitterEstimator: Sendable, Equatable {
    public let windowDuration: TimeInterval
    public let smoothing: Double
    public private(set) var samples: SampleWindow
    public private(set) var previousLatencyMs: Double?
    public private(set) var smoothedJitterMs: Double?
    public private(set) var differenceCount: Int
    public private(set) var endpoint: String?

    public init(windowDuration: TimeInterval = 60, smoothing: Double = 1.0 / 16.0, capacity: Int = 900) {
        self.windowDuration = max(15, windowDuration)
        self.smoothing = min(1, max(0.001, smoothing))
        self.samples = SampleWindow(duration: max(15, windowDuration), capacity: capacity)
        self.previousLatencyMs = nil
        self.smoothedJitterMs = nil
        self.differenceCount = 0
        self.endpoint = nil
    }

    /// Records one successful latency sample.
    @discardableResult
    public mutating func add(latencyMs: Double, at date: Date, endpoint: String? = nil) -> Double? {
        guard latencyMs.isFinite, latencyMs >= 0 else { return smoothedJitterMs }

        if let endpoint {
            if let currentEndpoint = self.endpoint, currentEndpoint != endpoint {
                // Endpoint changed: latency variation across two different endpoints is
                // not temporal jitter, so the whole window and the difference chain reset.
                samples.removeAll()
                previousLatencyMs = nil
                smoothedJitterMs = nil
                differenceCount = 0
            }
            self.endpoint = endpoint
        }

        if let previous = previousLatencyMs {
            let delta = abs(latencyMs - previous)
            // The first difference seeds the estimate; RFC 3550's `J += (|D| - J)/16`
            // then smooths from a meaningful starting point instead of from zero.
            if let current = smoothedJitterMs {
                smoothedJitterMs = current + (delta - current) * smoothing
            } else {
                smoothedJitterMs = delta
            }
            differenceCount += 1
        }

        previousLatencyMs = latencyMs
        samples.add(latencyMs, at: date)
        samples.prune(relativeTo: date)
        return smoothedJitterMs
    }

    public mutating func prune(relativeTo date: Date) {
        samples.prune(relativeTo: date)
    }

    public mutating func removeAll() {
        samples.removeAll()
        previousLatencyMs = nil
        smoothedJitterMs = nil
        differenceCount = 0
        endpoint = nil
    }

    /// Preferred jitter value: the smoothed estimate once it has seen a few
    /// differences, otherwise the unsmoothed window statistic.
    public var jitterMs: Double? {
        if differenceCount >= 3, let smoothedJitterMs {
            return smoothedJitterMs
        }
        return windowJitterMs
    }

    /// Mean absolute successive difference across the current window, no smoothing.
    public var windowJitterMs: Double? {
        let values = samples.values
        guard values.count > 1 else { return nil }
        var total = 0.0
        for index in 1..<values.count {
            total += abs(values[index] - values[index - 1])
        }
        return total / Double(values.count - 1)
    }

    public var averageLatencyMs: Double? { samples.mean }

    public var latencyStandardDeviationMs: Double? { samples.standardDeviation }

    public var sampleCount: Int { samples.count }

    public var methodDescription: String {
        if let endpoint {
            return "successive probes to \(endpoint)"
        }
        return "successive probes"
    }
}
