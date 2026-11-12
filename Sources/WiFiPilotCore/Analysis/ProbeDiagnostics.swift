import Foundation

// MARK: - Probe outcomes

/// Why a single connectivity probe did not produce a latency sample.
///
/// Deliberately separate cases: a refused connection, a timeout, a DNS failure and a
/// dead network path all look like "loss" in a naive counter, but they mean very
/// different things.
public enum ProbeFailure: String, Codable, Sendable, CaseIterable {
    case timeout
    case connectionRefused
    case hostUnreachable
    case dnsFailure
    case pathUnavailable
    case cancelled
    case unknown

    public var displayName: String {
        switch self {
        case .timeout: "timeout"
        case .connectionRefused: "connection refused"
        case .hostUnreachable: "host unreachable"
        case .dnsFailure: "DNS failure"
        case .pathUnavailable: "network path unavailable"
        case .cancelled: "cancelled"
        case .unknown: "unknown error"
        }
    }
}

/// One probe attempt against one endpoint.
public struct ProbeAttempt: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var endpoint: String
    public var latencyMs: Double?
    public var failure: ProbeFailure?

    public init(timestamp: Date, endpoint: String, latencyMs: Double? = nil, failure: ProbeFailure? = nil) {
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.latencyMs = latencyMs
        self.failure = failure
    }

    public var succeeded: Bool { failure == nil && latencyMs != nil }
}

/// Rolling probe-failure statistics.
///
/// This is explicitly **not** ICMP packet loss. It counts unanswered TCP connection
/// attempts to a known endpoint over a window and reports the failure rate together
/// with a confidence figure and a breakdown of failure kinds. The UI labels it as
/// "probe loss" for that reason.
public struct LossEstimate: Codable, Sendable, Equatable {
    public var windowSeconds: TimeInterval
    public var attempts: Int
    public var successes: Int
    public var timeouts: Int
    public var refused: Int
    public var dnsFailures: Int
    public var pathFailures: Int
    /// Failed probes / attempts, 0...100.
    public var estimatedLossPercent: Double
    /// 0...1, grows with the number of attempts in the window.
    public var confidence: Double
    public var method: String
    public var endpoint: String?

    public init(
        windowSeconds: TimeInterval,
        attempts: Int,
        successes: Int,
        timeouts: Int,
        refused: Int,
        dnsFailures: Int,
        pathFailures: Int,
        estimatedLossPercent: Double,
        confidence: Double,
        method: String = "TCP connection attempts (not ICMP)",
        endpoint: String? = nil
    ) {
        self.windowSeconds = windowSeconds
        self.attempts = attempts
        self.successes = successes
        self.timeouts = timeouts
        self.refused = refused
        self.dnsFailures = dnsFailures
        self.pathFailures = pathFailures
        self.estimatedLossPercent = estimatedLossPercent
        self.confidence = confidence
        self.method = method
        self.endpoint = endpoint
    }

    /// Enough evidence to describe a rate rather than a single blip.
    public var isStatisticallyMeaningful: Bool { attempts >= 4 && confidence >= 0.3 }

    public var summary: String {
        guard attempts > 0 else { return "No probes yet" }
        if successes == attempts { return "\(attempts) of \(attempts) probes answered" }
        var parts: [String] = []
        if timeouts > 0 { parts.append("\(timeouts) timed out") }
        if refused > 0 { parts.append("\(refused) refused") }
        if dnsFailures > 0 { parts.append("\(dnsFailures) DNS failures") }
        if pathFailures > 0 { parts.append("\(pathFailures) path failures") }
        let detail = parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
        return "\(successes) of \(attempts) probes answered\(detail)"
    }
}

/// Bounded-window store of probe attempts with failure classification.
public struct PacketLossEstimator: Sendable, Equatable {
    public let windowDuration: TimeInterval
    public let capacity: Int
    public private(set) var attempts: [ProbeAttempt]

    public init(windowDuration: TimeInterval = 300, capacity: Int = 600) {
        self.windowDuration = max(30, windowDuration)
        self.capacity = max(10, capacity)
        self.attempts = []
    }

    public mutating func record(_ attempt: ProbeAttempt) {
        attempts.append(attempt)
        prune(relativeTo: attempt.timestamp)
        if attempts.count > capacity {
            attempts.removeFirst(attempts.count - capacity)
        }
    }

    public mutating func record(contentsOf newAttempts: [ProbeAttempt]) {
        for attempt in newAttempts { record(attempt) }
    }

    public mutating func prune(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-windowDuration)
        if let firstValid = attempts.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValid > 0 { attempts.removeFirst(firstValid) }
        } else {
            attempts.removeAll(keepingCapacity: true)
        }
    }

    public mutating func removeAll() { attempts.removeAll(keepingCapacity: true) }

    public var attemptCount: Int { attempts.count }

    /// Failure statistics over the window ending at `now`. Nil when no probes exist.
    public func estimate(relativeTo now: Date) -> LossEstimate? {
        let cutoff = now.addingTimeInterval(-windowDuration)
        let recent = attempts.filter { $0.timestamp >= cutoff }
        guard !recent.isEmpty else { return nil }

        var successes = 0
        var timeouts = 0
        var refused = 0
        var dnsFailures = 0
        var pathFailures = 0

        for attempt in recent {
            if attempt.succeeded {
                successes += 1
                continue
            }
            switch attempt.failure ?? .unknown {
            case .timeout: timeouts += 1
            case .connectionRefused, .hostUnreachable: refused += 1
            case .dnsFailure: dnsFailures += 1
            case .pathUnavailable: pathFailures += 1
            case .cancelled, .unknown: break
            }
        }

        let countedFailures = timeouts + refused + dnsFailures + pathFailures
        let attemptsTotal = recent.count
        let loss = 100.0 * Double(countedFailures) / Double(max(1, attemptsTotal))
        // 12 attempts in the window is treated as full confidence; fewer scale down.
        let confidence = min(1.0, Double(attemptsTotal) / 12.0)

        return LossEstimate(
            windowSeconds: windowDuration,
            attempts: attemptsTotal,
            successes: successes,
            timeouts: timeouts,
            refused: refused,
            dnsFailures: dnsFailures,
            pathFailures: pathFailures,
            estimatedLossPercent: loss,
            confidence: confidence,
            endpoint: recent.last?.endpoint
        )
    }
}

// MARK: - Throughput outcome

/// Result of a throughput measurement attempt.
///
/// `notAttempted` and `unavailable` are deliberately distinct from `measured(0)`:
/// a network that could not be measured is not a network with zero throughput.
public enum ThroughputOutcome: Codable, Sendable, Equatable {
    case notAttempted
    case measured(mbps: Double)
    case unavailable(reason: String)

    public var measuredMbps: Double? {
        if case .measured(let mbps) = self { return mbps }
        return nil
    }

    public var attempted: Bool {
        if case .notAttempted = self { return false }
        return true
    }

    public var failureReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Connectivity

/// Result of the HTTP verification probe.
public enum HTTPProbeResult: String, Codable, Sendable {
    /// 200 with the expected payload: a normal, open internet connection.
    case success
    /// A 3xx response: typically a captive portal redirect.
    case redirect
    /// 200 with unexpected content: something intercepted the request.
    case unexpectedContent
    /// No usable HTTP response at all.
    case failure

    public var displayName: String {
        switch self {
        case .success: "verified"
        case .redirect: "redirected"
        case .unexpectedContent: "intercepted"
        case .failure: "failed"
        }
    }
}

/// How usable the current internet connection actually is.
public enum ConnectivityClass: String, Codable, Sendable, CaseIterable {
    /// HTTP verification succeeded against a known endpoint.
    case verifiedOpen
    /// HTTP was intercepted/redirected: sign-in or a proxy is required.
    case captivePortal
    /// TCP connectivity works but HTTP verification failed.
    case restricted
    /// Name resolution is failing.
    case dnsFailure
    /// No external connectivity at all.
    case offline
    /// Path/TCP connectivity exists but internet access was not verified.
    case unverified

    public var displayName: String {
        switch self {
        case .verifiedOpen: "Internet verified"
        case .captivePortal: "Captive portal"
        case .restricted: "Restricted"
        case .dnsFailure: "DNS failing"
        case .offline: "Offline"
        case .unverified: "Unverified"
        }
    }

    /// Only a verified-open connection is treated as usable internet.
    public var isVerifiedInternet: Bool { self == .verifiedOpen }
}

public struct ConnectivityAssessment: Codable, Sendable, Equatable {
    public var pathAvailable: Bool
    public var dnsHealthy: Bool?
    public var tcpReachable: Bool
    public var httpResult: HTTPProbeResult?
    public var classification: ConnectivityClass
    public var detail: String

    public init(
        pathAvailable: Bool,
        dnsHealthy: Bool?,
        tcpReachable: Bool,
        httpResult: HTTPProbeResult?,
        classification: ConnectivityClass,
        detail: String
    ) {
        self.pathAvailable = pathAvailable
        self.dnsHealthy = dnsHealthy
        self.tcpReachable = tcpReachable
        self.httpResult = httpResult
        self.classification = classification
        self.detail = detail
    }

    public var isVerifiedInternet: Bool { classification.isVerifiedInternet }

    public static let unknown = ConnectivityAssessment(
        pathAvailable: true,
        dnsHealthy: nil,
        tcpReachable: false,
        httpResult: nil,
        classification: .unverified,
        detail: "Not measured yet"
    )
}

/// Deterministic classification of connectivity signals. Pure and unit-testable.
public enum ConnectivityClassifier {
    /// - Parameters:
    ///   - pathAvailable: `NWPathMonitor` reports a satisfied path.
    ///   - dnsHealthy: nil when DNS was not checked.
    ///   - tcpReachable: at least one external TCP handshake succeeded.
    ///   - httpResult: nil when HTTP verification was not attempted.
    public static func classify(
        pathAvailable: Bool,
        dnsHealthy: Bool?,
        tcpReachable: Bool,
        httpResult: HTTPProbeResult?
    ) -> ConnectivityAssessment {
        guard pathAvailable else {
            return ConnectivityAssessment(
                pathAvailable: false,
                dnsHealthy: dnsHealthy,
                tcpReachable: false,
                httpResult: httpResult,
                classification: .offline,
                detail: "The system reports no usable network path."
            )
        }

        switch httpResult {
        case .success:
            return ConnectivityAssessment(
                pathAvailable: true,
                dnsHealthy: dnsHealthy,
                tcpReachable: true,
                httpResult: .success,
                classification: .verifiedOpen,
                detail: "HTTP verification succeeded."
            )
        case .redirect:
            return ConnectivityAssessment(
                pathAvailable: true,
                dnsHealthy: dnsHealthy,
                tcpReachable: tcpReachable,
                httpResult: .redirect,
                classification: .captivePortal,
                detail: "HTTP was redirected; a sign-in page or proxy is intercepting traffic."
            )
        case .unexpectedContent:
            return ConnectivityAssessment(
                pathAvailable: true,
                dnsHealthy: dnsHealthy,
                tcpReachable: tcpReachable,
                httpResult: .unexpectedContent,
                classification: .captivePortal,
                detail: "HTTP returned unexpected content; traffic is being intercepted."
            )
        case .failure:
            if dnsHealthy == false {
                return ConnectivityAssessment(
                    pathAvailable: true,
                    dnsHealthy: false,
                    tcpReachable: tcpReachable,
                    httpResult: .failure,
                    classification: .dnsFailure,
                    detail: "Name resolution is failing, so internet access cannot be verified."
                )
            }
            if tcpReachable {
                return ConnectivityAssessment(
                    pathAvailable: true,
                    dnsHealthy: dnsHealthy,
                    tcpReachable: true,
                    httpResult: .failure,
                    classification: .restricted,
                    detail: "TCP connections succeed but HTTP verification failed."
                )
            }
            return ConnectivityAssessment(
                pathAvailable: true,
                dnsHealthy: dnsHealthy,
                tcpReachable: false,
                httpResult: .failure,
                classification: .offline,
                detail: "No external connection could be established."
            )
        case nil:
            if dnsHealthy == false {
                return ConnectivityAssessment(
                    pathAvailable: true,
                    dnsHealthy: false,
                    tcpReachable: tcpReachable,
                    httpResult: nil,
                    classification: .dnsFailure,
                    detail: "Name resolution is failing."
                )
            }
            if tcpReachable {
                return ConnectivityAssessment(
                    pathAvailable: true,
                    dnsHealthy: dnsHealthy,
                    tcpReachable: true,
                    httpResult: nil,
                    classification: .unverified,
                    detail: "TCP is reachable but internet access has not been verified."
                )
            }
            return ConnectivityAssessment(
                pathAvailable: true,
                dnsHealthy: dnsHealthy,
                tcpReachable: false,
                httpResult: nil,
                classification: .unverified,
                detail: "No verification result yet."
            )
        }
    }
}

// MARK: - One probe round

/// Structured result of one monitoring round, produced by the platform layer and
/// consumed by the shared analyzer.
public struct ProbeRoundSummary: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var endpoint: String
    public var latenciesMs: [Double]
    public var attempts: Int
    public var successes: Int
    public var timeouts: Int
    public var refused: Int
    public var dnsFailures: Int
    public var pathFailures: Int
    public var dnsResolutionMs: Double?
    public var dnsHealthy: Bool
    public var connectivity: ConnectivityAssessment
    public var throughput: ThroughputOutcome

    public init(
        timestamp: Date,
        endpoint: String,
        latenciesMs: [Double],
        attempts: Int,
        successes: Int,
        timeouts: Int = 0,
        refused: Int = 0,
        dnsFailures: Int = 0,
        pathFailures: Int = 0,
        dnsResolutionMs: Double? = nil,
        dnsHealthy: Bool,
        connectivity: ConnectivityAssessment,
        throughput: ThroughputOutcome = .notAttempted
    ) {
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.latenciesMs = latenciesMs
        self.attempts = attempts
        self.successes = successes
        self.timeouts = timeouts
        self.refused = refused
        self.dnsFailures = dnsFailures
        self.pathFailures = pathFailures
        self.dnsResolutionMs = dnsResolutionMs
        self.dnsHealthy = dnsHealthy
        self.connectivity = connectivity
        self.throughput = throughput
    }

    public var medianLatencyMs: Double? { latenciesMs.percentile(0.5) }

    /// Jitter within this round: mean absolute difference between successive
    /// successful probes to the *same* endpoint.
    public var roundJitterMs: Double? {
        guard latenciesMs.count > 1 else { return nil }
        var deltas: [Double] = []
        for index in 1..<latenciesMs.count {
            deltas.append(abs(latenciesMs[index] - latenciesMs[index - 1]))
        }
        return deltas.mean
    }

    /// Attempts as individual probe records, for the rolling loss estimator.
    public var probeAttempts: [ProbeAttempt] {
        var records: [ProbeAttempt] = []
        for latency in latenciesMs {
            records.append(ProbeAttempt(timestamp: timestamp, endpoint: endpoint, latencyMs: latency))
        }
        if timeouts > 0 {
            records.append(contentsOf: Array(repeating: ProbeAttempt(timestamp: timestamp, endpoint: endpoint, failure: .timeout), count: timeouts))
        }
        if refused > 0 {
            records.append(contentsOf: Array(repeating: ProbeAttempt(timestamp: timestamp, endpoint: endpoint, failure: .connectionRefused), count: refused))
        }
        if dnsFailures > 0 {
            records.append(contentsOf: Array(repeating: ProbeAttempt(timestamp: timestamp, endpoint: endpoint, failure: .dnsFailure), count: dnsFailures))
        }
        if pathFailures > 0 {
            records.append(contentsOf: Array(repeating: ProbeAttempt(timestamp: timestamp, endpoint: endpoint, failure: .pathUnavailable), count: pathFailures))
        }
        return records
    }
}
