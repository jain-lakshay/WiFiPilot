import XCTest
@testable import WiFiPilotCore

/// Decision engine tests: hysteresis, cooldown, traffic protection, emergencies,
/// manual overrides and recovery. All driven by simulated data and a fake clock.
final class DecisionEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private var severeSeries: NetworkSimulation.Series {
        NetworkSimulation.Series(
            name: "Severe congestion",
            throughputMbps: [4, 6, 5, 3, 6, 5],
            latencyMs: [190, 240, 210, 260, 200, 230],
            jitterMs: [70, 90, 80, 95, 75, 85],
            packetLossPercent: [4, 6, 5, 7, 4, 5],
            rssi: [-83, -85, -82, -86, -84, -83]
        )
    }

    /// Clearly degraded but not dead: should be abandoned once a better option qualifies.
    private var degradedSeries: NetworkSimulation.Series {
        NetworkSimulation.Series(
            name: "Degraded",
            throughputMbps: [8, 9, 7, 10, 8, 7, 9, 8, 8],
            latencyMs: [125, 140, 130, 150, 135, 128, 145, 132, 130],
            jitterMs: [50, 58, 52, 62, 55, 51, 60, 53, 54],
            packetLossPercent: [3, 4, 3.5, 4, 3.5, 3, 3.5, 3, 3],
            rssi: [-78, -79, -77, -80, -78, -77, -79, -78, -78]
        )
    }

    /// Only a few points better than `degradedSeries` — not worth the interruption.
    private var slightlyBetterSeries: NetworkSimulation.Series {
        NetworkSimulation.Series(
            name: "Slightly better",
            throughputMbps: [11, 13, 10, 14, 12, 11, 13, 12, 12],
            latencyMs: [105, 120, 110, 125, 112, 108, 118, 112, 110],
            jitterMs: [42, 48, 44, 52, 46, 43, 50, 45, 44],
            packetLossPercent: [2.5, 3, 2.5, 3, 2.5, 2, 3, 2.5, 2.5],
            rssi: [-74, -75, -73, -76, -74, -73, -75, -74, -74]
        )
    }

    private func snapshot(
        _ ssid: String,
        _ series: NetworkSimulation.Series,
        basis: ScoreBasis,
        reachable: Bool? = nil,
        knownSaved: Bool = true,
        preferred: Bool = false,
        avoided: Bool = false,
        neverAutoJoin: Bool = false,
        available: Bool = true,
        rssiStandardDeviation: Double? = nil,
        weights: ScoringWeights = .standard,
        at date: Date
    ) -> CandidateSnapshot {
        let scoring = NetworkScoringEngine(weights: weights)
        let metrics = NetworkSimulation.metrics(from: series)
        let score = scoring.score(metrics: metrics, basis: basis)
        return CandidateSnapshot(
            network: NetworkIdentity(ssid: ssid),
            rssi: series.rssi.mean ?? -70,
            rssiStandardDeviation: rssiStandardDeviation ?? series.rssi.standardDeviation,
            score: score,
            isKnownSaved: knownSaved,
            isPreferred: preferred,
            isAvoided: avoided,
            isNeverAutoJoin: neverAutoJoin,
            isAvailable: available,
            firstObservedAt: date.addingTimeInterval(-600),
            lastObservedAt: date,
            historicalReliability: nil,
            isInternetReachable: reachable
        )
    }

    private func current() -> CandidateSnapshot {
        snapshot("WeakNet", severeSeries, basis: .live, reachable: true, at: t0)
    }

    private func goodCandidate() -> CandidateSnapshot {
        snapshot("GoodNet", NetworkSimulation.strongFiveGHz, basis: .historical, at: t0)
    }

    @discardableResult
    private func evaluate(
        _ engine: inout DecisionEngine,
        current: CandidateSnapshot?,
        candidates: [CandidateSnapshot],
        mode: AutomationMode = .auto,
        at now: Date,
        policy: SwitchingPolicy = .standard,
        pauseUntil: Date? = nil,
        traffic: TrafficAssessment = .idle
    ) -> AutomatedDecision {
        engine.evaluate(
            DecisionInput(
                current: current,
                candidates: candidates,
                mode: mode,
                pauseUntil: pauseUntil,
                activeTraffic: traffic,
                policy: policy
            ),
            at: now
        )
    }

    // MARK: - Basics

    func testFixtureScoresHaveExpectedSeparation() {
        let weak = current().score.total
        let good = goodCandidate().score.total
        XCTAssertLessThan(weak, SwitchingPolicy.standard.degradationScoreThreshold)
        XCTAssertGreaterThan(good, SwitchingPolicy.standard.degradationScoreThreshold)
        XCTAssertGreaterThan(good - weak, SwitchingPolicy.standard.minimumScoreAdvantage)
    }

    func testAutomationOffDoesNothing() {
        var engine = DecisionEngine()
        let decision = evaluate(&engine, current: current(), candidates: [goodCandidate()], mode: .off, at: t0.addingTimeInterval(60))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .automationOff)
    }

    func testManualPauseWinsOverEverything() {
        var engine = DecisionEngine()
        let decision = evaluate(
            &engine,
            current: current(),
            candidates: [goodCandidate()],
            at: t0.addingTimeInterval(60),
            pauseUntil: t0.addingTimeInterval(600)
        )
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .manuallyPaused)
    }

    func testNotConnected() {
        var engine = DecisionEngine()
        let decision = evaluate(&engine, current: nil, candidates: [goodCandidate()], at: t0)
        XCTAssertEqual(decision.reason.code, .noCurrentConnection)
    }

    func testNoEligibleCandidatesWhenNothingElseIsSaved() {
        var engine = DecisionEngine()
        let unsaved = snapshot("Cafe", NetworkSimulation.strongFiveGHz, basis: .signalOnly, knownSaved: false, at: t0)
        let decision = evaluate(&engine, current: current(), candidates: [unsaved], at: t0.addingTimeInterval(60))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .noEligibleCandidates)
        XCTAssertTrue(decision.notes.contains { $0.contains("not a saved network") })
    }

    func testAvoidedNetworkIsExcluded() {
        var engine = DecisionEngine()
        let avoided = snapshot("Avoided", NetworkSimulation.strongFiveGHz, basis: .historical, avoided: true, at: t0)
        let decision = evaluate(&engine, current: current(), candidates: [avoided], at: t0.addingTimeInterval(60))
        XCTAssertEqual(decision.reason.code, .noEligibleCandidates)
        XCTAssertTrue(decision.notes.contains { $0.contains("avoided") })
    }

    func testNeverAutoJoinNetworkIsExcluded() {
        var engine = DecisionEngine()
        let manual = snapshot("ManualOnly", NetworkSimulation.strongFiveGHz, basis: .historical, neverAutoJoin: true, at: t0)
        let decision = evaluate(&engine, current: current(), candidates: [manual], at: t0.addingTimeInterval(60))
        XCTAssertEqual(decision.reason.code, .noEligibleCandidates)
        XCTAssertTrue(decision.notes.contains { $0.contains("never auto-join") })
    }

    // MARK: - Hysteresis and qualification

    func testDegradationMustBeSustained() {
        var engine = DecisionEngine()
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0)
        let decision = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(5))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .degradationNotSustained)
    }

    func testCandidateMustQualify() {
        var engine = DecisionEngine()
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0)
        let decision = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(12))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .candidateNotQualified)
    }

    func testSwitchesAfterSustainedDegradationAndQualification() {
        var engine = DecisionEngine()
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0)
        let decision = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(20))
        XCTAssertEqual(decision.action, .switchNetwork)
        XCTAssertEqual(decision.target?.ssid, "GoodNet")
        XCTAssertEqual(decision.reason.code, .qualifiedImprovement)
        XCTAssertNotNil(decision.comparison)
        XCTAssertGreaterThan(decision.comparison?.advantage ?? 0, 0)
    }

    func testHealthyNetworkIsNotAbandonedForMarginalGain() {
        var engine = DecisionEngine()
        let healthy = snapshot("StrongNet", NetworkSimulation.strongFiveGHz, basis: .live, reachable: true, at: t0)
        let marginal = snapshot("Steady45", NetworkSimulation.steadyFortyFive, basis: .historical, at: t0)
        _ = evaluate(&engine, current: healthy, candidates: [marginal], at: t0)
        let decision = evaluate(&engine, current: healthy, candidates: [marginal], at: t0.addingTimeInterval(120))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .currentNetworkHealthy)
    }

    func testMarginalAdvantageIsRejected() {
        let degraded = snapshot("Degraded", degradedSeries, basis: .live, reachable: true, at: t0)
        let marginallyBetter = snapshot("SlightlyBetter", slightlyBetterSeries, basis: .historical, at: t0)
        let advantage = marginallyBetter.score.total - degraded.score.total

        XCTAssertLessThan(degraded.score.total, SwitchingPolicy.standard.degradationScoreThreshold)
        XCTAssertGreaterThan(advantage, 0, "fixture must actually be better")
        XCTAssertLessThan(advantage, SwitchingPolicy.standard.minimumScoreAdvantage)

        var engine = DecisionEngine()
        _ = evaluate(&engine, current: degraded, candidates: [marginallyBetter], at: t0)
        let decision = evaluate(&engine, current: degraded, candidates: [marginallyBetter], at: t0.addingTimeInterval(120))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .insufficientAdvantage)
    }

    func testLowQualityCandidateIsRejected() {
        var engine = DecisionEngine()
        var policy = SwitchingPolicy.standard
        policy.minimumCandidateScore = 100
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0, policy: policy)
        let decision = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(120), policy: policy)
        XCTAssertEqual(decision.reason.code, .candidateLowQuality)
    }

    func testUnstableSignalOnlyCandidateIsRejected() {
        var engine = DecisionEngine()
        let unstable = snapshot(
            "Flaky",
            NetworkSimulation.strongFiveGHz,
            basis: .signalOnly,
            rssiStandardDeviation: 9,
            at: t0
        )
        _ = evaluate(&engine, current: current(), candidates: [unstable], at: t0)
        let decision = evaluate(&engine, current: current(), candidates: [unstable], at: t0.addingTimeInterval(120))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .candidateSignalUnstable)
    }

    // MARK: - Cooldown and manual protection

    func testCooldownBlocksRapidSwitching() {
        var engine = DecisionEngine()
        engine.recordAutomatedSwitch(to: NetworkIdentity(ssid: "GoodNet"), at: t0)

        let duringCooldown = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(30))
        XCTAssertEqual(duringCooldown.reason.code, .cooldownActive)

        // Cooldown expires at t0+120; a fresh degradation window then applies.
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(145))
        let afterCooldown = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(160))
        XCTAssertEqual(afterCooldown.action, .switchNetwork)
    }

    func testFailedSwitchStartsCooldown() {
        var engine = DecisionEngine()
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0)
        engine.recordFailedSwitch(at: t0.addingTimeInterval(20))
        let retry = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(40))
        XCTAssertEqual(retry.action, .stay)
        XCTAssertEqual(retry.reason.code, .cooldownActive)
    }

    func testManualSwitchIsRespected() {
        var engine = DecisionEngine()
        var policy = SwitchingPolicy.standard
        policy.cooldownDuration = 10
        policy.manualSwitchProtection = 300
        engine.recordManualSwitch(to: NetworkIdentity(ssid: "ChosenByUser"), at: t0)

        let decision = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(60), policy: policy)
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .manualSwitchProtection)
    }

    // MARK: - Active traffic protection

    func testActiveTrafficRaisesTheSwitchingBar() {
        var policy = SwitchingPolicy.standard
        policy.minimumScoreAdvantage = 10
        policy.activeTrafficAdvantageBonus = 60

        var quietEngine = DecisionEngine(policy: policy)
        _ = evaluate(&quietEngine, current: current(), candidates: [goodCandidate()], at: t0, policy: policy)
        let quiet = evaluate(&quietEngine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(60), policy: policy)
        XCTAssertEqual(quiet.action, .switchNetwork)

        let traffic = TrafficAssessment(
            isActive: true,
            incomingMbps: 42,
            outgoingMbps: 3,
            windowSeconds: 5,
            reason: "Active transfer at 45.0 Mbps"
        )
        var busyEngine = DecisionEngine(policy: policy)
        _ = evaluate(&busyEngine, current: current(), candidates: [goodCandidate()], at: t0, policy: policy, traffic: traffic)
        let busy = evaluate(&busyEngine, current: current(), candidates: [goodCandidate()], at: t0.addingTimeInterval(60), policy: policy, traffic: traffic)
        XCTAssertEqual(busy.action, .stay)
        XCTAssertEqual(busy.reason.code, .activeTrafficProtection)
    }

    func testActiveTrafficStillAllowsEmergencySwitch() {
        var engine = DecisionEngine()
        let dead = snapshot("DeadNet", NetworkSimulation.noInternet, basis: .live, reachable: false, at: t0)
        let traffic = TrafficAssessment(isActive: true, incomingMbps: 80, outgoingMbps: 5, windowSeconds: 5, reason: "Active transfer")
        let decision = evaluate(&engine, current: dead, candidates: [goodCandidate()], at: t0, traffic: traffic)
        XCTAssertEqual(decision.action, .switchNetwork)
        XCTAssertEqual(decision.reason.code, .emergencySwitch)
    }

    // MARK: - Emergency and verification

    func testNoInternetTriggersImmediateEmergencySwitch() {
        var engine = DecisionEngine()
        let dead = snapshot("DeadNet", NetworkSimulation.noInternet, basis: .live, reachable: false, at: t0)
        let decision = evaluate(&engine, current: dead, candidates: [goodCandidate()], at: t0)
        XCTAssertEqual(decision.action, .switchNetwork)
        XCTAssertEqual(decision.reason.code, .emergencySwitch)
        XCTAssertEqual(decision.target?.ssid, "GoodNet")
    }

    func testEmergencyRequiresABetterCandidate() {
        var engine = DecisionEngine()
        let dead = snapshot("DeadNet", NetworkSimulation.noInternet, basis: .live, reachable: false, at: t0)
        let alsoBad = snapshot("AlsoBad", NetworkSimulation.noInternet, basis: .historical, reachable: false, at: t0)
        let decision = evaluate(&engine, current: dead, candidates: [alsoBad], at: t0)
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .insufficientAdvantage)
    }

    func testFailedSwitchProducesRecoveryDecision() {
        var engine = DecisionEngine()
        let failed = NetworkIdentity(ssid: "GoodNet")
        let previous = NetworkIdentity(ssid: "WeakNet")
        let recovery = engine.recoveryDecision(failedNetwork: failed, previous: previous, at: t0.addingTimeInterval(40))
        XCTAssertEqual(recovery?.action, .revertToPrevious)
        XCTAssertEqual(recovery?.target?.ssid, "WeakNet")
        XCTAssertEqual(recovery?.reason.code, .recoveryToPrevious)

        let none = engine.recoveryDecision(failedNetwork: failed, previous: nil, at: t0)
        XCTAssertNil(none)

        let same = engine.recoveryDecision(failedNetwork: failed, previous: failed, at: t0)
        XCTAssertNil(same, "Reverting to the network that just failed is pointless")
    }

    func testVerificationOutcomeIsRecorded() {
        var engine = DecisionEngine()
        let ok = engine.verificationDecision(target: NetworkIdentity(ssid: "GoodNet"), succeeded: true, detail: "Latency 12 ms", at: t0)
        XCTAssertEqual(ok.reason.code, .switchVerificationSucceeded)

        let failed = engine.verificationDecision(target: NetworkIdentity(ssid: "GoodNet"), succeeded: false, detail: "No reachability", at: t0)
        XCTAssertEqual(failed.reason.code, .switchVerificationFailed)
    }

    // MARK: - Observe mode

    func testObserveModeRecordsHypotheticalDecisionOnly() {
        var engine = DecisionEngine()
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], mode: .observe, at: t0)
        let hypothetical = evaluate(&engine, current: current(), candidates: [goodCandidate()], mode: .observe, at: t0.addingTimeInterval(60))
        XCTAssertEqual(hypothetical.action, .wouldSwitch)
        XCTAssertEqual(hypothetical.reason.code, .observingWouldSwitch)
        XCTAssertEqual(hypothetical.target?.ssid, "GoodNet")
        XCTAssertTrue(hypothetical.isHypothetical)

        let stillHypothetical = evaluate(&engine, current: current(), candidates: [goodCandidate()], mode: .observe, at: t0.addingTimeInterval(600))
        XCTAssertEqual(stillHypothetical.action, .wouldSwitch)
    }

    // MARK: - No unnecessary switching

    func testNoSwitchWhenOnlyCurrentNetworkIsVisible() {
        var engine = DecisionEngine()
        let decision = evaluate(&engine, current: current(), candidates: [current()], at: t0.addingTimeInterval(120))
        XCTAssertEqual(decision.action, .stay)
        XCTAssertEqual(decision.reason.code, .noEligibleCandidates)
    }

    func testPreferredNetworkTieBreak() {
        let a = snapshot("A", NetworkSimulation.strongFiveGHz, basis: .historical, at: t0)
        var b = snapshot("B", NetworkSimulation.strongFiveGHz, basis: .historical, at: t0)
        b.isPreferred = true
        XCTAssertTrue(
            DecisionEngine.preferredOrder(a, b),
            "On equal scores the preferred network must sort higher (last)"
        )
    }

    func testPolicySanitizationClampsHostileValues() {
        var policy = SwitchingPolicy.standard
        policy.observationWindow = -5
        policy.minimumScoreAdvantage = 500
        policy.cooldownDuration = .nan
        policy.maximumCandidateSignalVariation = 0
        let sanitized = policy.sanitized()
        XCTAssertGreaterThanOrEqual(sanitized.observationWindow, 15)
        XCTAssertLessThanOrEqual(sanitized.minimumScoreAdvantage, 60)
        XCTAssertGreaterThanOrEqual(sanitized.cooldownDuration, 0)
        XCTAssertGreaterThanOrEqual(sanitized.maximumCandidateSignalVariation, 0.5)
    }

    // MARK: - Engine bookkeeping

    func testNetworkChangeResetsDegradationTimer() {
        var engine = DecisionEngine()
        _ = evaluate(&engine, current: current(), candidates: [goodCandidate()], at: t0)
        engine.noteConnection(NetworkIdentity(ssid: "Other"), at: t0.addingTimeInterval(6))
        XCTAssertEqual(engine.degradationElapsed(at: t0.addingTimeInterval(6)), 0)
    }

    func testCooldownRemainingIsReported() {
        var engine = DecisionEngine()
        engine.recordAutomatedSwitch(to: NetworkIdentity(ssid: "X"), at: t0)
        XCTAssertEqual(engine.cooldownRemaining(at: t0.addingTimeInterval(20)), 100, accuracy: 0.001)
        XCTAssertEqual(engine.cooldownRemaining(at: t0.addingTimeInterval(200)), 0, accuracy: 0.001)
    }
}
