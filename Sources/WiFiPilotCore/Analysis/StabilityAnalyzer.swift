import Foundation

/// Accumulates live measurements for the currently connected network and turns them
/// into `NetworkMetrics`.
///
/// Two windows are deliberately different lengths:
/// - `windowDuration` (60 s default) covers signal, latency and probe loss — things
///   that change quickly and drive switching decisions.
/// - `throughputWindowDuration` (5 minutes default) covers throughput samples, because
///   small, spaced probes cannot describe variability inside a single minute.
///
/// Jitter is derived from successive latencies to the same endpoint and kept separate
/// from average latency. Probe failures are classified, and counted as a rolling
/// "probe loss" rate rather than being described as ICMP packet loss.
public struct StabilityAnalyzer: Sendable, Equatable {
    public let windowDuration: TimeInterval
    public let throughputWindowDuration: TimeInterval

    public private(set) var network: NetworkIdentity?
    public private(set) var signal: SampleWindow
    public private(set) var latency: SampleWindow
    public private(set) var jitter: JitterEstimator
    public private(set) var loss: PacketLossEstimator
    public private(set) var throughput: ThroughputSampler
    public private(set) var signalSmooth: ExponentialMovingAverage
    public private(set) var throughputSmooth: ExponentialMovingAverage
    public private(set) var latencyBaseline: ExponentialMovingAverage
    public private(set) var disconnections: Int
    public private(set) var latencySpikes: Int
    public private(set) var dnsHealthy: Bool?
    public private(set) var internetReachable: Bool?
    public private(set) var connectivity: ConnectivityAssessment?
    public private(set) var startedAt: Date?
    public private(set) var lastUpdate: Date?
    public private(set) var probeCount: Int
    public private(set) var failedProbes: Int
    /// Fallback loss source for legacy `HealthSample` inputs that carry a percentage.
    private var legacyLoss: SampleWindow

    public init(
        windowDuration: TimeInterval = 60,
        capacity: Int = 900,
        alpha: Double = 0.3,
        throughputWindowDuration: TimeInterval = 300
    ) {
        let window = max(15, windowDuration)
        self.windowDuration = window
        self.throughputWindowDuration = max(120, throughputWindowDuration)
        self.signal = SampleWindow(duration: window, capacity: capacity)
        self.latency = SampleWindow(duration: window, capacity: capacity)
        self.jitter = JitterEstimator(windowDuration: window, capacity: capacity)
        self.loss = PacketLossEstimator(windowDuration: window, capacity: 600)
        self.throughput = ThroughputSampler(windowDuration: max(120, throughputWindowDuration))
        self.signalSmooth = ExponentialMovingAverage(alpha: alpha)
        self.throughputSmooth = ExponentialMovingAverage(alpha: alpha)
        self.latencyBaseline = ExponentialMovingAverage(alpha: alpha)
        self.disconnections = 0
        self.latencySpikes = 0
        self.dnsHealthy = nil
        self.internetReachable = nil
        self.connectivity = nil
        self.startedAt = nil
        self.lastUpdate = nil
        self.probeCount = 0
        self.failedProbes = 0
        self.legacyLoss = SampleWindow(duration: window, capacity: capacity)
    }

    /// Starts a fresh observation period, typically on a new association.
    public mutating func start(network: NetworkIdentity?, at date: Date) {
        self.network = network
        self.signal.removeAll()
        self.latency.removeAll()
        self.jitter.removeAll()
        self.loss.removeAll()
        self.throughput.removeAll()
        self.signalSmooth.reset()
        self.throughputSmooth.reset()
        self.latencyBaseline.reset()
        self.legacyLoss.removeAll()
        self.disconnections = 0
        self.latencySpikes = 0
        self.dnsHealthy = nil
        self.internetReachable = nil
        self.connectivity = nil
        self.startedAt = date
        self.lastUpdate = date
        self.probeCount = 0
        self.failedProbes = 0
    }

    // MARK: - Signal

    public mutating func addSignal(rssi: Int, at date: Date) {
        if startedAt == nil { startedAt = date }
        lastUpdate = date
        signal.add(Double(rssi), at: date)
        signalSmooth.add(Double(rssi))
        prune(relativeTo: date)
    }

    // MARK: - Probe rounds (preferred path)

    /// Ingests one structured probe round: attempts, classifications and outcomes.
    public mutating func add(round: ProbeRoundSummary) {
        if startedAt == nil { startedAt = round.timestamp }
        lastUpdate = round.timestamp
        probeCount += round.attempts
        failedProbes += max(0, round.attempts - round.successes)

        for value in round.latenciesMs where value.isFinite {
            if let baseline = latencyBaseline.value,
               value > max(baseline * 2.0, baseline + 60) {
                latencySpikes += 1
            }
            latencyBaseline.add(value)
            latency.add(value, at: round.timestamp)
            jitter.add(latencyMs: value, at: round.timestamp, endpoint: round.endpoint)
        }

        loss.record(contentsOf: round.probeAttempts)

        switch round.throughput {
        case .measured(let mbps):
            throughput.record(mbps: mbps, at: round.timestamp)
            throughputSmooth.add(mbps)
        case .unavailable(let reason):
            throughput.recordFailure(reason: reason, at: round.timestamp)
        case .notAttempted:
            break
        }

        dnsHealthy = round.dnsHealthy
        connectivity = round.connectivity
        internetReachable = round.connectivity.isVerifiedInternet
        prune(relativeTo: round.timestamp)
    }

    // MARK: - Legacy sample path

    /// Ingests a single `HealthSample`.
    ///
    /// Jitter is computed from successive latencies here rather than trusting a value
    /// carried on the sample, and a missing throughput value is only treated as a
    /// failure when the sample says a measurement was attempted.
    public mutating func add(health sample: HealthSample) {
        if startedAt == nil { startedAt = sample.timestamp }
        lastUpdate = sample.timestamp
        probeCount += 1
        if !sample.internetReachable { failedProbes += 1 }

        let endpoint = sample.network?.displayName
        if let value = sample.latencyMs, value.isFinite {
            if let baseline = latencyBaseline.value,
               value > max(baseline * 2.0, baseline + 60) {
                latencySpikes += 1
            }
            latencyBaseline.add(value)
            latency.add(value, at: sample.timestamp)
            jitter.add(latencyMs: value, at: sample.timestamp, endpoint: endpoint)
            loss.record(
                ProbeAttempt(timestamp: sample.timestamp, endpoint: endpoint ?? "current", latencyMs: value)
            )
        } else if sample.internetReachable == false {
            loss.record(
                ProbeAttempt(timestamp: sample.timestamp, endpoint: endpoint ?? "current", failure: .timeout)
            )
        }

        if let lossPercent = sample.packetLossPercent {
            legacyLoss.add(lossPercent, at: sample.timestamp)
        }

        if let value = sample.throughputMbps {
            throughput.record(mbps: value, at: sample.timestamp)
            throughputSmooth.add(value)
        } else if sample.throughputMeasurementFailed {
            throughput.recordFailure(at: sample.timestamp)
        }

        dnsHealthy = sample.dnsHealthy
        connectivity = sample.connectivity
        internetReachable = sample.connectivity?.isVerifiedInternet ?? sample.internetReachable
        prune(relativeTo: sample.timestamp)
    }

    public mutating func addThroughput(_ mbps: Double, at date: Date) {
        lastUpdate = date
        throughput.record(mbps: mbps, at: date)
        throughputSmooth.add(mbps)
        prune(relativeTo: date)
    }

    public mutating func recordThroughputFailure(at date: Date) {
        lastUpdate = date
        throughput.recordFailure(at: date)
    }

    public mutating func recordDisconnection(at date: Date) {
        disconnections += 1
        lastUpdate = date
        internetReachable = false
    }

    private mutating func prune(relativeTo date: Date) {
        signal.prune(relativeTo: date)
        latency.prune(relativeTo: date)
        jitter.prune(relativeTo: date)
        loss.prune(relativeTo: date)
        throughput.prune(relativeTo: date)
        legacyLoss.prune(relativeTo: date)
    }

    /// True when the analyzer holds enough information for a live score.
    public var hasMeasurements: Bool {
        !latency.isEmpty || throughput.sampleCount > 0 || loss.attemptCount > 0
    }

    // MARK: - Metrics

    public func metrics() -> NetworkMetrics {
        let now = lastUpdate ?? Date()
        let lossEstimate = loss.estimate(relativeTo: now)
        let resolvedLoss = lossEstimate?.estimatedLossPercent ?? legacyLoss.mean

        let duration: TimeInterval
        if let startedAt, let lastUpdate {
            duration = max(0, lastUpdate.timeIntervalSince(startedAt))
        } else {
            duration = 0
        }

        return NetworkMetrics(
            averageThroughputMbps: throughput.averageMbps,
            p60ThroughputMbps: throughput.p60Mbps,
            throughputCoefficientOfVariation: throughput.coefficientOfVariation,
            averageLatencyMs: latency.mean,
            latencyJitterMs: jitter.jitterMs,
            packetLossPercent: resolvedLoss,
            averageRSSI: signalSmooth.value ?? signal.mean,
            rssiStandardDeviation: signal.standardDeviation,
            disconnectionCount: disconnections,
            latencySpikeCount: latencySpikes,
            dnsHealthy: dnsHealthy,
            internetReachable: internetReachable,
            sampleCount: probeCount,
            observationDuration: duration,
            latencySampleCount: latency.count,
            jitterMethod: jitter.methodDescription,
            throughputSampleCount: throughput.sampleCount,
            throughputWindowSeconds: throughput.windowSeconds,
            throughputIsApproximate: throughput.sampleCount > 0,
            throughputLastMeasuredAt: throughput.latestSampleAt,
            throughputProbeFailures: throughput.failureCount,
            lossEstimate: lossEstimate,
            connectivity: connectivity
        )
    }
}
