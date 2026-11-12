import XCTest
@testable import WiFiPilotCore

/// Scoring and analysis tests. These never touch Wi-Fi hardware.
final class ScoringTests: XCTestCase {
    private let engine = NetworkScoringEngine()

    // MARK: - Consistency over peak speed

    func testStableNetworkOutscoresFluctuatingNetworkWithSameAverage() {
        let steady = engine.score(
            metrics: NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive),
            basis: .historical
        )
        let fluctuating = engine.score(
            metrics: NetworkSimulation.metrics(from: NetworkSimulation.fluctuatingFortyToSixty),
            basis: .historical
        )

        XCTAssertGreaterThan(
            steady.total,
            fluctuating.total,
            "The steady 45 Mbps network must beat the 40-60 Mbps fluctuating one"
        )
        let steadyVariation = steady.component(.stability)?.quality ?? 0
        let fluctuatingVariation = fluctuating.component(.stability)?.quality ?? 0
        XCTAssertGreaterThan(steadyVariation, fluctuatingVariation)
    }

    func testBurstyPeaksDoNotWin() {
        let steady = engine.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive), basis: .historical)
        let bursty = engine.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.burstyPeaks), basis: .historical)

        XCTAssertLessThan(
            bursty.total,
            steady.total,
            "A network averaging more throughput through rare bursts must not outrank a steady network"
        )
    }

    func testThroughputIsLogScaledSoSmallGainsMatterLittle() {
        let a = NetworkScoringEngine.throughputQuality(mbps: 45)
        let b = NetworkScoringEngine.throughputQuality(mbps: 55)
        let c = NetworkScoringEngine.throughputQuality(mbps: 200)

        XCTAssertLessThan(b - a, 0.06, "45 → 55 Mbps should be a marginal quality change")
        XCTAssertGreaterThan(c - b, 0.2, "55 → 200 Mbps should be a large quality change")
        XCTAssertGreaterThan(c - b, 3 * (b - a), "speed must not be rewarded linearly")
    }

    // MARK: - Individual metrics

    func testLatencyAndJitterReduceScore() {
        var good = NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive)
        var poor = good
        poor.averageLatencyMs = 180
        poor.latencyJitterMs = 70

        let goodScore = engine.score(metrics: good, basis: .live)
        let poorScore = engine.score(metrics: poor, basis: .live)
        XCTAssertGreaterThan(goodScore.total, poorScore.total)
        XCTAssertGreaterThan(
            goodScore.component(.latency)?.quality ?? 0,
            poorScore.component(.latency)?.quality ?? 0
        )

        good.averageLatencyMs = 18
        XCTAssertNotEqual(goodScore.total, poorScore.total)
    }

    func testPacketLossReducesScore() {
        let clean = engine.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive), basis: .live)

        var lossyMetrics = NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive)
        lossyMetrics.packetLossPercent = 9
        let lossy = engine.score(metrics: lossyMetrics, basis: .live)

        XCTAssertGreaterThan(clean.total, lossy.total)
        XCTAssertTrue(lossy.penalties.contains { $0.reason.contains("Packet loss") })
    }

    func testDisconnectionsPenaliseScore() {
        var metrics = NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive)
        metrics.disconnectionCount = 3
        let unstable = engine.score(metrics: metrics, basis: .live)
        let stable = engine.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive), basis: .live)
        XCTAssertGreaterThan(stable.total, unstable.total)
        XCTAssertTrue(unstable.penalties.contains { $0.reason.contains("disconnections") })
    }

    func testNoInternetCapsScore() {
        var metrics = NetworkSimulation.metrics(from: NetworkSimulation.strongFiveGHz)
        metrics.internetReachable = false
        metrics.packetLossPercent = 100
        let score = engine.score(metrics: metrics, basis: .live)
        XCTAssertLessThanOrEqual(score.total, 20)
        XCTAssertTrue(score.penalties.contains { $0.reason.contains("internet") })
    }

    // MARK: - Basis and confidence

    func testSignalOnlyScoreIsCappedAndLowConfidence() {
        let score = engine.signalOnlyScore(rssi: -45, rssiStandardDeviation: 1)
        XCTAssertLessThanOrEqual(score.total, 60)
        XCTAssertEqual(score.basis, .signalOnly)
        XCTAssertLessThan(score.confidence, 0.5)
        XCTAssertTrue(score.components.contains { !$0.isMeasured })
    }

    func testHistoricalScoreHasLowerConfidenceThanLive() {
        let metrics = NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive)
        let live = engine.score(metrics: metrics, basis: .live)
        let historical = engine.historicalScore(for: metrics, sampleCount: 3)
        XCTAssertGreaterThan(live.confidence, historical.confidence)
    }

    func testUnmeasuredMetricsAreMarkedAndNeutral() {
        let metrics = NetworkMetrics.empty
        let score = engine.score(metrics: metrics, basis: .signalOnly)
        for component in score.components {
            XCTAssertFalse(component.isMeasured)
            XCTAssertEqual(component.quality, 0.5, accuracy: 0.0001)
        }
    }

    // MARK: - Weights

    func testStabilityPreferenceShiftsWeightFromThroughput() {
        var speedy = ScoringWeights.standard
        speedy.stabilityPreference = 0
        var consistent = ScoringWeights.standard
        consistent.stabilityPreference = 1

        let speedyWeights = speedy.effectiveWeights()
        let consistentWeights = consistent.effectiveWeights()
        XCTAssertGreaterThan(speedyWeights[.throughput] ?? 0, consistentWeights[.throughput] ?? 0)
        XCTAssertLessThan(speedyWeights[.stability] ?? 0, consistentWeights[.stability] ?? 0)

        let sumSpeedy = speedyWeights.values.reduce(0, +)
        XCTAssertEqual(sumSpeedy, 1.0, accuracy: 0.0001)
    }

    func testWeightsAreSanitized() {
        let broken = ScoringWeights(
            throughput: -1,
            latency: .nan,
            jitter: 0,
            packetLoss: 0,
            signal: 0,
            stability: 0,
            stabilityPreference: 5
        )
        let sanitized = broken.sanitized()
        XCTAssertGreaterThanOrEqual(sanitized.throughput, 0)
        XCTAssertGreaterThanOrEqual(sanitized.latency, 0)
        XCTAssertLessThanOrEqual(sanitized.stabilityPreference, 1)
    }

    // MARK: - Analysis plumbing

    func testStabilityAnalyzerDerivesVariationFromSamples() {
        var analyzer = StabilityAnalyzer(windowDuration: 120)
        let network = NetworkIdentity(ssid: "Fluctuating")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        analyzer.start(network: network, at: start)

        let samples = NetworkSimulation.healthSamples(
            for: NetworkSimulation.fluctuatingFortyToSixty,
            network: network,
            startingAt: start,
            interval: 5
        )
        for sample in samples { analyzer.add(health: sample) }

        let metrics = analyzer.metrics()
        XCTAssertNotNil(metrics.throughputCoefficientOfVariation)
        XCTAssertGreaterThan(metrics.throughputCoefficientOfVariation ?? 0, 0.1)
        XCTAssertEqual(metrics.averageThroughputMbps ?? 0, NetworkSimulation.fluctuatingFortyToSixty.throughputMbps.mean ?? 0, accuracy: 0.001)
    }

    func testExponentialMovingAverageDampsSpikes() {
        var average = ExponentialMovingAverage(alpha: 0.3)
        average.add(10)
        average.add(10)
        average.add(10)
        let afterSpike = average.add(100)
        XCTAssertLessThan(afterSpike, 40)
        XCTAssertGreaterThan(afterSpike, 10)
    }

    func testSampleWindowDropsOldSamples() {
        var window = SampleWindow(duration: 60)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        window.add(1, at: start)
        window.add(2, at: start.addingTimeInterval(30))
        window.add(3, at: start.addingTimeInterval(120))

        XCTAssertEqual(window.values, [3])
    }

    func testPercentileInterpolates() {
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        XCTAssertEqual(values.percentile(0.5) ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(values.percentile(0.0) ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(values.percentile(1.0) ?? 0, 5, accuracy: 0.0001)
    }

    func testCongestedNetworkScoresBelowDegradationThreshold() {
        let score = engine.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.congested), basis: .live)
        XCTAssertLessThan(score.total, SwitchingPolicy.standard.degradationScoreThreshold)
        XCTAssertGreaterThan(score.total, 0)
    }
}
