import Foundation

/// Automation mode of the app.
public enum AutomationMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Monitoring only; no evaluation, no switching. Monitoring itself continues.
    case off
    /// Evaluate and log hypothetical decisions, never switch.
    case observe
    /// Switch automatically when the engine confirms a meaningful improvement.
    case auto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .observe: "Observe"
        case .auto: "Auto"
        }
    }

    public var explanation: String {
        switch self {
        case .off: "Monitoring continues (signal, latency and reachability), but WiFiPilot never evaluates candidates or switches networks."
        case .observe: "WiFiPilot evaluates candidates and records what it would do, without switching."
        case .auto: "WiFiPilot switches automatically when a candidate is clearly more reliable."
        }
    }
}

/// Tunable anti-flapping and scoring configuration.
///
/// The defaults are deliberate starting points: they favour staying put, and the
/// engine can only switch after a *sustained* degradation and a *sustained*
/// candidate improvement.
public struct SwitchingPolicy: Codable, Sendable, Equatable {
    /// Rolling window used to compute live metrics.
    public var observationWindow: TimeInterval
    /// How long the current network must stay degraded before it can be abandoned.
    public var degradationDuration: TimeInterval
    /// How long a candidate must remain available and better before it qualifies.
    public var candidateQualificationDuration: TimeInterval
    /// Points (0...100 scale) a candidate must beat the current network by.
    public var minimumScoreAdvantage: Double
    /// Minimum time after any switch before the next automatic switch.
    public var cooldownDuration: TimeInterval
    /// Extra advantage required while a significant transfer is in progress.
    public var activeTrafficAdvantageBonus: Double
    /// Combined interface throughput considered "active traffic".
    public var activeTrafficThresholdMbps: Double
    /// Below this score the current network is considered degraded.
    public var degradationScoreThreshold: Double
    /// Below this score the current network is considered effectively unusable,
    /// which lets the engine bypass the advantage threshold.
    public var unusableScoreThreshold: Double
    /// Below this score an immediate switch is allowed even during cooldown
    /// (given internet reachability failures or near-zero health).
    public var emergencyScoreThreshold: Double
    /// A candidate must score at least this much to be worth joining.
    public var minimumCandidateScore: Double
    /// Maximum RSSI standard deviation (dB) for a signal-only candidate to qualify.
    public var maximumCandidateSignalVariation: Double
    /// How long a manual switch suppresses automatic switching.
    public var manualSwitchProtection: TimeInterval
    /// Whether candidates must be saved/known networks.
    public var requireCandidateSavedNetwork: Bool
    /// Rolling-hour cap on automatic switch attempts (successful, failed or recovery).
    /// Emergency switches are exempt. Zero disables the cap.
    public var maximumSwitchesPerHour: Double
    /// Weight configuration used for scoring.
    public var scoringWeights: ScoringWeights

    public init(
        observationWindow: TimeInterval = 60,
        degradationDuration: TimeInterval = 10,
        candidateQualificationDuration: TimeInterval = 15,
        minimumScoreAdvantage: Double = 12,
        cooldownDuration: TimeInterval = 120,
        activeTrafficAdvantageBonus: Double = 10,
        activeTrafficThresholdMbps: Double = 2.0,
        degradationScoreThreshold: Double = 60,
        unusableScoreThreshold: Double = 35,
        emergencyScoreThreshold: Double = 20,
        minimumCandidateScore: Double = 45,
        maximumCandidateSignalVariation: Double = 6.0,
        manualSwitchProtection: TimeInterval = 120,
        requireCandidateSavedNetwork: Bool = true,
        maximumSwitchesPerHour: Double = 4,
        scoringWeights: ScoringWeights = .standard
    ) {
        self.observationWindow = observationWindow
        self.degradationDuration = degradationDuration
        self.candidateQualificationDuration = candidateQualificationDuration
        self.minimumScoreAdvantage = minimumScoreAdvantage
        self.cooldownDuration = cooldownDuration
        self.activeTrafficAdvantageBonus = activeTrafficAdvantageBonus
        self.activeTrafficThresholdMbps = activeTrafficThresholdMbps
        self.degradationScoreThreshold = degradationScoreThreshold
        self.unusableScoreThreshold = unusableScoreThreshold
        self.emergencyScoreThreshold = emergencyScoreThreshold
        self.minimumCandidateScore = minimumCandidateScore
        self.maximumCandidateSignalVariation = maximumCandidateSignalVariation
        self.manualSwitchProtection = manualSwitchProtection
        self.requireCandidateSavedNetwork = requireCandidateSavedNetwork
        self.maximumSwitchesPerHour = maximumSwitchesPerHour
        self.scoringWeights = scoringWeights
    }

    public static let standard = SwitchingPolicy()

    /// Sanitised copy with nonsensical values clamped. Settings changes pass through here.
    public func sanitized() -> SwitchingPolicy {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            guard value.isFinite else { return range.lowerBound }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        var copy = self
        copy.observationWindow = clamp(observationWindow, 15...600)
        copy.degradationDuration = clamp(degradationDuration, 0...600)
        copy.candidateQualificationDuration = clamp(candidateQualificationDuration, 0...600)
        copy.minimumScoreAdvantage = clamp(minimumScoreAdvantage, 0...60)
        copy.cooldownDuration = clamp(cooldownDuration, 0...3600)
        copy.activeTrafficAdvantageBonus = clamp(activeTrafficAdvantageBonus, 0...60)
        copy.activeTrafficThresholdMbps = clamp(activeTrafficThresholdMbps, 0.1...1000)
        copy.degradationScoreThreshold = clamp(degradationScoreThreshold, 5...95)
        copy.unusableScoreThreshold = clamp(unusableScoreThreshold, 1...95)
        copy.emergencyScoreThreshold = clamp(emergencyScoreThreshold, 0...90)
        copy.minimumCandidateScore = clamp(minimumCandidateScore, 0...100)
        copy.maximumCandidateSignalVariation = clamp(maximumCandidateSignalVariation, 0.5...30)
        copy.manualSwitchProtection = clamp(manualSwitchProtection, 0...3600)
        copy.maximumSwitchesPerHour = clamp(maximumSwitchesPerHour, 0...60)
        copy.scoringWeights = scoringWeights.sanitized()
        return copy
    }

    /// How long after a switch automatic switching is blocked.
    public var effectiveCooldown: TimeInterval { max(cooldownDuration, 0) }
}

/// Everything the engine knows about one network at evaluation time.
public struct CandidateSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var network: NetworkIdentity
    /// Smoothed RSSI in dBm.
    public var rssi: Double
    /// RSSI standard deviation over recent observations, when known.
    public var rssiStandardDeviation: Double?
    public var score: ScoreBreakdown
    /// macOS has saved credentials for this SSID (as far as we can determine).
    public var isKnownSaved: Bool
    public var isPreferred: Bool
    public var isAvoided: Bool
    public var isNeverAutoJoin: Bool
    public var isAvailable: Bool
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    /// 0...1 reliability derived from past associations with this network.
    public var historicalReliability: Double?
    /// Live reachability; nil when not connected to this network.
    public var isInternetReachable: Bool?

    public var id: String { network.networkKey }
    public var linkQuality: Double { SignalQuality.normalized(rssi: rssi) }

    public init(
        network: NetworkIdentity,
        rssi: Double,
        rssiStandardDeviation: Double? = nil,
        score: ScoreBreakdown,
        isKnownSaved: Bool,
        isPreferred: Bool = false,
        isAvoided: Bool = false,
        isNeverAutoJoin: Bool = false,
        isAvailable: Bool = true,
        firstObservedAt: Date,
        lastObservedAt: Date,
        historicalReliability: Double? = nil,
        isInternetReachable: Bool? = nil
    ) {
        self.network = network
        self.rssi = rssi
        self.rssiStandardDeviation = rssiStandardDeviation
        self.score = score
        self.isKnownSaved = isKnownSaved
        self.isPreferred = isPreferred
        self.isAvoided = isAvoided
        self.isNeverAutoJoin = isNeverAutoJoin
        self.isAvailable = isAvailable
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.historicalReliability = historicalReliability
        self.isInternetReachable = isInternetReachable
    }
}

/// Pure input for one evaluation. Contains no clocks and no hardware references.
public struct DecisionInput: Sendable, Equatable {
    public var current: CandidateSnapshot?
    public var candidates: [CandidateSnapshot]
    public var mode: AutomationMode
    /// Automatic switching is suspended until this date.
    public var pauseUntil: Date?
    public var activeTraffic: TrafficAssessment
    public var policy: SwitchingPolicy

    public init(
        current: CandidateSnapshot?,
        candidates: [CandidateSnapshot],
        mode: AutomationMode,
        pauseUntil: Date? = nil,
        activeTraffic: TrafficAssessment = .idle,
        policy: SwitchingPolicy = .standard
    ) {
        self.current = current
        self.candidates = candidates
        self.mode = mode
        self.pauseUntil = pauseUntil
        self.activeTraffic = activeTraffic
        self.policy = policy
    }
}

public enum DecisionAction: String, Codable, Sendable {
    case stay
    case wouldSwitch
    case switchNetwork
    case revertToPrevious
}

public struct DecisionReason: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case automationOff
        case manuallyPaused
        case noCurrentConnection
        case noEligibleCandidates
        case currentNetworkHealthy
        case insufficientAdvantage
        case degradationNotSustained
        case candidateNotQualified
        case candidateSignalUnstable
        case candidateNotSaved
        case candidateAvoided
        case candidateNeverAutoJoin
        case candidateLowQuality
        case candidateAlreadyConnected
        case cooldownActive
        case activeTrafficProtection
        case currentNetworkUnusable
        case emergencySwitch
        case qualifiedImprovement
        case observingWouldSwitch
        case manualSwitchProtection
        case awaitingVerification
        case recoveryToPrevious
        case switchVerificationFailed
        case switchVerificationSucceeded
        case switchRateLimited
    }

    public var code: Code
    public var title: String
    public var detail: String

    public init(code: Code, title: String, detail: String) {
        self.code = code
        self.title = title
        self.detail = detail
    }
}

/// Side-by-side explanation of the two scores that drove a decision.
public struct ScoreComparison: Codable, Sendable, Equatable {
    public var currentScore: Double
    public var candidateScore: Double
    public var advantage: Double
    public var minimumRequired: Double
    public var currentBasis: ScoreBasis
    public var candidateBasis: ScoreBasis
    public var currentConfidence: Double
    public var candidateConfidence: Double
    public var currentSummary: String
    public var candidateSummary: String
}

/// What the engine concluded. Always carries a human-readable reason.
public struct AutomatedDecision: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var action: DecisionAction
    public var target: NetworkIdentity?
    public var reason: DecisionReason
    public var comparison: ScoreComparison?
    public var currentNetwork: NetworkIdentity?
    public var mode: AutomationMode
    public var activeTraffic: TrafficAssessment
    /// Extra observations, e.g. which gates were evaluated.
    public var notes: [String]

    public var isHypothetical: Bool { action == .wouldSwitch }
    public var shouldSwitch: Bool { action == .switchNetwork || action == .revertToPrevious }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        action: DecisionAction,
        target: NetworkIdentity? = nil,
        reason: DecisionReason,
        comparison: ScoreComparison? = nil,
        currentNetwork: NetworkIdentity? = nil,
        mode: AutomationMode,
        activeTraffic: TrafficAssessment = .idle,
        notes: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.target = target
        self.reason = reason
        self.comparison = comparison
        self.currentNetwork = currentNetwork
        self.mode = mode
        self.activeTraffic = activeTraffic
        self.notes = notes
    }
}
