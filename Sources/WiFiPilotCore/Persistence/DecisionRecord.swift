import Foundation

/// One entry in the local decision log.
///
/// The log is the audit trail that makes the app trustworthy: it records what was
/// compared, what the numbers were, why switching happened or was refused, and
/// whether the switch verified. It never contains browsing data or payload content.
public struct DecisionRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var mode: AutomationMode
    public var action: DecisionAction
    public var currentNetwork: NetworkIdentity?
    public var candidateNetwork: NetworkIdentity?
    public var currentMetrics: NetworkMetrics?
    public var candidateMetrics: NetworkMetrics?
    public var comparison: ScoreComparison?
    public var reasonCode: String
    public var reasonTitle: String
    public var reasonDetail: String
    public var currentScore: Double?
    public var candidateScore: Double?
    public var activeTraffic: Bool
    public var notes: [String]
    public var switchAttempted: Bool
    public var switchSucceeded: Bool?
    public var verificationDetail: String?

    public init(
        decision: AutomatedDecision,
        currentMetrics: NetworkMetrics? = nil,
        candidateMetrics: NetworkMetrics? = nil
    ) {
        self.id = decision.id
        self.timestamp = decision.timestamp
        self.mode = decision.mode
        self.action = decision.action
        self.currentNetwork = decision.currentNetwork
        self.candidateNetwork = decision.target
        self.currentMetrics = currentMetrics
        self.candidateMetrics = candidateMetrics
        self.comparison = decision.comparison
        self.reasonCode = decision.reason.code.rawValue
        self.reasonTitle = decision.reason.title
        self.reasonDetail = decision.reason.detail
        self.currentScore = decision.comparison?.currentScore
        self.candidateScore = decision.comparison?.candidateScore
        self.activeTraffic = decision.activeTraffic.isActive
        self.notes = decision.notes
        self.switchAttempted = decision.action == .switchNetwork || decision.action == .revertToPrevious
        self.switchSucceeded = nil
        self.verificationDetail = nil
    }

    /// Whether this record represents a hypothetical decision recorded in OBSERVE mode.
    public var wasHypothetical: Bool { action == .wouldSwitch }

    public var title: String {
        switch action {
        case .switchNetwork: "Switched to \(candidateNetwork?.displayName ?? "unknown")"
        case .wouldSwitch: "Would switch to \(candidateNetwork?.displayName ?? "unknown")"
        case .revertToPrevious: "Reverted to \(candidateNetwork?.displayName ?? "previous network")"
        case .stay: reasonTitle
        }
    }
}

/// Persisted knowledge about a network across sessions.
///
/// This is what lets the app say "I remember this network was flaky" without
/// pretending to measure a network it is not connected to.
public struct NetworkProfile: Codable, Sendable, Identifiable, Equatable {
    public var networkKey: String
    public var ssid: String
    public var lastBSSID: String?
    public var isKnownSaved: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    public var connectionCount: Int
    public var successfulVerifications: Int
    public var failedVerifications: Int
    public var disconnections: Int
    public var lastMetrics: NetworkMetrics?
    public var lastScore: Double?
    public var lastBasis: ScoreBasis?

    public var id: String { networkKey }

    public var identity: NetworkIdentity { NetworkIdentity(ssid: ssid, bssid: lastBSSID) }

    public init(
        networkKey: String,
        ssid: String,
        lastBSSID: String? = nil,
        isKnownSaved: Bool = false,
        firstSeen: Date,
        lastSeen: Date,
        connectionCount: Int = 0,
        successfulVerifications: Int = 0,
        failedVerifications: Int = 0,
        disconnections: Int = 0,
        lastMetrics: NetworkMetrics? = nil,
        lastScore: Double? = nil,
        lastBasis: ScoreBasis? = nil
    ) {
        self.networkKey = networkKey
        self.ssid = ssid
        self.lastBSSID = lastBSSID
        self.isKnownSaved = isKnownSaved
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.connectionCount = connectionCount
        self.successfulVerifications = successfulVerifications
        self.failedVerifications = failedVerifications
        self.disconnections = disconnections
        self.lastMetrics = lastMetrics
        self.lastScore = lastScore
        self.lastBasis = lastBasis
    }

    public init(identity: NetworkIdentity, isKnownSaved: Bool, at date: Date) {
        self.init(
            networkKey: identity.networkKey,
            ssid: identity.ssid,
            lastBSSID: identity.bssid,
            isKnownSaved: isKnownSaved,
            firstSeen: date,
            lastSeen: date
        )
    }

    /// 0...1 reliability from verification history, nil when there is no evidence.
    public var reliability: Double? {
        let attempts = successfulVerifications + failedVerifications
        guard attempts > 0 else { return nil }
        var ratio = Double(successfulVerifications) / Double(attempts)
        // Penalise repeated disconnections during associations.
        if connectionCount > 0 {
            let disconnectRate = min(1.0, Double(disconnections) / Double(max(1, connectionCount)))
            ratio *= (1 - 0.5 * disconnectRate)
        }
        return min(1, max(0, ratio))
    }
}

/// A single point on the dashboard's historical charts.
public struct TimelineSample: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var network: String
    public var rssi: Double?
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var packetLossPercent: Double?
    public var throughputMbps: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        network: String,
        rssi: Double? = nil,
        latencyMs: Double? = nil,
        jitterMs: Double? = nil,
        packetLossPercent: Double? = nil,
        throughputMbps: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.network = network
        self.rssi = rssi
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.packetLossPercent = packetLossPercent
        self.throughputMbps = throughputMbps
    }
}
