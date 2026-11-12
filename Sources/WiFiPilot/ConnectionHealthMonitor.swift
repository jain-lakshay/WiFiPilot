import Foundation
import WiFiPilotCore

/// Owns the live measurement state for the current association.
///
/// `StabilityAnalyzer` is the shared, tested core type; this actor only orchestrates
/// probe rounds, RSSI sampling and disconnections into it.
///
/// The throughput window is deliberately longer (5 minutes) than the observation
/// window, because small rate-limited probes need several samples spread over minutes
/// before variation means anything.
actor ConnectionHealthMonitor {
    private var analyzer: StabilityAnalyzer
    private var windowDuration: TimeInterval
    private let throughputWindowDuration: TimeInterval

    init(windowDuration: TimeInterval = 60, throughputWindowDuration: TimeInterval = 300) {
        self.windowDuration = windowDuration
        self.throughputWindowDuration = throughputWindowDuration
        self.analyzer = StabilityAnalyzer(
            windowDuration: windowDuration,
            capacity: 900,
            alpha: 0.3,
            throughputWindowDuration: throughputWindowDuration
        )
    }

    func start(network: NetworkIdentity?, at date: Date) {
        analyzer.start(network: network, at: date)
    }

    func updateWindow(_ duration: TimeInterval) {
        guard abs(duration - windowDuration) > 0.5 else { return }
        let network = analyzer.network
        let wasStarted = analyzer.startedAt
        windowDuration = duration
        analyzer = StabilityAnalyzer(
            windowDuration: duration,
            capacity: 900,
            alpha: 0.3,
            throughputWindowDuration: throughputWindowDuration
        )
        if let wasStarted { analyzer.start(network: network, at: wasStarted) }
    }

    @discardableResult
    func recordSignal(rssi: Int, at date: Date) -> NetworkMetrics {
        analyzer.addSignal(rssi: rssi, at: date)
        return analyzer.metrics()
    }

    func recordDisconnection(at date: Date) {
        analyzer.recordDisconnection(at: date)
    }

    func currentMetrics() -> NetworkMetrics {
        analyzer.metrics()
    }

    func currentNetwork() -> NetworkIdentity? {
        analyzer.network
    }

    /// Feeds one structured probe round in and returns the sample plus fresh metrics.
    ///
    /// No debouncing is applied to reachability here: the probe already classifies the
    /// connection, and inventing "still fine" after a failed verification is exactly the
    /// silent over-reporting this design avoids.
    func ingest(
        _ round: ProbeRoundSummary,
        rssi: Int?,
        network: NetworkIdentity?,
        at date: Date
    ) -> (HealthSample, NetworkMetrics) {
        if let current = analyzer.network, let network, current.networkKey != network.networkKey {
            analyzer.start(network: network, at: date)
        }
        if let rssi {
            analyzer.addSignal(rssi: rssi, at: date)
        }

        analyzer.add(round: round)
        let metrics = analyzer.metrics()

        let sample = HealthSample(
            timestamp: date,
            latencyMs: round.medianLatencyMs,
            jitterMs: metrics.latencyJitterMs,
            packetLossPercent: metrics.packetLossPercent,
            dnsResolutionMs: round.dnsResolutionMs,
            dnsHealthy: round.dnsHealthy,
            internetReachable: round.connectivity.isVerifiedInternet,
            throughputMbps: round.throughput.measuredMbps,
            throughputMeasurementFailed: round.throughput.failureReason != nil,
            connectivity: round.connectivity,
            network: network
        )
        return (sample, metrics)
    }
}
