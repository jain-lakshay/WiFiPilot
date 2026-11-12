import XCTest
@testable import WiFiPilotCore

/// Tests for the measurement layer: throughput windows, temporal jitter, probe-loss
/// estimation, connectivity classification, missing-data handling, active-transfer
/// protection, OFF semantics and switch-rate limiting.
final class MonitoringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private var verified: ConnectivityAssessment {
        ConnectivityClassifier.classify(pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .success)
    }

    private func round(
        at date: Date,
        latencies: [Double] = [28],
        endpoint: String = "1.1.1.1:443",
        timeouts: Int = 0,
        refused: Int = 0,
        dnsFailures: Int = 0,
        pathFailures: Int = 0,
        dnsHealthy: Bool = true,
        connectivity: ConnectivityAssessment? = nil,
        throughput: ThroughputOutcome = .notAttempted
    ) -> ProbeRoundSummary {
        let failures = timeouts + refused + dnsFailures + pathFailures
        return ProbeRoundSummary(
            timestamp: date,
            endpoint: endpoint,
            latenciesMs: latencies,
            attempts: latencies.count + failures,
            successes: latencies.count,
            timeouts: timeouts,
            refused: refused,
            dnsFailures: dnsFailures,
            pathFailures: pathFailures,
            dnsHealthy: dnsHealthy,
            connectivity: connectivity ?? verified,
            throughput: throughput
        )
    }

    // MARK: - 1. Throughput

    func testStableThroughputHasLowVariation() {
        var sampler = ThroughputSampler()
        for (index, mbps) in [50.0, 49.4, 50.6, 50.1, 49.8].enumerated() {
            sampler.record(mbps: mbps, at: at(Double(index) * 60))
        }

        XCTAssertEqual(sampler.sampleCount, 5)
        XCTAssertTrue(sampler.hasEnoughSamplesForVariability)
        XCTAssertEqual(sampler.averageMbps ?? 0, 50.0, accuracy: 0.5)
        XCTAssertLessThan(sampler.coefficientOfVariation ?? 1, 0.05)
        XCTAssertEqual(sampler.windowSeconds, 300)
    }

    func testFluctuatingThroughputHasHighVariation() {
        var sampler = ThroughputSampler()
        for (index, mbps) in [60.0, 4.0, 55.0, 3.0, 48.0, 5.0].enumerated() {
            sampler.record(mbps: mbps, at: at(Double(index) * 45))
        }

        XCTAssertEqual(sampler.sampleCount, 6)
        XCTAssertGreaterThan(sampler.coefficientOfVariation ?? 0, 0.5)
        XCTAssertLessThan(sampler.p10Mbps ?? 99, sampler.p60Mbps ?? 0)
    }

    func testThroughputWindowKeepsFiveMinutesOfSamples() {
        var sampler = ThroughputSampler()
        for seconds in [0.0, 90, 180, 270, 400] {
            sampler.record(mbps: 40, at: at(seconds))
        }

        // At 400 s the 300 s window keeps samples from 100 s onward: three remain.
        XCTAssertEqual(sampler.sampleCount, 3)
        XCTAssertEqual(sampler.values.count, 3)
    }

    func testFailedThroughputProbeIsNotZeroThroughput() {
        var sampler = ThroughputSampler()
        sampler.record(mbps: 42, at: at(0))
        sampler.recordFailure(reason: "timed out", at: at(90))

        XCTAssertEqual(sampler.sampleCount, 1, "A failed measurement must not become a zero sample")
        XCTAssertEqual(sampler.averageMbps ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(sampler.failureCount, 1)
        XCTAssertEqual(sampler.attemptCount, 2)
    }

    func testThroughputProbePolicyRespectsBandwidthAndUserTraffic() {
        let disabled = ThroughputProbePolicy(isEnabled: false)
        let assessment = disabled.assess(
            now: at(0), isConnected: true, traffic: .idle, lastAttemptAt: nil, lastFailureAt: nil
        )
        XCTAssertEqual(assessment.decision, .disabled)
        XCTAssertFalse(assessment.shouldProbe)

        let policy = ThroughputProbePolicy(isEnabled: true, minimumInterval: 90)
        XCTAssertLessThan(policy.estimatedMegabytesPerHour, 10.1, "Default cadence must stay around 10 MB/hour")

        XCTAssertEqual(
            policy.assess(now: at(0), isConnected: false, traffic: .idle, lastAttemptAt: nil, lastFailureAt: nil).decision,
            .notConnected
        )

        let busy = TrafficAssessment(isActive: true, incomingMbps: 25, outgoingMbps: 2, windowSeconds: 5, reason: "Active transfer")
        XCTAssertEqual(
            policy.assess(now: at(0), isConnected: true, traffic: busy, lastAttemptAt: nil, lastFailureAt: nil).decision,
            .userTrafficActive
        )

        XCTAssertEqual(
            policy.assess(now: at(30), isConnected: true, traffic: .idle, lastAttemptAt: at(0), lastFailureAt: nil).decision,
            .tooSoon
        )

        XCTAssertEqual(
            policy.assess(now: at(100), isConnected: true, traffic: .idle, lastAttemptAt: at(0), lastFailureAt: at(20)).decision,
            .backoffAfterFailure
        )

        XCTAssertEqual(
            policy.assess(now: at(200), isConnected: true, traffic: .idle, lastAttemptAt: at(0), lastFailureAt: nil).decision,
            .probe
        )
    }

    func testAnalyzerLabelsThroughputAsApproximateAndWindowed() {
        var analyzer = StabilityAnalyzer()
        analyzer.start(network: NetworkIdentity(ssid: "Home"), at: at(0))
        analyzer.add(round: round(at: at(0), throughput: .measured(mbps: 48)))
        analyzer.add(round: round(at: at(90), throughput: .measured(mbps: 12)))

        let metrics = analyzer.metrics()
        XCTAssertEqual(metrics.throughputSampleCount, 2)
        XCTAssertEqual(metrics.throughputWindowSeconds, 300)
        XCTAssertEqual(metrics.throughputIsApproximate, true)
        XCTAssertEqual(metrics.averageThroughputMbps ?? 0, 30, accuracy: 0.001)
        XCTAssertNotNil(metrics.throughputCoefficientOfVariation)
    }

    // MARK: - 2. Jitter

    func testJitterComesFromSuccessiveLatenciesNotAverageLatency() {
        var estimator = JitterEstimator()
        var clock = 0.0
        for value in [20.0, 40, 20, 40, 20, 40] {
            estimator.add(latencyMs: value, at: at(clock), endpoint: "1.1.1.1:443")
            clock += 5
        }

        XCTAssertEqual(estimator.averageLatencyMs ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(estimator.jitterMs ?? 0, 20, accuracy: 1.5)
        XCTAssertNotEqual(estimator.jitterMs ?? 0, estimator.averageLatencyMs ?? 0)
        XCTAssertEqual(estimator.sampleCount, 6)
    }

    func testStableLatencyHasLowJitter() {
        var estimator = JitterEstimator()
        for (index, value) in [20.0, 21, 20, 21, 20].enumerated() {
            estimator.add(latencyMs: value, at: at(Double(index) * 5), endpoint: "1.1.1.1:443")
        }
        XCTAssertEqual(estimator.jitterMs ?? 99, 1, accuracy: 0.3)
        XCTAssertLessThan(estimator.jitterMs ?? 99, 3)
    }

    func testJitterIsNotComputedAcrossDifferentEndpoints() {
        var estimator = JitterEstimator()
        estimator.add(latencyMs: 20, at: at(0), endpoint: "1.1.1.1:443")
        estimator.add(latencyMs: 22, at: at(5), endpoint: "1.1.1.1:443")
        estimator.add(latencyMs: 300, at: at(10), endpoint: "9.9.9.9:443")

        XCTAssertEqual(estimator.sampleCount, 1, "Changing endpoint restarts the measurement window")
        XCTAssertNil(estimator.windowJitterMs)
        XCTAssertEqual(estimator.endpoint, "9.9.9.9:443")
    }

    // MARK: - 3. Probe loss

    func testIntermittentEndpointFailuresProduceRollingLoss() {
        var estimator = PacketLossEstimator()
        for (index, failure) in [0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0].enumerated() {
            let attempt = failure == 1
                ? ProbeAttempt(timestamp: at(Double(index) * 5), endpoint: "1.1.1.1:443", failure: .timeout)
                : ProbeAttempt(timestamp: at(Double(index) * 5), endpoint: "1.1.1.1:443", latencyMs: 30)
            estimator.record(attempt)
        }

        let estimate = estimator.estimate(relativeTo: at(60))
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate?.attempts, 12)
        XCTAssertEqual(estimate?.timeouts, 3)
        XCTAssertEqual(estimate?.successes, 9)
        XCTAssertEqual(estimate?.estimatedLossPercent ?? 0, 25, accuracy: 0.01)
        XCTAssertEqual(estimate?.isStatisticallyMeaningful, true)
        XCTAssertEqual(estimate?.confidence ?? 0, 1, accuracy: 0.001)
    }

    func testLossDistinguishesFailureKinds() {
        var estimator = PacketLossEstimator()
        estimator.record(ProbeAttempt(timestamp: at(0), endpoint: "1.1.1.1", latencyMs: 25))
        estimator.record(ProbeAttempt(timestamp: at(5), endpoint: "1.1.1.1", failure: .dnsFailure))
        estimator.record(ProbeAttempt(timestamp: at(10), endpoint: "1.1.1.1", failure: .connectionRefused))
        estimator.record(ProbeAttempt(timestamp: at(15), endpoint: "1.1.1.1", failure: .pathUnavailable))
        estimator.record(ProbeAttempt(timestamp: at(20), endpoint: "1.1.1.1", failure: .timeout))

        let estimate = estimator.estimate(relativeTo: at(20))
        XCTAssertEqual(estimate?.dnsFailures, 1)
        XCTAssertEqual(estimate?.refused, 1)
        XCTAssertEqual(estimate?.pathFailures, 1)
        XCTAssertEqual(estimate?.timeouts, 1)
        XCTAssertEqual(estimate?.successes, 1)
        XCTAssertEqual(estimate?.estimatedLossPercent ?? 0, 80, accuracy: 0.01)
    }

    func testLossEstimateIsNotPresentedAsIcmpPacketLoss() {
        var estimator = PacketLossEstimator()
        estimator.record(ProbeAttempt(timestamp: at(0), endpoint: "1.1.1.1", latencyMs: 20))
        estimator.record(ProbeAttempt(timestamp: at(5), endpoint: "1.1.1.1", failure: .timeout))
        let estimate = estimator.estimate(relativeTo: at(5))

        XCTAssertEqual(estimate?.method, "TCP connection attempts (not ICMP)")
        XCTAssertTrue(estimate?.summary.contains("timed out") ?? false)
        XCTAssertEqual(estimate?.attempts, 2)
    }

    func testLossWindowExpires() {
        var estimator = PacketLossEstimator(windowDuration: 60)
        estimator.record(ProbeAttempt(timestamp: at(0), endpoint: "1.1.1.1", failure: .timeout))
        XCTAssertNotNil(estimator.estimate(relativeTo: at(10)))
        XCTAssertNil(estimator.estimate(relativeTo: at(300)), "Old attempts must fall out of the rolling window")
    }

    // MARK: - 4. Reachability

    func testCaptivePortalDetection() {
        let redirected = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .redirect
        )
        XCTAssertEqual(redirected.classification, .captivePortal)
        XCTAssertFalse(redirected.isVerifiedInternet)

        let intercepted = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .unexpectedContent
        )
        XCTAssertEqual(intercepted.classification, .captivePortal)
        XCTAssertFalse(intercepted.isVerifiedInternet)
    }

    func testTCPWithoutHTTPVerificationIsNotVerifiedInternet() {
        let restricted = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .failure
        )
        XCTAssertEqual(restricted.classification, .restricted)
        XCTAssertFalse(restricted.isVerifiedInternet)

        let unverified = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: nil
        )
        XCTAssertEqual(unverified.classification, .unverified)
        XCTAssertFalse(unverified.isVerifiedInternet)

        let verifiedOpen = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .success
        )
        XCTAssertEqual(verifiedOpen.classification, .verifiedOpen)
        XCTAssertTrue(verifiedOpen.isVerifiedInternet)
    }

    func testDNSFailureAndOfflineClassification() {
        let dns = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: false, tcpReachable: false, httpResult: .failure
        )
        XCTAssertEqual(dns.classification, .dnsFailure)

        let dnsNoHTTP = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: false, tcpReachable: true, httpResult: nil
        )
        XCTAssertEqual(dnsNoHTTP.classification, .dnsFailure)

        let offline = ConnectivityClassifier.classify(
            pathAvailable: false, dnsHealthy: nil, tcpReachable: false, httpResult: nil
        )
        XCTAssertEqual(offline.classification, .offline)
        XCTAssertFalse(offline.isVerifiedInternet)
    }

    func testAnalyzerCarriesConnectivityIntoMetrics() {
        var analyzer = StabilityAnalyzer()
        analyzer.start(network: NetworkIdentity(ssid: "Hotel"), at: at(0))
        let portal = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .redirect
        )
        analyzer.add(round: round(at: at(0), connectivity: portal))

        let metrics = analyzer.metrics()
        XCTAssertEqual(metrics.connectivityClass, .captivePortal)
        XCTAssertEqual(metrics.isInternetVerified, false)
        XCTAssertNil(metrics.latencyJitterMs, "A single latency sample cannot produce jitter")
    }

    // MARK: - Scoring integration

    func testConnectivityClassesCapScores() {
        let engine = NetworkScoringEngine(weights: .standard)
        let base = NetworkSimulation.metrics(from: NetworkSimulation.strongFiveGHz)

        var verifiedMetrics = base
        verifiedMetrics.connectivity = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .success
        )
        var portalMetrics = base
        portalMetrics.connectivity = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .redirect
        )
        var restrictedMetrics = base
        restrictedMetrics.connectivity = ConnectivityClassifier.classify(
            pathAvailable: true, dnsHealthy: true, tcpReachable: true, httpResult: .failure
        )
        var offlineMetrics = base
        offlineMetrics.connectivity = ConnectivityClassifier.classify(
            pathAvailable: false, dnsHealthy: nil, tcpReachable: false, httpResult: nil
        )

        let verifiedScore = engine.score(metrics: verifiedMetrics, basis: .live)
        let portalScore = engine.score(metrics: portalMetrics, basis: .live)
        let restrictedScore = engine.score(metrics: restrictedMetrics, basis: .live)
        let offlineScore = engine.score(metrics: offlineMetrics, basis: .live)

        XCTAssertGreaterThan(verifiedScore.total, 80)
        XCTAssertLessThanOrEqual(portalScore.total, 25)
        XCTAssertLessThanOrEqual(restrictedScore.total, 45)
        XCTAssertLessThanOrEqual(offlineScore.total, 20)
        XCTAssertTrue(portalScore.penalties.contains { $0.reason.contains("Captive portal") })
        XCTAssertLessThan(portalScore.total, verifiedScore.total)
    }

    func testProbeLossIsLabelledAsProbeLossInScoring() {
        var analyzer = StabilityAnalyzer()
        analyzer.start(network: NetworkIdentity(ssid: "Flaky"), at: at(0))
        for index in 0..<4 {
            analyzer.add(round: round(at: at(Double(index) * 5), timeouts: 1))
        }
        let metrics = analyzer.metrics()

        XCTAssertEqual(metrics.packetLossPercent ?? 0, 50, accuracy: 0.01)
        XCTAssertNotNil(metrics.lossEstimate)

        let score = NetworkScoringEngine(weights: .standard).score(metrics: metrics, basis: .live)
        XCTAssertTrue(
            score.penalties.contains { $0.reason.hasPrefix("Probe loss") },
            "Probe loss must not be reported as ICMP packet loss: \(score.penalties.map(\.reason))"
        )
    }

    // MARK: - 5. Missing data and OFF

    func testMissingThroughputIsUnavailableNotZero() {
        var analyzer = StabilityAnalyzer()
        analyzer.start(network: NetworkIdentity(ssid: "Metered"), at: at(0))
        analyzer.add(round: round(at: at(0), throughput: .notAttempted))
        analyzer.add(round: round(at: at(90), throughput: .unavailable(reason: "request timed out")))

        let metrics = analyzer.metrics()
        XCTAssertNil(metrics.averageThroughputMbps)
        XCTAssertFalse(metrics.hasThroughputMeasurement)
        XCTAssertEqual(metrics.throughputSampleCount, 0)
        XCTAssertEqual(metrics.throughputProbeFailures, 1)

        let score = NetworkScoringEngine(weights: .standard).score(metrics: metrics, basis: .live)
        XCTAssertEqual(
            score.component(.throughput)?.isMeasured,
            false,
            "Missing throughput must not be scored as zero throughput"
        )
    }

    func testAutomationDefaultsAreSafe() {
        let settings = AppSettings.default
        XCTAssertEqual(settings.automationMode, .observe)
        XCTAssertNotEqual(settings.automationMode, .auto)
        XCTAssertFalse(settings.throughputProbeEnabled)
        XCTAssertEqual(settings.throughputProbeIntervalSeconds, 90)
        XCTAssertEqual(settings.throughputPolicy.windowDuration, 300)
        XCTAssertEqual(SwitchingPolicy.standard.maximumSwitchesPerHour, 4)
    }

    func testOffModeMeansAutomationOffWhileMonitoringContinues() {
        XCTAssertTrue(AutomationMode.off.explanation.contains("Monitoring continues"))
        XCTAssertTrue(AutomationMode.off.explanation.contains("never evaluates"))
        XCTAssertEqual(AutomationMode.off.displayName, "Off")

        // Monitoring data is still produced while the engine refuses to act.
        var analyzer = StabilityAnalyzer()
        analyzer.start(network: NetworkIdentity(ssid: "Home"), at: at(0))
        analyzer.add(round: round(at: at(0), latencies: [20, 22]))
        XCTAssertTrue(analyzer.hasMeasurements)

        var engine = DecisionEngine()
        let decision = engine.evaluate(
            DecisionInput(
                current: snapshot("Home", NetworkSimulation.congested, basis: .live),
                candidates: [snapshot("Better", NetworkSimulation.strongFiveGHz, basis: .historical)],
                mode: .off
            ),
            at: at(60)
        )
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .automationOff)
    }

    // MARK: - 6. Switch rate limiting

    func testSwitchRateLimitStopsRepeatedSwitching() {
        var policy = SwitchingPolicy.standard
        policy.cooldownDuration = 0
        policy.manualSwitchProtection = 0
        policy.degradationDuration = 0
        policy.candidateQualificationDuration = 0
        policy.maximumSwitchesPerHour = 2

        var engine = DecisionEngine(policy: policy)
        let current = snapshot("WeakNet", NetworkSimulation.congested, basis: .live)
        let candidate = snapshot("GoodNet", NetworkSimulation.strongFiveGHz, basis: .historical)

        func evaluateNow(_ date: Date) -> AutomatedDecision {
            engine.evaluate(
                DecisionInput(current: current, candidates: [candidate], mode: .auto, policy: policy),
                at: date
            )
        }

        let first = evaluateNow(at(0))
        XCTAssertEqual(first.action, .switchNetwork)
        engine.recordAutomatedSwitch(to: NetworkIdentity(ssid: "GoodNet"), at: at(0))

        let second = evaluateNow(at(10))
        XCTAssertEqual(second.action, .switchNetwork)
        engine.recordAutomatedSwitch(to: NetworkIdentity(ssid: "GoodNet"), at: at(10))

        let blocked = evaluateNow(at(20))
        XCTAssertEqual(blocked.action, .stay)
        XCTAssertEqual(blocked.reason.code, .switchRateLimited)
        XCTAssertEqual(engine.switchAttempts(inLast: 3600, at: at(20)), 2)

        // An hour later the history has rolled off and switching is allowed again.
        XCTAssertEqual(engine.switchAttempts(inLast: 3600, at: at(4000)), 0)
    }

    func testEmergencySwitchBypassesRateLimit() {
        var policy = SwitchingPolicy.standard
        policy.maximumSwitchesPerHour = 1
        policy.cooldownDuration = 0
        policy.degradationDuration = 0
        policy.candidateQualificationDuration = 0

        var engine = DecisionEngine(policy: policy)
        engine.recordAutomatedSwitch(to: NetworkIdentity(ssid: "Somewhere"), at: at(0))

        let dead = snapshot("DeadNet", NetworkSimulation.noInternet, basis: .live, reachable: false)
        let good = snapshot("GoodNet", NetworkSimulation.strongFiveGHz, basis: .historical)
        let decision = engine.evaluate(
            DecisionInput(current: dead, candidates: [good], mode: .auto, policy: policy),
            at: at(30)
        )
        XCTAssertEqual(decision.action, .switchNetwork)
        XCTAssertEqual(decision.reason.code, .emergencySwitch)
    }

    // MARK: - 7. Active transfer protection

    func testActiveTransferProtectsDuringHandover() {
        var policy = SwitchingPolicy.standard
        policy.minimumScoreAdvantage = 30
        policy.activeTrafficAdvantageBonus = 20
        policy.cooldownDuration = 0
        policy.degradationDuration = 0
        policy.candidateQualificationDuration = 0

        let current = snapshot("WeakNet", NetworkSimulation.congested, basis: .live)
        let candidate = snapshot("GoodNet", NetworkSimulation.strongFiveGHz, basis: .historical)
        let advantage = candidate.score.total - current.score.total
        XCTAssertGreaterThan(advantage, policy.minimumScoreAdvantage)
        XCTAssertLessThan(advantage, policy.minimumScoreAdvantage + policy.activeTrafficAdvantageBonus)

        let traffic = TrafficAssessment(isActive: true, incomingMbps: 60, outgoingMbps: 4, windowSeconds: 5, reason: "Active transfer at 64.0 Mbps")

        var engine = DecisionEngine(policy: policy)
        let quiet = engine.evaluate(
            DecisionInput(current: current, candidates: [candidate], mode: .auto, policy: policy),
            at: at(0)
        )
        XCTAssertEqual(quiet.action, .switchNetwork)

        var busyEngine = DecisionEngine(policy: policy)
        let busy = busyEngine.evaluate(
            DecisionInput(current: current, candidates: [candidate], mode: .auto, activeTraffic: traffic, policy: policy),
            at: at(0)
        )
        XCTAssertEqual(busy.action, .stay)
        XCTAssertEqual(busy.reason.code, .activeTrafficProtection)
    }

    func testThroughputProbeIsDeferredDuringUserTransfer() {
        let policy = ThroughputProbePolicy(isEnabled: true, minimumInterval: 90, maximumUserTrafficMbps: 1.0)
        let transfer = TrafficAssessment(isActive: true, incomingMbps: 8, outgoingMbps: 1, windowSeconds: 5, reason: "Download")
        let decision = policy.assess(
            now: at(600), isConnected: true, traffic: transfer, lastAttemptAt: nil, lastFailureAt: nil
        )
        XCTAssertEqual(decision.decision, .userTrafficActive)
        XCTAssertFalse(decision.shouldProbe)
        XCTAssertTrue(decision.detail.contains("Deferred"))

        // The same policy probes once the transfer is over.
        XCTAssertTrue(
            policy.assess(now: at(660), isConnected: true, traffic: .idle, lastAttemptAt: nil, lastFailureAt: nil).shouldProbe
        )
    }

    // MARK: - Fixtures

    private func snapshot(
        _ ssid: String,
        _ series: NetworkSimulation.Series,
        basis: ScoreBasis,
        reachable: Bool? = nil
    ) -> CandidateSnapshot {
        let metrics = NetworkSimulation.metrics(from: series)
        let score = NetworkScoringEngine(weights: .standard).score(metrics: metrics, basis: basis)
        return CandidateSnapshot(
            network: NetworkIdentity(ssid: ssid),
            rssi: series.rssi.mean ?? -70,
            score: score,
            isKnownSaved: true,
            firstObservedAt: at(-600),
            lastObservedAt: at(0),
            isInternetReachable: reachable
        )
    }
}
