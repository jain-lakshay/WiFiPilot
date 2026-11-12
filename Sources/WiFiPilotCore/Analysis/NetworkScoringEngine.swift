import Foundation

/// Turns raw metrics into an explainable 0...100 network quality score.
///
/// Design rules:
/// - Throughput is log-scaled, so 40 → 60 Mbps is a small gain while 40 → 200 Mbps is large.
/// - Throughput is additionally damped by its own variability: a network that only
///   occasionally bursts is not rewarded like one that sustains the same average.
/// - Latency, jitter and packet loss use piecewise maps where small values are nearly
///   equivalent and pathological values fall off quickly.
/// - Instability (variation, spikes, disconnections) is scored explicitly and can be
///   weighted up via `stabilityPreference`.
/// - When data is missing the component is marked unmeasured and scores a neutral 0.5,
///   and signal-only scores are capped so an unmeasured network cannot masquerade as
///   a high-confidence winner.
public struct NetworkScoringEngine: Sendable {
    public var weights: ScoringWeights

    public init(weights: ScoringWeights = .standard) {
        self.weights = weights.sanitized()
    }

    // MARK: - Public API

    public func score(
        metrics: NetworkMetrics,
        basis: ScoreBasis,
        confidence: Double? = nil,
        historicalReliability: Double? = nil
    ) -> ScoreBreakdown {
        let effective = weights.effectiveWeights()
        var components: [ScoreComponent] = []

        func append(
            _ kind: ScoreComponentKind,
            quality: Double?,
            detail: String
        ) {
            let measured = quality != nil
            let resolved = min(1, max(0, quality ?? 0.5))
            let weight = effective[kind] ?? 0
            components.append(
                ScoreComponent(
                    kind: kind,
                    quality: resolved,
                    weight: weight,
                    contribution: resolved * weight * 100,
                    detail: measured ? detail : "Not measured — neutral value used",
                    isMeasured: measured
                )
            )
        }

        let throughputQualityValue: Double? = {
            guard let mbps = metrics.averageThroughputMbps, mbps > 0 else { return nil }
            let raw = Self.throughputQuality(mbps: mbps)
            let cv = min(1.5, max(0, metrics.throughputCoefficientOfVariation ?? 0))
            // Consistency damping: never let a burst pattern score like a steady link.
            return raw * (0.6 + 0.4 * (1 - min(1, cv)))
        }()

        append(
            .throughput,
            quality: throughputQualityValue,
            detail: Self.throughputDetail(metrics)
        )
        append(
            .latency,
            quality: metrics.averageLatencyMs.map { Self.latencyQuality(milliseconds: $0) },
            detail: metrics.averageLatencyMs.map { String(format: "%.0f ms average", $0) } ?? ""
        )
        append(
            .jitter,
            quality: metrics.latencyJitterMs.map { Self.jitterQuality(milliseconds: $0) },
            detail: metrics.latencyJitterMs.map { value in
                let method = metrics.jitterMethod.map { " · \($0)" } ?? ""
                return String(format: "%.1f ms", value) + method
            } ?? ""
        )
        append(
            .packetLoss,
            quality: metrics.packetLossPercent.map { Self.packetLossQuality(percent: $0) },
            detail: metrics.packetLossPercent.map { percent in
                if let estimate = metrics.lossEstimate {
                    return String(format: "%.1f %% · %@", percent, estimate.summary)
                }
                return String(format: "%.1f %%", percent)
            } ?? ""
        )
        append(
            .signal,
            quality: metrics.averageRSSI.map { Self.signalQuality(rssi: $0) },
            detail: metrics.averageRSSI.map { String(format: "%.0f dBm", $0) } ?? ""
        )
        append(
            .stability,
            quality: metrics.hasConnectionMeasurements || metrics.averageRSSI != nil
                ? Self.stabilityQuality(metrics: metrics)
                : nil,
            detail: Self.stabilityDetail(metrics)
        )

        var penalties: [ScorePenalty] = []
        var raw = components.reduce(0) { $0 + $1.contribution }

        // Connectivity is judged on verified internet access, not on TCP reachability.
        if let connectivity = metrics.connectivity {
            switch connectivity.classification {
            case .verifiedOpen:
                break
            case .captivePortal:
                let penalty = min(35, raw * 0.5)
                penalties.append(ScorePenalty(reason: "Captive portal — sign-in required", points: penalty))
                raw -= penalty
            case .restricted:
                penalties.append(ScorePenalty(reason: "HTTP verification failing", points: 15))
                raw -= 15
            case .dnsFailure:
                penalties.append(ScorePenalty(reason: "DNS resolution failing", points: 12))
                raw -= 12
            case .offline:
                let penalty = min(45, raw * 0.6)
                penalties.append(ScorePenalty(reason: "No external connectivity", points: penalty))
                raw -= penalty
            case .unverified:
                penalties.append(ScorePenalty(reason: "Internet access unverified", points: 5))
                raw -= 5
            }
        } else if metrics.sampleCount > 0, metrics.internetReachable == false {
            let penalty = min(45, raw * 0.6)
            penalties.append(ScorePenalty(reason: "No internet reachability", points: penalty))
            raw -= penalty
        } else if metrics.dnsHealthy == false {
            penalties.append(ScorePenalty(reason: "DNS resolution failing", points: 8))
            raw -= 8
        }
        if let loss = metrics.packetLossPercent, loss > 2 {
            let penalty = min(18, loss * 1.6)
            let label = metrics.lossEstimate == nil ? "Packet loss" : "Probe loss"
            penalties.append(ScorePenalty(reason: String(format: "%@ %.1f %%", label, loss), points: penalty))
            raw -= penalty
        }
        if metrics.disconnectionCount >= 2 {
            let penalty = min(20, Double(metrics.disconnectionCount) * 5)
            penalties.append(
                ScorePenalty(reason: "\(metrics.disconnectionCount) recent disconnections", points: penalty)
            )
            raw -= penalty
        }
        if let latency = metrics.averageLatencyMs, latency > 250 {
            penalties.append(ScorePenalty(reason: "Very high latency", points: 8))
            raw -= 8
        }

        if let historicalReliability {
            let adjustment = (min(1, max(0, historicalReliability)) - 0.5) * 8
            raw += adjustment
            if abs(adjustment) >= 0.5 {
                penalties.append(
                    ScorePenalty(
                        reason: adjustment > 0 ? "Past connections were reliable" : "Past connections were unreliable",
                        points: -adjustment
                    )
                )
            }
        }

        var total = min(100, max(0, raw))

        switch basis {
        case .signalOnly:
            total = min(total, 60)
        case .historical:
            total = min(total, 95)
        case .live:
            break
        }

        if let connectivity = metrics.connectivity {
            switch connectivity.classification {
            case .offline: total = min(total, 20)
            case .captivePortal: total = min(total, 25)
            case .restricted: total = min(total, 45)
            case .dnsFailure: total = min(total, 50)
            case .verifiedOpen, .unverified: break
            }
        } else if metrics.sampleCount > 0, metrics.internetReachable == false {
            total = min(total, 20)
        }

        let resolvedConfidence = min(
            1,
            max(0.05, confidence ?? Self.defaultConfidence(metrics: metrics, basis: basis))
        )

        return ScoreBreakdown(
            total: (total * 10).rounded() / 10,
            confidence: resolvedConfidence,
            basis: basis,
            components: components,
            penalties: penalties,
            summary: Self.summarize(total: total, components: components, basis: basis)
        )
    }

    /// Score built from a scan observation only. This is the honest maximum for a
    /// network we are not connected to and have no history with.
    public func signalOnlyScore(
        rssi: Double,
        rssiStandardDeviation: Double?,
        historicalReliability: Double? = nil
    ) -> ScoreBreakdown {
        let metrics = NetworkMetrics(
            averageRSSI: rssi,
            rssiStandardDeviation: rssiStandardDeviation,
            sampleCount: 0
        )
        return score(
            metrics: metrics,
            basis: .signalOnly,
            confidence: 0.3,
            historicalReliability: historicalReliability
        )
    }

    public func historicalScore(for metrics: NetworkMetrics, sampleCount: Int) -> ScoreBreakdown {
        var adjusted = metrics
        adjusted.sampleCount = max(adjusted.sampleCount, sampleCount)
        let confidence = min(0.9, max(0.25, Double(sampleCount) / 20.0))
        return score(metrics: adjusted, basis: .historical, confidence: confidence)
    }

    // MARK: - Quality maps

    /// Log-scaled throughput quality. 10 Mbps ≈ 0.4, 45 Mbps ≈ 0.56, 200 Mbps = 1.
    public static func throughputQuality(mbps: Double) -> Double {
        guard mbps.isFinite, mbps > 0 else { return 0 }
        let reference = 200.0
        let scaled = log1p(mbps / 10) / log1p(reference / 10)
        return min(1, max(0, scaled))
    }

    /// Latency quality: excellent up to ~25 ms, rapidly worse past ~120 ms.
    public static func latencyQuality(milliseconds: Double) -> Double {
        Piecewise.quality(
            milliseconds,
            points: [(0, 1.0), (25, 1.0), (60, 0.85), (120, 0.55), (250, 0.2), (500, 0.05), (2000, 0.0)]
        )
    }

    /// Jitter quality: a few milliseconds is fine, sustained jitter destroys calls.
    public static func jitterQuality(milliseconds: Double) -> Double {
        Piecewise.quality(
            milliseconds,
            points: [(0, 1.0), (5, 0.95), (20, 0.7), (60, 0.35), (150, 0.1), (300, 0.0)]
        )
    }

    /// Packet loss quality.
    public static func packetLossQuality(percent: Double) -> Double {
        Piecewise.quality(
            percent,
            points: [(0, 1.0), (0.5, 0.95), (1, 0.9), (3, 0.7), (8, 0.35), (20, 0.1), (50, 0.0)]
        )
    }

    /// RSSI quality in dBm.
    public static func signalQuality(rssi: Double) -> Double {
        Piecewise.quality(
            rssi,
            points: [(-95, 0.0), (-88, 0.15), (-80, 0.4), (-72, 0.65), (-65, 0.85), (-55, 1.0), (-30, 1.0)]
        )
    }

    /// Stability quality penalising variability, spikes, loss and disconnections.
    public static func stabilityQuality(metrics: NetworkMetrics) -> Double {
        let cv = min(1, max(0, (metrics.throughputCoefficientOfVariation ?? 0) / 0.6))
        let rssiVariation = min(1, max(0, (metrics.rssiStandardDeviation ?? 0) / 10.0))
        let disconnects = min(1, Double(metrics.disconnectionCount) / 3.0)
        let spikes = min(1, Double(metrics.latencySpikeCount) / 6.0)
        let lossComponent = min(1, max(0, (metrics.packetLossPercent ?? 0) / 5.0))

        let penalty = 0.34 * cv
            + 0.16 * rssiVariation
            + 0.20 * disconnects
            + 0.15 * spikes
            + 0.15 * lossComponent
        return min(1, max(0, 1 - penalty))
    }

    // MARK: - Helpers

    private static func defaultConfidence(metrics: NetworkMetrics, basis: ScoreBasis) -> Double {
        switch basis {
        case .signalOnly: return 0.3
        case .historical: return min(0.9, max(0.25, Double(metrics.sampleCount) / 20.0))
        case .live: return min(1, max(0.35, Double(metrics.sampleCount) / 12.0))
        }
    }

    private static func throughputDetail(_ metrics: NetworkMetrics) -> String {
        guard let mbps = metrics.averageThroughputMbps else { return "" }
        var parts = [String(format: "≈%.1f Mbps", mbps)]
        if let cv = metrics.throughputCoefficientOfVariation {
            parts.append(String(format: "%.0f %% variation", cv * 100))
        }
        if let count = metrics.throughputSampleCount, let window = metrics.throughputWindowSeconds {
            parts.append("\(count) sample\(count == 1 ? "" : "s") / \(Int(window)) s")
        }
        if metrics.throughputIsApproximate == true {
            parts.append("approximate")
        }
        return parts.joined(separator: ", ")
    }

    private static func stabilityDetail(_ metrics: NetworkMetrics) -> String {
        var parts: [String] = []
        if let cv = metrics.throughputCoefficientOfVariation {
            parts.append(String(format: "throughput variation %.0f %%", cv * 100))
        }
        if let sd = metrics.rssiStandardDeviation {
            parts.append(String(format: "signal variation %.1f dB", sd))
        }
        if metrics.disconnectionCount > 0 {
            parts.append("\(metrics.disconnectionCount) disconnections")
        }
        if metrics.latencySpikeCount > 0 {
            parts.append("\(metrics.latencySpikeCount) latency spikes")
        }
        return parts.isEmpty ? "No instability observed" : parts.joined(separator: ", ")
    }

    private static func summarize(total: Double, components: [ScoreComponent], basis: ScoreBasis) -> String {
        let measured = components.filter(\.isMeasured).sorted { $0.quality < $1.quality }
        let weakest = measured.first
        let band: String
        switch total {
        case 80...: band = "Excellent"
        case 65..<80: band = "Good"
        case 50..<65: band = "Fair"
        case 35..<50: band = "Poor"
        default: band = "Bad"
        }
        var text = "\(band)"
        if basis == .signalOnly { text += " (signal estimate)" }
        if let weakest, weakest.quality < 0.6 {
            text += " — weakest: \(weakest.kind.displayName.lowercased())"
        }
        return text
    }
}

/// Linear interpolation over a small set of quality reference points.
enum Piecewise {
    /// `points` must be sorted by x ascending.
    static func quality(_ x: Double, points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for index in 1..<points.count {
            let (x1, y1) = points[index - 1]
            let (x2, y2) = points[index]
            if x <= x2 {
                let span = x2 - x1
                guard span > 0 else { return y2 }
                let t = (x - x1) / span
                return y1 + (y2 - y1) * t
            }
        }
        return last.1
    }
}
