import CoreLocation
import Foundation
import Observation
import WiFiPilotCore

/// Application state and orchestration.
///
/// Owns the monitoring loop: read the association, scan nearby networks, probe the
/// connection, evaluate the decision engine, act, and record everything. All UI state
/// is published here; the views contain no networking logic.
@MainActor
@Observable
final class AppState {
    // MARK: - Published UI state

    private(set) var link: WiFiLink?
    private(set) var currentMetrics: NetworkMetrics = .empty
    private(set) var currentScore: ScoreBreakdown = .unavailable
    private(set) var discovered: [DiscoveredNetwork] = []
    private(set) var rows: [NetworkRow] = []
    private(set) var decisions: [DecisionRecord] = []
    private(set) var timeline: [TimelineSample] = []
    private(set) var lastDecision: AutomatedDecision?
    private(set) var activeTraffic: TrafficAssessment = .idle
    private(set) var settings: AppSettings = .default
    private(set) var pauseUntil: Date?
    private(set) var isScanning = false
    private(set) var isRunning = false
    private(set) var isSwitching = false
    private(set) var statusMessage = "Starting up"
    /// Human-readable state of the optional, approximate throughput measurement.
    private(set) var throughputStatus: String?
    private(set) var lastError: String?
    private(set) var lastScanAt: Date?
    private(set) var launchAtLoginStatus = LaunchAtLogin.statusDescription
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined

    let locationPermission = LocationPermission()
    let networkMonitor = NetworkMonitor()
    let scanner = WiFiScanner()

    // MARK: - Services

    private let store: PersistenceStore
    private let logger: DecisionLogger
    private let healthMonitor: ConnectionHealthMonitor
    private let trafficMonitor = TrafficMonitor()
    private let switcher = SwitchingManager()

    // MARK: - Internal state

    private var engine = DecisionEngine()
    private var profiles: [String: NetworkProfile] = [:]
    private var signalWindows: [String: SampleWindow] = [:]
    private var loopTask: Task<Void, Never>?
    private var lastLoggedSignature: String?
    private var lastLoggedAt: Date?
    private var lastSampleAt: Date?
    private var lastThroughputAttemptAt: Date?
    private var lastThroughputFailureAt: Date?
    private var lastPruneAt: Date?

    init() {
        let store = PersistenceStore()
        self.store = store
        self.logger = DecisionLogger(store: store)
        self.healthMonitor = ConnectionHealthMonitor(
            windowDuration: SwitchingPolicy.standard.observationWindow
        )
    }

    // MARK: - Derived UI values

    var mode: AutomationMode { settings.automationMode }

    var isPaused: Bool {
        guard let pauseUntil else { return false }
        return pauseUntil > Date()
    }

    var isConnected: Bool { link != nil }

    var menuBarTitle: String {
        link?.identity.displayName ?? "Wi-Fi"
    }

    var menuBarSymbol: String {
        guard let link else { return "wifi.slash" }
        switch SignalQuality.normalized(rssi: Double(link.rssi)) {
        case 0.75...: return "wifi"
        case 0.45..<0.75: return "wifi"
        case 0.2..<0.45: return "wifi.exclamationmark"
        default: return "wifi.exclamationmark"
        }
    }

    var healthDescription: String {
        guard let link else { return "Not connected" }
        if let connectivity = currentMetrics.connectivity, !connectivity.isVerifiedInternet {
            return "\(connectivity.classification.displayName) · \(currentScore.summary)"
        }
        if currentMetrics.internetReachable == false { return "No internet" }
        if isPaused { return "Paused · \(currentScore.summary)" }
        return "\(SignalQuality.description(rssi: Double(link.rssi))) · \(currentScore.summary)"
    }

    /// Engine-level reachability. Only a genuinely failed connection counts as "no
    /// internet" for the emergency override. A captive portal is reported to the user and
    /// capped in scoring, but switching networks cannot remove the portal itself.
    private var engineReachability: Bool? {
        guard let connectivity = currentMetrics.connectivity else {
            return currentMetrics.internetReachable
        }
        switch connectivity.classification {
        case .verifiedOpen, .captivePortal:
            return true
        case .restricted, .dnsFailure, .offline, .unverified:
            return false
        }
    }

    var scoreText: String {
        guard currentScore.basis != .signalOnly || currentScore.total > 0 else { return "—" }
        return String(format: "%.0f", currentScore.total)
    }

    var pauseRemainingText: String? {
        guard let pauseUntil, pauseUntil > Date() else { return nil }
        let remaining = Int(pauseUntil.timeIntervalSinceNow)
        if remaining >= 3600 {
            return "Paused for \(remaining / 3600) h \((remaining % 3600) / 60) m"
        }
        return "Paused for \(max(0, remaining / 60)) m"
    }

    var bestAlternative: NetworkRow? {
        rows.first { !$0.isConnected }
    }

    var locationStatusText: String { locationPermission.statusDescription }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = "Loading settings"

        let snapshot = await store.snapshot()
        settings = snapshot.settings.sanitized()
        engine = DecisionEngine(policy: settings.policy)
        await healthMonitor.updateWindow(settings.policy.observationWindow)
        profiles = snapshot.profiles
        decisions = Array(snapshot.decisions.suffix(200).reversed())
        timeline = Array(snapshot.samples.suffix(900))
        launchAtLoginStatus = LaunchAtLogin.statusDescription
        locationPermission.request()
        locationStatus = locationPermission.status

        if settings.notificationsEnabled {
            await LocalNotifications.requestAuthorizationIfNeeded()
        }
        await store.prune()

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await tick()
            let interval = max(2, settings.probeIntervalSeconds)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func tick() async {
        let now = Date()
        locationStatus = locationPermission.status
        await refreshLink(now: now)
        await maybeScan(now: now)
        await measure(now: now)
        await evaluateAndAct(now: now)
        await persistSampleIfNeeded(now: now)
    }

    // MARK: - Monitoring

    private func refreshLink(now: Date) async {
        let current = await scanner.currentLink()
        if let current {
            if link?.identity.networkKey != current.identity.networkKey {
                await healthMonitor.start(network: current.identity, at: now)
                engine.noteConnection(current.identity, at: now)
                await recordAssociation(current.identity, at: now)
            }
            await healthMonitor.recordSignal(rssi: current.rssi, at: now)
            statusMessage = "Connected to \(current.identity.displayName)"
        } else if link != nil {
            await healthMonitor.recordDisconnection(at: now)
            engine.noteConnection(nil, at: now)
            statusMessage = "Wi-Fi disconnected"
        }
        link = current
    }

    private func maybeScan(now: Date) async {
        if let lastScanAt, now.timeIntervalSince(lastScanAt) < 15 { return }
        await performScan(now: now)
    }

    func performScan(now: Date = Date()) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        await scanner.refreshKnownNetworks()

        do {
            let results = try await scanner.scan()
            discovered = results
            lastScanAt = now
            lastError = nil
            var visibleKeys = Set<String>()
            for network in results {
                visibleKeys.insert(network.identity.networkKey)
                signalWindows[network.identity.networkKey, default: SampleWindow(duration: 300, capacity: 240)]
                    .add(Double(network.rssi), at: now)
                await touchProfile(for: network, at: now)
            }
            signalWindows = signalWindows.filter { visibleKeys.contains($0.key) || now.timeIntervalSince($0.value.latestTimestamp ?? .distantPast) < 600 }
            rebuildRows(now: now)
            if results.isEmpty {
                statusMessage = locationPermission.isAuthorized
                    ? "No networks visible"
                    : "Scan returned nothing — Location permission is required for Wi-Fi scanning"
            } else {
                statusMessage = "\(results.count) networks visible"
            }
        } catch {
            lastScanAt = now
            lastError = error.localizedDescription
            statusMessage = "Scan failed"
            rebuildRows(now: now)
        }
    }

    private func measure(now: Date) async {
        // Sample user traffic first: an in-progress transfer must both protect switching
        // and defer any controlled throughput download.
        if settings.activeTrafficProtectionEnabled {
            let interfaceName = await scanner.interfaceName
            activeTraffic = trafficMonitor.sample(
                interfaceName: interfaceName,
                thresholdMbps: settings.policy.activeTrafficThresholdMbps
            )
        } else {
            activeTraffic = .idle
        }

        // The policy owns bandwidth discipline: enabled? connected? user idle? rate
        // limited? backing off after a failure? A 250 KB sample every 90 s stays around
        // 10 MB/hour, which is why the sample count is small and the window is 5 minutes.
        let throughputPolicy = settings.throughputPolicy
        let throughputDecision = throughputPolicy.assess(
            now: now,
            isConnected: link != nil,
            traffic: activeTraffic,
            lastAttemptAt: lastThroughputAttemptAt,
            lastFailureAt: lastThroughputFailureAt
        )
        if throughputDecision.shouldProbe {
            lastThroughputAttemptAt = now
        }
        throughputStatus = throughputDecision.detail

        let round = await networkMonitor.probe(
            includeThroughput: throughputDecision.shouldProbe,
            throughputPolicy: throughputPolicy
        )
        if throughputDecision.shouldProbe, round.throughput.failureReason != nil {
            lastThroughputFailureAt = now
        }

        let (_, metrics) = await healthMonitor.ingest(
            round,
            rssi: link?.rssi,
            network: link?.identity,
            at: now
        )
        currentMetrics = metrics
        currentScore = NetworkScoringEngine(weights: settings.policy.scoringWeights)
            .score(metrics: metrics, basis: .live)
    }

    // MARK: - Decision flow

    private func evaluateAndAct(now: Date) async {
        // Never act on an unmeasured connection: without at least one probe round the
        // score is a neutral placeholder, not evidence.
        guard currentMetrics.sampleCount > 0 else { return }
        rebuildRows(now: now)
        let snapshots = buildSnapshots(now: now)
        let input = DecisionInput(
            current: snapshots.current,
            candidates: snapshots.candidates,
            mode: settings.automationMode,
            pauseUntil: pauseUntil,
            activeTraffic: activeTraffic,
            policy: settings.policy
        )

        let decision = engine.evaluate(input, at: now)
        lastDecision = decision
        await logDecisionIfNeeded(decision, now: now)

        guard decision.action == .switchNetwork, settings.automationMode == .auto else { return }
        guard !isSwitching, !isPaused, let target = decision.target else { return }
        await performAutomaticSwitch(to: target, decision: decision)
    }

    private func buildSnapshots(now: Date) -> (current: CandidateSnapshot?, candidates: [CandidateSnapshot]) {
        let scoring = NetworkScoringEngine(weights: settings.policy.scoringWeights)

        var current: CandidateSnapshot?
        if let link {
            current = CandidateSnapshot(
                network: link.identity,
                rssi: Double(link.rssi),
                rssiStandardDeviation: currentMetrics.rssiStandardDeviation,
                score: currentScore,
                isKnownSaved: true,
                isPreferred: settings.isPreferred(link.identity.ssid),
                isAvailable: true,
                firstObservedAt: now,
                lastObservedAt: now,
                historicalReliability: profiles[link.identity.networkKey]?.reliability,
                isInternetReachable: engineReachability
            )
        }

        var candidates: [CandidateSnapshot] = []
        for network in discovered where network.identity.networkKey != link?.identity.networkKey {
            let profile = profiles[network.identity.networkKey]
            let window = signalWindows[network.identity.networkKey]
            let score: ScoreBreakdown
            if let metrics = profile?.lastMetrics, metrics.hasConnectionMeasurements {
                score = scoring.historicalScore(for: metrics, sampleCount: max(3, metrics.sampleCount))
            } else {
                score = scoring.signalOnlyScore(
                    rssi: Double(network.rssi),
                    rssiStandardDeviation: window?.standardDeviation,
                    historicalReliability: profile?.reliability
                )
            }
            candidates.append(
                CandidateSnapshot(
                    network: network.identity,
                    rssi: Double(network.rssi),
                    rssiStandardDeviation: window?.standardDeviation,
                    score: score,
                    isKnownSaved: network.isKnownSaved,
                    isPreferred: settings.isPreferred(network.identity.ssid),
                    isAvoided: settings.isAvoided(network.identity.ssid),
                    isNeverAutoJoin: settings.isNeverAutoJoin(network.identity.ssid),
                    isAvailable: true,
                    firstObservedAt: profile?.firstSeen ?? now,
                    lastObservedAt: now,
                    historicalReliability: profile?.reliability,
                    isInternetReachable: nil
                )
            )
        }
        return (current, candidates)
    }

    private func rebuildRows(now: Date) {
        let snapshots = buildSnapshots(now: now)
        var newRows: [NetworkRow] = []

        if let current = snapshots.current, let link {
            newRows.append(
                NetworkRow(
                    snapshot: current,
                    metrics: currentMetrics,
                    isConnected: true,
                    lastSeen: now,
                    channel: link.channel,
                    security: link.security,
                    band: link.band
                )
            )
        }

        for candidate in snapshots.candidates {
            guard let network = discovered.first(where: { $0.identity.networkKey == candidate.network.networkKey }) else { continue }
            newRows.append(
                NetworkRow(
                    snapshot: candidate,
                    metrics: profiles[candidate.network.networkKey]?.lastMetrics,
                    isConnected: false,
                    lastSeen: candidate.lastObservedAt,
                    channel: network.channel,
                    security: network.security,
                    band: network.band
                )
            )
        }

        newRows.sort { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.snapshot.score.total > rhs.snapshot.score.total
        }
        rows = newRows
    }

    private func logDecisionIfNeeded(_ decision: AutomatedDecision, now: Date) async {
        let signature = "\(decision.reason.code.rawValue)|\(decision.target?.networkKey ?? "-")"
        let isActionable = decision.action != .stay
        let changed = signature != lastLoggedSignature
        let cooledDown = lastLoggedAt.map { now.timeIntervalSince($0) > 30 } ?? true
        guard isActionable || (changed && cooledDown) else { return }

        lastLoggedSignature = signature
        lastLoggedAt = now
        let candidateMetrics = decision.target.flatMap { profiles[$0.networkKey]?.lastMetrics }
        let record = await logger.log(
            decision,
            currentMetrics: currentMetrics,
            candidateMetrics: candidateMetrics
        )
        decisions.insert(record, at: 0)
        if decisions.count > 200 { decisions.removeLast(decisions.count - 200) }
    }

    // MARK: - Switching

    private var internetVerifier: @Sendable () async -> Bool {
        let monitor = networkMonitor
        return { await monitor.verifyInternet() }
    }

    private func performAutomaticSwitch(to target: NetworkIdentity, decision: AutomatedDecision) async {
        isSwitching = true
        defer { isSwitching = false }

        let previous = link?.identity
        statusMessage = "Switching to \(target.displayName)…"
        let outcome = await switcher.performSwitch(
            to: target,
            scanner: scanner,
            verifier: internetVerifier
        )

        if outcome.success && outcome.verified {
            engine.recordAutomatedSwitch(to: target, at: Date())
            await logger.recordVerification(recordID: decision.id, succeeded: true, detail: outcome.detail)
            let updated = await logger.updateProfileAfterSwitch(
                profile: profiles[target.networkKey],
                identity: target,
                succeeded: true,
                at: Date()
            )
            profiles[target.networkKey] = updated
            statusMessage = "Switched to \(target.displayName)"
            if settings.notificationsEnabled {
                LocalNotifications.post(
                    title: "Switched to \(target.displayName)",
                    body: outcome.detail
                )
            }
        } else {
            engine.recordFailedSwitch(at: Date())
            await logger.recordVerification(recordID: decision.id, succeeded: false, detail: outcome.detail)
            let updated = await logger.updateProfileAfterSwitch(
                profile: profiles[target.networkKey],
                identity: target,
                succeeded: false,
                at: Date()
            )
            profiles[target.networkKey] = updated
            statusMessage = "Switch not successful: \(outcome.detail)"
            if settings.notificationsEnabled {
                LocalNotifications.post(
                    title: "Could not switch to \(target.displayName)",
                    body: outcome.detail
                )
            }
            await recoverIfPossible(previous: previous, failed: target)
        }

        trafficMonitor.reset()
        await performScan(now: Date())
    }

    private func recoverIfPossible(previous: NetworkIdentity?, failed: NetworkIdentity) async {
        guard let previous,
              let recovery = engine.recoveryDecision(failedNetwork: failed, previous: previous, at: Date()) else {
            return
        }
        lastDecision = recovery
        await logger.log(recovery, currentMetrics: currentMetrics, candidateMetrics: nil)
        let outcome = await switcher.performSwitch(
            to: previous,
            scanner: scanner,
            verifier: internetVerifier
        )
        await logger.recordVerification(
            recordID: recovery.id,
            succeeded: outcome.success && outcome.verified,
            detail: outcome.detail
        )
        statusMessage = outcome.success && outcome.verified
            ? "Recovered \(previous.displayName)"
            : "Recovery to \(previous.displayName) failed"
    }

    /// User-initiated join from the menu bar or dashboard.
    func selectNetwork(_ target: NetworkIdentity) async {
        guard !isSwitching, target.networkKey != link?.identity.networkKey else { return }
        isSwitching = true
        defer { isSwitching = false }

        let previous = link?.identity
        statusMessage = "Joining \(target.displayName)…"
        let outcome = await switcher.performSwitch(
            to: target,
            scanner: scanner,
            verifier: internetVerifier
        )

        if outcome.success && outcome.verified {
            engine.recordManualSwitch(to: target, at: Date())
            let manualDecision = AutomatedDecision(
                timestamp: Date(),
                action: .switchNetwork,
                target: target,
                reason: DecisionReason(
                    code: .qualifiedImprovement,
                    title: "Manual selection",
                    detail: "You selected \(target.displayName) manually. Automation will not override this choice for a while."
                ),
                currentNetwork: previous,
                mode: settings.automationMode
            )
            await logger.log(manualDecision, currentMetrics: currentMetrics, candidateMetrics: nil)
            statusMessage = "Joined \(target.displayName)"
            lastError = nil
        } else {
            statusMessage = "Could not join \(target.displayName)"
            lastError = outcome.detail
        }

        trafficMonitor.reset()
        await performScan(now: Date())
    }

    // MARK: - Controls

    func setMode(_ newMode: AutomationMode) {
        settings.automationMode = newMode
        if newMode == .off { pauseUntil = nil }
        persistSettings()
    }

    func pause(for duration: TimeInterval) {
        pauseUntil = Date().addingTimeInterval(duration)
        statusMessage = "Automation paused"
    }

    func resumeAutomation() {
        pauseUntil = nil
        statusMessage = "Automation resumed"
    }

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy.sanitized()
        persistSettings()
    }

    func togglePreferred(_ ssid: String) {
        updateSettings { settings in
            if settings.preferredNetworks.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
                settings.preferredNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
            } else {
                settings.preferredNetworks.append(ssid)
                settings.avoidedNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
            }
        }
    }

    func toggleAvoided(_ ssid: String) {
        updateSettings { settings in
            if settings.avoidedNetworks.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
                settings.avoidedNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
            } else {
                settings.avoidedNetworks.append(ssid)
                settings.preferredNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
            }
        }
    }

    func toggleNeverAutoJoin(_ ssid: String) {
        updateSettings { settings in
            if settings.neverAutoJoinNetworks.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
                settings.neverAutoJoinNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
            } else {
                settings.neverAutoJoinNetworks.append(ssid)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            settings.launchAtLogin = enabled
            launchAtLoginStatus = LaunchAtLogin.statusDescription
            lastError = nil
            persistSettings()
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
            launchAtLoginStatus = LaunchAtLogin.statusDescription
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        updateSettings { $0.notificationsEnabled = enabled }
        if enabled {
            Task { await LocalNotifications.requestAuthorizationIfNeeded() }
        }
    }

    func requestLocationAccess() {
        locationPermission.request()
        locationStatus = locationPermission.status
    }

    func openLocationSettings() {
        locationPermission.openSystemSettings()
    }

    func clearError() {
        lastError = nil
    }

    func pruneHistory() {
        Task { [logger, store] in
            await logger.prune()
            let snapshot = await store.snapshot()
            timeline = Array(snapshot.samples.suffix(900))
            decisions = Array(snapshot.decisions.suffix(200).reversed())
        }
        lastPruneAt = Date()
    }

    // MARK: - Persistence helpers

    private func persistSettings() {
        let sanitized = settings.sanitized()
        settings = sanitized
        engine.update(policy: sanitized.policy)
        Task { [store, healthMonitor] in
            await store.updateSettings(sanitized)
            try? await store.save()
            await healthMonitor.updateWindow(sanitized.policy.observationWindow)
        }
    }

    private func recordAssociation(_ identity: NetworkIdentity, at date: Date) async {
        var profile = profiles[identity.networkKey]
            ?? NetworkProfile(identity: identity, isKnownSaved: true, at: date)
        profile.lastSeen = date
        profile.lastBSSID = identity.bssid
        profile.connectionCount += 1
        profiles[identity.networkKey] = profile
        await store.upsert(profile: profile)
        try? await store.save()
    }

    private func touchProfile(for network: DiscoveredNetwork, at date: Date) async {
        var profile = profiles[network.identity.networkKey]
            ?? NetworkProfile(identity: network.identity, isKnownSaved: network.isKnownSaved, at: date)
        profile.lastSeen = date
        profile.lastBSSID = network.identity.bssid
        profile.isKnownSaved = network.isKnownSaved
        profiles[network.identity.networkKey] = profile
        await store.upsert(profile: profile)
    }

    private func persistSampleIfNeeded(now: Date) async {
        guard let link else { return }
        if let lastSampleAt, now.timeIntervalSince(lastSampleAt) < 10 { return }
        lastSampleAt = now

        let sample = TimelineSample(
            timestamp: now,
            network: link.identity.displayName,
            rssi: Double(link.rssi),
            latencyMs: currentMetrics.averageLatencyMs,
            jitterMs: currentMetrics.latencyJitterMs,
            packetLossPercent: currentMetrics.packetLossPercent,
            throughputMbps: currentMetrics.averageThroughputMbps
        )
        timeline.append(sample)
        if timeline.count > 900 { timeline.removeFirst(timeline.count - 900) }

        await store.append(sample: sample)

        // Keep the profile's last measurements so unconnected networks can be scored
        // from history (clearly labelled as historical in the UI).
        var profile = profiles[link.identity.networkKey]
            ?? NetworkProfile(identity: link.identity, isKnownSaved: true, at: now)
        profile.lastMetrics = currentMetrics
        profile.lastScore = currentScore.total
        profile.lastBasis = currentScore.basis
        profile.lastSeen = now
        if currentMetrics.disconnectionCount > 0 {
            profile.disconnections = currentMetrics.disconnectionCount
        }
        profiles[link.identity.networkKey] = profile
        await store.upsert(profile: profile)

        try? await store.save()

        // Retention pruning rewrites the whole file, so do it every 10 minutes at most.
        if lastPruneAt.map({ now.timeIntervalSince($0) >= 600 }) ?? true {
            lastPruneAt = now
            await store.prune(now: now)
        }
    }
}
