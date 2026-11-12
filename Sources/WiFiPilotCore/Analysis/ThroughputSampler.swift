import Foundation

/// Rolling store of *approximate* throughput measurements.
///
/// Throughput is measured with small, periodic HTTP downloads, so it needs its own
/// window that is much longer than the latency/signal observation window: variability
/// is only meaningful with several samples spread over minutes. The default window is
/// five minutes, which fits ~3 probes at the default 90 s cadence while a 60 s window
/// would barely hold one.
///
/// Values are always approximate. Failed attempts are recorded separately and never
/// enter the sample list, so "could not measure" never becomes "zero throughput".
public struct ThroughputSampler: Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public var timestamp: Date
        public var mbps: Double

        public init(timestamp: Date, mbps: Double) {
            self.timestamp = timestamp
            self.mbps = mbps
        }
    }

    public let windowDuration: TimeInterval
    public let capacity: Int
    public private(set) var samples: [Sample]
    public private(set) var lastAttemptAt: Date?
    public private(set) var lastFailureAt: Date?
    public private(set) var failureCount: Int
    public private(set) var attemptCount: Int

    public init(windowDuration: TimeInterval = 300, capacity: Int = 120) {
        self.windowDuration = max(60, windowDuration)
        self.capacity = max(6, capacity)
        self.samples = []
        self.lastAttemptAt = nil
        self.lastFailureAt = nil
        self.failureCount = 0
        self.attemptCount = 0
    }

    /// Records a measured throughput. `0` is a valid measurement (the link carries
    /// almost nothing), unlike a failed measurement which is recorded separately.
    public mutating func record(mbps: Double, at date: Date) {
        guard mbps.isFinite else { return }
        let value = max(0, mbps)
        samples.append(Sample(timestamp: date, mbps: value))
        lastAttemptAt = date
        attemptCount += 1
        prune(relativeTo: date)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Records an attempt that produced no usable value (timeout, error, skipped
    /// transfer). This does **not** add a zero sample.
    public mutating func recordFailure(reason: String? = nil, at date: Date) {
        lastAttemptAt = date
        lastFailureAt = date
        attemptCount += 1
        failureCount += 1
    }

    public mutating func prune(relativeTo date: Date) {
        let cutoff = date.addingTimeInterval(-windowDuration)
        if let firstValid = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValid > 0 { samples.removeFirst(firstValid) }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
    }

    public mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
        lastAttemptAt = nil
        lastFailureAt = nil
        failureCount = 0
        attemptCount = 0
    }

    public var values: [Double] { samples.map(\.mbps) }
    public var sampleCount: Int { samples.count }
    public var latestMbps: Double? { samples.last?.mbps }
    public var latestSampleAt: Date? { samples.last?.timestamp }
    public var averageMbps: Double? { values.mean }
    public var p60Mbps: Double? { values.percentile(0.6) }
    public var p10Mbps: Double? { values.percentile(0.1) }

    public var coefficientOfVariation: Double? {
        guard let averageMbps, averageMbps > 0, let sd = values.standardDeviation else { return nil }
        return sd / averageMbps
    }

    /// Two samples cannot describe variation; three is the minimum useful window.
    public var hasEnoughSamplesForVariability: Bool { samples.count >= 3 }

    public var windowSeconds: TimeInterval { windowDuration }

    public func lastSampleAge(relativeTo now: Date) -> TimeInterval? {
        guard let latestSampleAt else { return nil }
        return max(0, now.timeIntervalSince(latestSampleAt))
    }
}

// MARK: - When to probe

public enum ThroughputProbeDecision: String, Codable, Sendable, CaseIterable {
    case probe
    case disabled
    case notConnected
    case userTrafficActive
    case backoffAfterFailure
    case tooSoon

    public var displayName: String {
        switch self {
        case .probe: "measuring"
        case .disabled: "disabled"
        case .notConnected: "not connected"
        case .userTrafficActive: "deferred (active transfer)"
        case .backoffAfterFailure: "backing off after a failed measurement"
        case .tooSoon: "waiting for the next interval"
        }
    }
}

public struct ThroughputProbeAssessment: Codable, Sendable, Equatable {
    public var decision: ThroughputProbeDecision
    public var detail: String

    public var shouldProbe: Bool { decision == .probe }

    public init(decision: ThroughputProbeDecision, detail: String) {
        self.decision = decision
        self.detail = detail
    }
}

/// Decides when a controlled throughput measurement may run.
///
/// Bandwidth discipline is part of the design, not an afterthought:
/// - fixed small payload (250 KB default) rather than a speed-test download,
/// - at most one probe per `minimumInterval` (90 s default → ~10 MB/hour ceiling),
/// - never while the user's own traffic exceeds `maximumUserTrafficMbps`,
/// - exponential-ish backoff after a failure instead of hammering an unhappy link.
///
/// The resulting figures are labelled approximate everywhere: a 250 KB transfer
/// includes TLS setup and cannot estimate a gigabit link accurately. The purpose is
/// variability over minutes, not a bandwidth benchmark.
public struct ThroughputProbePolicy: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// Minimum spacing between probes.
    public var minimumInterval: TimeInterval
    /// After a failed measurement, wait this long before trying again.
    public var failureBackoff: TimeInterval
    /// Size of the controlled download.
    public var payloadBytes: Int
    /// Do not probe while the user is transferring more than this.
    public var maximumUserTrafficMbps: Double
    /// Window used to evaluate throughput samples.
    public var windowDuration: TimeInterval

    public init(
        isEnabled: Bool = false,
        minimumInterval: TimeInterval = 90,
        failureBackoff: TimeInterval = 300,
        payloadBytes: Int = 250_000,
        maximumUserTrafficMbps: Double = 1.0,
        windowDuration: TimeInterval = 300
    ) {
        self.isEnabled = isEnabled
        self.minimumInterval = minimumInterval
        self.failureBackoff = failureBackoff
        self.payloadBytes = payloadBytes
        self.maximumUserTrafficMbps = maximumUserTrafficMbps
        self.windowDuration = windowDuration
    }

    public static let standard = ThroughputProbePolicy()

    /// Upper bound on data usage if probes ran continuously at the minimum interval.
    public var estimatedMegabytesPerHour: Double {
        guard minimumInterval > 0 else { return 0 }
        return Double(payloadBytes) * (3600.0 / minimumInterval) / 1_000_000.0
    }

    public func sanitized() -> ThroughputProbePolicy {
        var copy = self
        copy.minimumInterval = min(900, max(30, minimumInterval.isFinite ? minimumInterval : 90))
        copy.failureBackoff = min(3600, max(60, failureBackoff.isFinite ? failureBackoff : 300))
        copy.payloadBytes = min(2_000_000, max(64_000, payloadBytes))
        copy.maximumUserTrafficMbps = min(100, max(0.1, maximumUserTrafficMbps.isFinite ? maximumUserTrafficMbps : 1))
        copy.windowDuration = min(1800, max(120, windowDuration.isFinite ? windowDuration : 300))
        return copy
    }

    public func assess(
        now: Date,
        isConnected: Bool,
        traffic: TrafficAssessment,
        lastAttemptAt: Date?,
        lastFailureAt: Date?
    ) -> ThroughputProbeAssessment {
        let policy = sanitized()

        guard policy.isEnabled else {
            return ThroughputProbeAssessment(
                decision: .disabled,
                detail: "Controlled throughput measurement is disabled (it is optional and uses data)."
            )
        }
        guard isConnected else {
            return ThroughputProbeAssessment(
                decision: .notConnected,
                detail: "No active Wi-Fi association to measure."
            )
        }

        if traffic.isActive || traffic.totalMbps >= policy.maximumUserTrafficMbps {
            return ThroughputProbeAssessment(
                decision: .userTrafficActive,
                detail: String(
                    format: "Deferred: user traffic is at %.2f Mbps (probe limit %.2f Mbps).",
                    traffic.totalMbps,
                    policy.maximumUserTrafficMbps
                )
            )
        }

        if let lastFailureAt, now.timeIntervalSince(lastFailureAt) < policy.failureBackoff {
            let remaining = Int((policy.failureBackoff - now.timeIntervalSince(lastFailureAt)).rounded(.up))
            return ThroughputProbeAssessment(
                decision: .backoffAfterFailure,
                detail: "Last measurement failed; retrying in \(remaining) s."
            )
        }

        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < policy.minimumInterval {
            let remaining = Int((policy.minimumInterval - now.timeIntervalSince(lastAttemptAt)).rounded(.up))
            return ThroughputProbeAssessment(
                decision: .tooSoon,
                detail: "Next approximate throughput sample in \(remaining) s."
            )
        }

        return ThroughputProbeAssessment(
            decision: .probe,
            detail: String(
                format: "Measuring %d KB (≤ %.1f MB/hour at this cadence).",
                policy.payloadBytes / 1000,
                policy.estimatedMegabytesPerHour
            )
        )
    }
}
