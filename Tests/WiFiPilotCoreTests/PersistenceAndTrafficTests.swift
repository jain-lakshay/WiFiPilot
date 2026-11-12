import XCTest
@testable import WiFiPilotCore

final class PersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wifipilot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSettingsAndHistoryRoundTrip() async throws {
        let store = PersistenceStore(directory: directory)
        var settings = AppSettings.default
        settings.automationMode = .auto
        settings.preferredNetworks = ["Home", "home", "Office"]
        settings.avoidedNetworks = ["Cafe"]
        settings.policy.minimumScoreAdvantage = 18
        await store.updateSettings(settings)

        let decision = AutomatedDecision(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            action: .switchNetwork,
            target: NetworkIdentity(ssid: "Office"),
            reason: DecisionReason(code: .qualifiedImprovement, title: "Switched", detail: "Better stability"),
            comparison: nil,
            currentNetwork: NetworkIdentity(ssid: "Home"),
            mode: .auto
        )
        await store.record(DecisionRecord(decision: decision))
        await store.append(
            sample: TimelineSample(
                timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                network: "Office",
                rssi: -52,
                latencyMs: 14,
                jitterMs: 2,
                packetLossPercent: 0,
                throughputMbps: 180
            )
        )
        try await store.save()

        let reopened = PersistenceStore(directory: directory)
        let history = await reopened.snapshot()
        XCTAssertEqual(history.schemaVersion, StoredHistory.currentSchemaVersion)
        XCTAssertEqual(history.settings.automationMode, .auto)
        XCTAssertEqual(history.settings.preferredNetworks, ["Home", "Office"], "duplicate SSIDs are collapsed")
        XCTAssertEqual(history.settings.policy.minimumScoreAdvantage, 18)
        XCTAssertEqual(history.decisions.count, 1)
        XCTAssertEqual(history.decisions.first?.action, .switchNetwork)
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.rssi, -52)
    }

    func testProfilesTrackReliability() async throws {
        let store = PersistenceStore(directory: directory)
        var profile = NetworkProfile(
            identity: NetworkIdentity(ssid: "Home"),
            isKnownSaved: true,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        profile.connectionCount = 4
        profile.successfulVerifications = 3
        profile.failedVerifications = 1
        profile.disconnections = 1
        await store.upsert(profile: profile)

        let reloaded = await store.profile(forSSID: "home")
        XCTAssertEqual(reloaded?.ssid, "Home")
        let reliability = try XCTUnwrap(reloaded?.reliability)
        XCTAssertGreaterThan(reliability, 0)
        XCTAssertLessThan(reliability, 1)
    }

    func testRetentionPruning() async throws {
        let store = PersistenceStore(directory: directory)
        let old = Date().addingTimeInterval(-40 * 86_400)
        let recent = Date()
        var settings = AppSettings.default
        settings.historyRetentionDays = 30
        await store.updateSettings(settings)

        let oldDecision = AutomatedDecision(timestamp: old, action: .stay, reason: DecisionReason(code: .currentNetworkHealthy, title: "Stay", detail: "Fine"), mode: .observe)
        let newDecision = AutomatedDecision(timestamp: recent, action: .stay, reason: DecisionReason(code: .currentNetworkHealthy, title: "Stay", detail: "Fine"), mode: .observe)
        await store.record(DecisionRecord(decision: oldDecision))
        await store.record(DecisionRecord(decision: newDecision))
        await store.append(sample: TimelineSample(timestamp: old, network: "Old"))
        await store.append(sample: TimelineSample(timestamp: recent, network: "New"))

        await store.prune(now: recent)
        let history = await store.snapshot()
        XCTAssertEqual(history.decisions.count, 1)
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.network, "New")
    }

    func testVerificationOutcomeIsAttachedToDecision() async throws {
        let store = PersistenceStore(directory: directory)
        let decision = AutomatedDecision(
            timestamp: Date(),
            action: .switchNetwork,
            target: NetworkIdentity(ssid: "Office"),
            reason: DecisionReason(code: .qualifiedImprovement, title: "Switch", detail: "Better"),
            mode: .auto
        )
        let entry = DecisionRecord(decision: decision)
        await store.record(entry)
        XCTAssertNil(entry.switchSucceeded)

        await store.updateVerification(recordID: entry.id, succeeded: true, detail: "verified in 12 ms")
        let recent = await store.recentDecisions()
        XCTAssertEqual(recent.first?.switchSucceeded, true)
        XCTAssertEqual(recent.first?.verificationDetail, "verified in 12 ms")
    }

    func testCorruptFileIsQuarantinedNotFatal() async throws {
        let url = directory.appendingPathComponent(PersistenceStore.fileName)
        try Data("not json at all".utf8).write(to: url)
        let store = PersistenceStore(directory: directory)
        let history = await store.snapshot()
        XCTAssertTrue(history.decisions.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt") })
    }

    func testTimelineSampleIdentifiable() {
        let sample = TimelineSample(timestamp: Date(), network: "Home")
        XCTAssertFalse(sample.id.uuidString.isEmpty)
    }
}

final class TrafficTests: XCTestCase {
    func testQuietInterfaceIsNotActive() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = InterfaceCounters(receivedBytes: 1_000_000, sentBytes: 500_000, timestamp: start)
        let current = InterfaceCounters(receivedBytes: 1_100_000, sentBytes: 520_000, timestamp: start.addingTimeInterval(5))

        let assessment = TrafficAnalysis.assess(previous: previous, current: current, thresholdMbps: 2)
        XCTAssertFalse(assessment.isActive)
        XCTAssertLessThan(assessment.totalMbps, 1)
    }

    func testLargeTransferIsActive() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = InterfaceCounters(receivedBytes: 1_000_000, sentBytes: 500_000, timestamp: start)
        // 100 MB over 5 s ≈ 160 Mbps.
        let current = InterfaceCounters(
            receivedBytes: 1_000_000 + 100_000_000,
            sentBytes: 500_000,
            timestamp: start.addingTimeInterval(5)
        )

        let assessment = TrafficAnalysis.assess(previous: previous, current: current, thresholdMbps: 2)
        XCTAssertTrue(assessment.isActive)
        XCTAssertGreaterThan(assessment.incomingMbps, 150)
        XCTAssertTrue(assessment.reason.contains("Active transfer"))
    }

    func testCounterResetDoesNotProduceBogusSpike() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = InterfaceCounters(receivedBytes: 9_000_000_000, sentBytes: 9_000_000_000, timestamp: start)
        let current = InterfaceCounters(receivedBytes: 1_000, sentBytes: 1_000, timestamp: start.addingTimeInterval(2))

        let assessment = TrafficAnalysis.assess(previous: previous, current: current, thresholdMbps: 2)
        XCTAssertFalse(assessment.isActive)
        XCTAssertEqual(assessment.totalMbps, 0, accuracy: 0.0001)
    }

    func testFirstSampleIsNotActive() {
        let assessment = TrafficAnalysis.assess(
            previous: nil,
            current: InterfaceCounters(receivedBytes: 1, sentBytes: 1, timestamp: Date()),
            thresholdMbps: 2
        )
        XCTAssertFalse(assessment.isActive)
        XCTAssertTrue(assessment.reason.contains("Collecting"))
    }
}
