import Foundation

/// Which aspect of a network a score component describes.
public enum ScoreComponentKind: String, Codable, Sendable, CaseIterable {
    case throughput
    case latency
    case jitter
    case packetLoss
    case signal
    case stability

    public var displayName: String {
        switch self {
        case .throughput: "Throughput"
        case .latency: "Latency"
        case .jitter: "Jitter"
        case .packetLoss: "Packet loss"
        case .signal: "Signal"
        case .stability: "Stability"
        }
    }
}

/// How a score was obtained. The UI always shows this so an unmeasured candidate is
/// never presented as if it had live internet measurements.
public enum ScoreBasis: String, Codable, Sendable, CaseIterable {
    /// Measured on the current association.
    case live
    /// Measured during an earlier association with this network.
    case historical
    /// No measurements exist; derived from RSSI stability and past reliability.
    case signalOnly

    public var displayName: String {
        switch self {
        case .live: "Live measurement"
        case .historical: "Historical measurement"
        case .signalOnly: "Signal estimate"
        }
    }

    public var shortLabel: String {
        switch self {
        case .live: "Live"
        case .historical: "History"
        case .signalOnly: "Signal only"
        }
    }
}

public struct ScoreComponent: Codable, Sendable, Equatable, Identifiable {
    public var kind: ScoreComponentKind
    /// Normalized quality 0...1.
    public var quality: Double
    /// Effective weight after preference shifts (all weights sum to 1).
    public var weight: Double
    /// Points contributed to the 0...100 total.
    public var contribution: Double
    public var detail: String
    public var isMeasured: Bool

    public var id: String { kind.rawValue }
}

public struct ScorePenalty: Codable, Sendable, Equatable, Identifiable {
    public var reason: String
    public var points: Double
    public var id: String { reason }
}

/// Full, explainable score for one network.
public struct ScoreBreakdown: Codable, Sendable, Equatable {
    /// 0...100, higher is better.
    public var total: Double
    /// 0...1, how much measured data supports the score.
    public var confidence: Double
    public var basis: ScoreBasis
    public var components: [ScoreComponent]
    public var penalties: [ScorePenalty]
    public var summary: String

    public var isLive: Bool { basis == .live }

    public func component(_ kind: ScoreComponentKind) -> ScoreComponent? {
        components.first { $0.kind == kind }
    }

    public static let unavailable = ScoreBreakdown(
        total: 0,
        confidence: 0,
        basis: .signalOnly,
        components: [],
        penalties: [],
        summary: "No data"
    )
}

/// Configurable metric weights. Higher weight = more influence on the final score.
public struct ScoringWeights: Codable, Sendable, Equatable {
    public var throughput: Double
    public var latency: Double
    public var jitter: Double
    public var packetLoss: Double
    public var signal: Double
    public var stability: Double
    /// 0 = favour raw speed, 1 = favour consistency. Shifts weight from throughput to stability.
    public var stabilityPreference: Double

    public init(
        throughput: Double = 0.20,
        latency: Double = 0.22,
        jitter: Double = 0.14,
        packetLoss: Double = 0.20,
        signal: Double = 0.12,
        stability: Double = 0.12,
        stabilityPreference: Double = 0.7
    ) {
        self.throughput = throughput
        self.latency = latency
        self.jitter = jitter
        self.packetLoss = packetLoss
        self.signal = signal
        self.stability = stability
        self.stabilityPreference = stabilityPreference
    }

    public static let standard = ScoringWeights()

    /// Clamps inputs into a usable range; all weights must be non-negative and sum > 0.
    public func sanitized() -> ScoringWeights {
        func clampWeight(_ value: Double, fallback: Double) -> Double {
            value.isFinite ? max(0, value) : fallback
        }
        let cleaned = ScoringWeights(
            throughput: clampWeight(throughput, fallback: 0.20),
            latency: clampWeight(latency, fallback: 0.22),
            jitter: clampWeight(jitter, fallback: 0.14),
            packetLoss: clampWeight(packetLoss, fallback: 0.20),
            signal: clampWeight(signal, fallback: 0.12),
            stability: clampWeight(stability, fallback: 0.12),
            stabilityPreference: min(1, max(0, stabilityPreference.isFinite ? stabilityPreference : 0.7))
        )
        let total = cleaned.throughput + cleaned.latency + cleaned.jitter
            + cleaned.packetLoss + cleaned.signal + cleaned.stability
        return total > 0 ? cleaned : .standard
    }

    /// Weights normalized to 1, with the stability preference shifting emphasis
    /// away from throughput. This is what the engine actually multiplies by.
    public func effectiveWeights() -> [ScoreComponentKind: Double] {
        let base = sanitized()
        let sum = base.throughput + base.latency + base.jitter
            + base.packetLoss + base.signal + base.stability
        guard sum > 0 else { return ScoringWeights.standard.effectiveWeights() }

        var normalized: [ScoreComponentKind: Double] = [
            .throughput: base.throughput / sum,
            .latency: base.latency / sum,
            .jitter: base.jitter / sum,
            .packetLoss: base.packetLoss / sum,
            .signal: base.signal / sum,
            .stability: base.stability / sum
        ]
        let shifted = base.stabilityPreference * 0.5 * (normalized[.throughput] ?? 0)
        normalized[.throughput] = (normalized[.throughput] ?? 0) - shifted
        normalized[.stability] = (normalized[.stability] ?? 0) + shifted
        return normalized
    }
}
