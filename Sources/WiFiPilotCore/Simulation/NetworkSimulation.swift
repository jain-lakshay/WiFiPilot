import Foundation

/// Synthetic network datasets used by tests and by the `wifipilot-simulate` harness.
///
/// These exist so the decision engine can be exercised against realistic patterns
/// (steady, fluctuating, peaky, lossy) without any Wi-Fi hardware.
public enum NetworkSimulation {
    public struct Series: Sendable, Equatable {
        public var name: String
        public var throughputMbps: [Double]
        public var latencyMs: [Double]
        public var jitterMs: [Double]
        public var packetLossPercent: [Double]
        public var rssi: [Double]
        public var disconnections: Int

        public init(
            name: String,
            throughputMbps: [Double] = [],
            latencyMs: [Double] = [],
            jitterMs: [Double] = [],
            packetLossPercent: [Double] = [],
            rssi: [Double] = [],
            disconnections: Int = 0
        ) {
            self.name = name
            self.throughputMbps = throughputMbps
            self.latencyMs = latencyMs
            self.jitterMs = jitterMs
            self.packetLossPercent = packetLossPercent
            self.rssi = rssi
            self.disconnections = disconnections
        }
    }

    /// The example from the product brief: 45 ± 1 Mbps, low jitter.
    public static let steadyFortyFive = Series(
        name: "Steady 45",
        throughputMbps: [45, 46, 44, 45, 46, 45, 45, 44, 46],
        latencyMs: [18, 17, 19, 18, 18, 17, 19, 18, 18],
        jitterMs: [2, 2, 3, 2, 2, 2, 3, 2, 2],
        packetLossPercent: [0, 0, 0, 0, 0, 0, 0, 0, 0],
        rssi: [-58, -58, -57, -59, -58, -58, -57, -58, -58]
    )

    /// The other half of the brief example: 40→60 Mbps with high variation.
    public static let fluctuatingFortyToSixty = Series(
        name: "Fluctuating 40-60",
        throughputMbps: [40, 45, 50, 35, 40, 60, 50, 38, 47],
        latencyMs: [20, 22, 19, 25, 21, 23, 20, 26, 22],
        jitterMs: [6, 7, 5, 9, 6, 8, 7, 9, 6],
        packetLossPercent: [0, 0, 0, 0.5, 0, 0, 0, 0.5, 0],
        rssi: [-60, -62, -59, -64, -61, -60, -63, -65, -62]
    )

    /// High average throughput produced by rare bursts — must not win.
    public static let burstyPeaks = Series(
        name: "Bursty peaks",
        throughputMbps: [12, 15, 300, 14, 16, 280, 13, 15, 310],
        latencyMs: [40, 45, 30, 50, 42, 35, 48, 44, 32],
        jitterMs: [15, 18, 8, 22, 16, 10, 20, 17, 9],
        packetLossPercent: [1, 1.5, 0, 2, 1, 0, 1.5, 1, 0],
        rssi: [-70, -72, -66, -74, -71, -67, -73, -72, -68]
    )

    /// Congested 2.4 GHz network: associated and technically working, but slow,
    /// jittery and lossy — exactly the situation where another network is worth it.
    public static let congested = Series(
        name: "Congested",
        throughputMbps: [7, 10, 5, 12, 8, 6, 9, 7, 8],
        latencyMs: [100, 140, 120, 160, 125, 105, 150, 130, 110],
        jitterMs: [40, 55, 45, 70, 50, 40, 60, 48, 42],
        packetLossPercent: [2, 3, 2.5, 4, 3, 2, 3.5, 3, 2.5],
        rssi: [-76, -78, -75, -80, -77, -76, -79, -78, -77]
    )

    /// Closer to a captive-portal failure: associated but no usable internet.
    public static let noInternet = Series(
        name: "No internet",
        throughputMbps: [],
        latencyMs: [],
        jitterMs: [],
        packetLossPercent: [100, 100, 100],
        rssi: [-55, -56, -55]
    )

    /// A strong, clean 5 GHz network.
    public static let strongFiveGHz = Series(
        name: "Strong 5 GHz",
        throughputMbps: [180, 195, 185, 190, 188, 192, 187, 190, 191],
        latencyMs: [11, 12, 10, 11, 12, 11, 10, 11, 11],
        jitterMs: [1, 2, 1, 1, 2, 1, 1, 2, 1],
        packetLossPercent: [0, 0, 0, 0, 0, 0, 0, 0, 0],
        rssi: [-50, -51, -50, -49, -50, -51, -50, -50, -49]
    )

    public static let all: [Series] = [
        steadyFortyFive,
        fluctuatingFortyToSixty,
        burstyPeaks,
        congested,
        noInternet,
        strongFiveGHz
    ]

    /// Aggregates a series into metrics exactly the way `StabilityAnalyzer` would.
    public static func metrics(from series: Series, observationDuration: TimeInterval = 60) -> NetworkMetrics {
        let throughputMean = series.throughputMbps.mean
        let throughputSD = series.throughputMbps.standardDeviation
        let cv: Double?
        if let throughputMean, throughputMean > 0, let throughputSD {
            cv = throughputSD / throughputMean
        } else {
            cv = nil
        }
        let reachable: Bool? = series.packetLossPercent.contains { $0 >= 100 } ? false : (series.packetLossPercent.isEmpty ? nil : true)
        return NetworkMetrics(
            averageThroughputMbps: throughputMean,
            p60ThroughputMbps: series.throughputMbps.percentile(0.6),
            throughputCoefficientOfVariation: cv,
            averageLatencyMs: series.latencyMs.mean,
            latencyJitterMs: series.jitterMs.mean,
            packetLossPercent: series.packetLossPercent.mean,
            averageRSSI: series.rssi.mean,
            rssiStandardDeviation: series.rssi.standardDeviation,
            disconnectionCount: series.disconnections,
            latencySpikeCount: 0,
            dnsHealthy: reachable == false ? false : true,
            internetReachable: reachable,
            sampleCount: max(series.latencyMs.count, series.packetLossPercent.count),
            observationDuration: observationDuration
        )
    }

    /// Health samples suitable for streaming into `StabilityAnalyzer` with a fake clock.
    public static func healthSamples(
        for series: Series,
        network: NetworkIdentity,
        startingAt start: Date,
        interval: TimeInterval = 5
    ) -> [HealthSample] {
        let count = Swift.max(
            series.latencyMs.count,
            Swift.max(series.throughputMbps.count, series.packetLossPercent.count)
        )
        let reachable = series.packetLossPercent.first.map { $0 < 100 } ?? true
        var samples: [HealthSample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let timestamp = start.addingTimeInterval(Double(index) * interval)
            let latency: Double? = index < series.latencyMs.count ? series.latencyMs[index] : nil
            let jitter: Double? = index < series.jitterMs.count ? series.jitterMs[index] : nil
            let loss: Double? = index < series.packetLossPercent.count ? series.packetLossPercent[index] : nil
            let throughput: Double? = index < series.throughputMbps.count ? series.throughputMbps[index] : nil
            samples.append(
                HealthSample(
                    timestamp: timestamp,
                    latencyMs: latency,
                    jitterMs: jitter,
                    packetLossPercent: loss,
                    dnsResolutionMs: latency.map { $0 * 0.4 },
                    dnsHealthy: reachable,
                    internetReachable: reachable,
                    throughputMbps: throughput,
                    network: network
                )
            )
        }
        return samples
    }

    /// Convenience: build a candidate snapshot for engine tests.
    public static func snapshot(
        ssid: String,
        series: Series,
        weights: ScoringWeights = .standard,
        isKnownSaved: Bool = true,
        isPreferred: Bool = false,
        isAvoided: Bool = false,
        isNeverAutoJoin: Bool = false,
        isAvailable: Bool = true,
        basis: ScoreBasis? = nil,
        rssiOverride: Double? = nil,
        at date: Date,
        firstObservedAt: Date? = nil
    ) -> CandidateSnapshot {
        let engine = NetworkScoringEngine(weights: weights)
        let metrics = metrics(from: series)
        let resolvedBasis = basis ?? (series.latencyMs.isEmpty ? .signalOnly : .historical)
        let score = engine.score(metrics: metrics, basis: resolvedBasis)
        let rssi = rssiOverride ?? (series.rssi.mean ?? -70)
        return CandidateSnapshot(
            network: NetworkIdentity(ssid: ssid),
            rssi: rssi,
            rssiStandardDeviation: series.rssi.standardDeviation,
            score: score,
            isKnownSaved: isKnownSaved,
            isPreferred: isPreferred,
            isAvoided: isAvoided,
            isNeverAutoJoin: isNeverAutoJoin,
            isAvailable: isAvailable,
            firstObservedAt: firstObservedAt ?? date.addingTimeInterval(-300),
            lastObservedAt: date,
            historicalReliability: nil,
            isInternetReachable: nil
        )
    }
}
