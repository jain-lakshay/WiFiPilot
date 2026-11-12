import Foundation

/// Aggregated statistics for one network over the observation window.
///
/// Only the *current* network has live measurements. For other networks the engine
/// consumes historical metrics (recorded during earlier associations) or signal-only
/// data, and the score carries the basis so the UI never pretends otherwise.
public struct NetworkMetrics: Codable, Sendable, Equatable {
    public var averageThroughputMbps: Double?
    public var p60ThroughputMbps: Double?
    /// Standard deviation / mean. 0 = perfectly steady, 1 = wildly fluctuating.
    public var throughputCoefficientOfVariation: Double?
    public var averageLatencyMs: Double?
    public var latencyJitterMs: Double?
    public var packetLossPercent: Double?
    public var averageRSSI: Double?
    public var rssiStandardDeviation: Double?
    public var disconnectionCount: Int
    public var latencySpikeCount: Int
    public var dnsHealthy: Bool?
    public var internetReachable: Bool?
    public var sampleCount: Int
    public var observationDuration: TimeInterval

    // Measurement provenance (optional so older persisted history still decodes).
    public var latencySampleCount: Int?
    public var jitterMethod: String?
    public var throughputSampleCount: Int?
    public var throughputWindowSeconds: TimeInterval?
    /// Throughput always comes from small HTTP downloads, so it is always approximate.
    public var throughputIsApproximate: Bool?
    public var throughputLastMeasuredAt: Date?
    public var throughputProbeFailures: Int?
    /// Rolling probe-failure statistics (explicitly not ICMP packet loss).
    public var lossEstimate: LossEstimate?
    /// Path/DNS/TCP/HTTP classification for this connection.
    public var connectivity: ConnectivityAssessment?

    public init(
        averageThroughputMbps: Double? = nil,
        p60ThroughputMbps: Double? = nil,
        throughputCoefficientOfVariation: Double? = nil,
        averageLatencyMs: Double? = nil,
        latencyJitterMs: Double? = nil,
        packetLossPercent: Double? = nil,
        averageRSSI: Double? = nil,
        rssiStandardDeviation: Double? = nil,
        disconnectionCount: Int = 0,
        latencySpikeCount: Int = 0,
        dnsHealthy: Bool? = nil,
        internetReachable: Bool? = nil,
        sampleCount: Int = 0,
        observationDuration: TimeInterval = 0,
        latencySampleCount: Int? = nil,
        jitterMethod: String? = nil,
        throughputSampleCount: Int? = nil,
        throughputWindowSeconds: TimeInterval? = nil,
        throughputIsApproximate: Bool? = nil,
        throughputLastMeasuredAt: Date? = nil,
        throughputProbeFailures: Int? = nil,
        lossEstimate: LossEstimate? = nil,
        connectivity: ConnectivityAssessment? = nil
    ) {
        self.averageThroughputMbps = averageThroughputMbps
        self.p60ThroughputMbps = p60ThroughputMbps
        self.throughputCoefficientOfVariation = throughputCoefficientOfVariation
        self.averageLatencyMs = averageLatencyMs
        self.latencyJitterMs = latencyJitterMs
        self.packetLossPercent = packetLossPercent
        self.averageRSSI = averageRSSI
        self.rssiStandardDeviation = rssiStandardDeviation
        self.disconnectionCount = disconnectionCount
        self.latencySpikeCount = latencySpikeCount
        self.dnsHealthy = dnsHealthy
        self.internetReachable = internetReachable
        self.sampleCount = sampleCount
        self.observationDuration = observationDuration
        self.latencySampleCount = latencySampleCount
        self.jitterMethod = jitterMethod
        self.throughputSampleCount = throughputSampleCount
        self.throughputWindowSeconds = throughputWindowSeconds
        self.throughputIsApproximate = throughputIsApproximate
        self.throughputLastMeasuredAt = throughputLastMeasuredAt
        self.throughputProbeFailures = throughputProbeFailures
        self.lossEstimate = lossEstimate
        self.connectivity = connectivity
    }

    public static let empty = NetworkMetrics()

    /// Metrics contain enough data to be scored meaningfully.
    public var hasConnectionMeasurements: Bool {
        averageLatencyMs != nil || averageThroughputMbps != nil || packetLossPercent != nil
    }

    /// Whether an internet-usable connection has actually been verified.
    /// Nil means "not verified yet", which is different from "verified failing".
    public var isInternetVerified: Bool? {
        connectivity?.isVerifiedInternet ?? internetReachable
    }

    public var connectivityClass: ConnectivityClass? {
        connectivity?.classification
    }

    public var hasThroughputMeasurement: Bool {
        averageThroughputMbps != nil
    }
}

/// Result of a single connectivity probe round.
public struct HealthSample: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var packetLossPercent: Double?
    public var dnsResolutionMs: Double?
    public var dnsHealthy: Bool
    public var internetReachable: Bool
    /// Only present when an explicit throughput measurement was performed.
    public var throughputMbps: Double?
    /// True when a throughput probe ran but produced no usable value. This is not
    /// the same as zero throughput and must never be recorded as a zero sample.
    public var throughputMeasurementFailed: Bool
    /// Connectivity classification at the time of the sample, when available.
    public var connectivity: ConnectivityAssessment?
    public var network: NetworkIdentity?

    public init(
        timestamp: Date,
        latencyMs: Double? = nil,
        jitterMs: Double? = nil,
        packetLossPercent: Double? = nil,
        dnsResolutionMs: Double? = nil,
        dnsHealthy: Bool = true,
        internetReachable: Bool = true,
        throughputMbps: Double? = nil,
        throughputMeasurementFailed: Bool = false,
        connectivity: ConnectivityAssessment? = nil,
        network: NetworkIdentity? = nil
    ) {
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.packetLossPercent = packetLossPercent
        self.dnsResolutionMs = dnsResolutionMs
        self.dnsHealthy = dnsHealthy
        self.internetReachable = internetReachable
        self.throughputMbps = throughputMbps
        self.throughputMeasurementFailed = throughputMeasurementFailed
        self.connectivity = connectivity
        self.network = network
    }
}

extension Array where Element == Double {
    /// Arithmetic mean, or nil for an empty sequence.
    public var mean: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }

    /// Population standard deviation.
    public var standardDeviation: Double? {
        guard count > 1, let mean else { return nil }
        let variance = reduce(0) { $0 + pow($1 - mean, 2) } / Double(count)
        return sqrt(variance)
    }

    /// Linear-interpolated percentile, `p` in 0...1.
    public func percentile(_ p: Double) -> Double? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        if sorted.count == 1 { return sorted[0] }
        let position = Swift.min(1, Swift.max(0, p)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(sorted.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
