import Foundation
@preconcurrency import Network
import WiFiPilotCore

/// Connectivity and latency probing using Network.framework.
///
/// Measurement design:
/// - Latency and jitter come from **several successive TCP handshakes to the same
///   endpoint** in one round. Comparing two different hosts tells you about two
///   different paths, not about variation over time.
/// - Every attempt is classified (`ProbeFailure`), so refusals, timeouts, DNS errors
///   and missing routes are counted separately instead of collapsing into "loss".
/// - Reachability is classified from path status, DNS, TCP and a verified HTTP fetch.
///   TCP success alone is never reported as internet access.
/// - Throughput is an optional, small, rate-limited download and is always labelled
///   approximate.
///
/// Nothing here inspects payloads, and nothing is uploaded.
final class NetworkMonitor: @unchecked Sendable {
    struct Reachability: Sendable, Equatable {
        var isSatisfied: Bool
        var isExpensive: Bool
        var usesWiFi: Bool
    }

    enum TCPProbeOutcome: Sendable, Equatable {
        case success(milliseconds: Double)
        case failure(ProbeFailure)
    }

    /// Serialises whichever probe callback finishes first.
    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    /// Remembers the most recent `NWConnection.waiting` error so a timeout can be
    /// reported as "host unreachable" rather than an unqualified timeout.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: NWError?

        func store(_ error: NWError) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        func take() -> NWError? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.wifipilot.pathmonitor")
    private let stateLock = NSLock()
    private var latestReachability = Reachability(isSatisfied: false, isExpensive: false, usesWiFi: false)

    /// A single stable endpoint, so successive attempts measure one path over time.
    let primaryHost = "1.1.1.1"
    let primaryPort: UInt16 = 443
    /// Successive attempts per round. Three gives a within-round jitter value and
    /// feeds the rolling loss estimate without meaningful bandwidth cost.
    let attemptsPerRound = 3
    let attemptTimeout: TimeInterval = 1.5
    let attemptSpacing: TimeInterval = 0.4

    var endpointLabel: String { "\(primaryHost):\(primaryPort)" }

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let usesWiFi = path.availableInterfaces.contains { $0.type == .wifi }
            let value = Reachability(
                isSatisfied: path.status == .satisfied,
                isExpensive: path.isExpensive,
                usesWiFi: usesWiFi
            )
            self.stateLock.lock()
            self.latestReachability = value
            self.stateLock.unlock()
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func reachability() -> Reachability {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestReachability
    }

    // MARK: - Probe rounds

    /// Runs one full monitoring round and returns a structured summary.
    ///
    /// - Parameters:
    ///   - includeThroughput: only true when the caller's `ThroughputProbePolicy`
    ///     approved a measurement (rate limit, no active transfer, enabled).
    ///   - throughputPolicy: supplies the payload size for that measurement.
    func probe(
        includeThroughput: Bool = false,
        throughputPolicy: ThroughputProbePolicy = .standard
    ) async -> ProbeRoundSummary {
        let startedAt = Date()
        let path = reachability()

        // DNS and HTTP run alongside the TCP attempts; the HTTP check is what actually
        // verifies internet access.
        async let dnsResult = dnsProbe(host: "captive.apple.com")
        async let httpResult = httpProbe()

        var attempts: [ProbeAttempt] = []
        var latencies: [Double] = []

        for index in 0..<attemptsPerRound {
            let outcome = await tcpProbe(host: primaryHost, port: primaryPort, timeout: attemptTimeout)
            switch outcome {
            case .success(let milliseconds):
                latencies.append(milliseconds)
                attempts.append(
                    ProbeAttempt(timestamp: Date(), endpoint: endpointLabel, latencyMs: milliseconds)
                )
            case .failure(let failure):
                attempts.append(
                    ProbeAttempt(timestamp: Date(), endpoint: endpointLabel, failure: failure)
                )
            }
            if index < attemptsPerRound - 1 {
                try? await Task.sleep(for: .milliseconds(Int(attemptSpacing * 1000)))
            }
        }

        let dns = await dnsResult
        let http = await httpResult

        // A DNS failure is a probe failure of its own kind: it is recorded separately and
        // never reported as an unanswered TCP handshake.
        if !dns.healthy {
            attempts.append(
                ProbeAttempt(timestamp: Date(), endpoint: "captive.apple.com", failure: .dnsFailure)
            )
        }

        let connectivity = ConnectivityClassifier.classify(
            pathAvailable: path.isSatisfied,
            dnsHealthy: dns.healthy,
            tcpReachable: !latencies.isEmpty,
            httpResult: http
        )

        var throughput: ThroughputOutcome = .notAttempted
        if includeThroughput {
            throughput = await measureThroughputOutcome(payloadBytes: throughputPolicy.payloadBytes)
        }

        return ProbeRoundSummary(
            timestamp: startedAt,
            endpoint: endpointLabel,
            latenciesMs: latencies,
            attempts: attempts.count,
            successes: latencies.count,
            timeouts: attempts.filter { $0.failure == .timeout }.count,
            refused: attempts.filter { $0.failure == .connectionRefused }.count,
            dnsFailures: attempts.filter { $0.failure == .dnsFailure }.count,
            pathFailures: attempts.filter { $0.failure == .pathUnavailable }.count
                + attempts.filter { $0.failure == .hostUnreachable }.count,
            dnsResolutionMs: dns.milliseconds,
            dnsHealthy: dns.healthy,
            connectivity: connectivity,
            throughput: throughput
        )
    }

    /// TCP connect time, measured from `start()` to the ready state, with the failure
    /// classified rather than reduced to nil.
    func tcpProbe(host: String, port: UInt16, timeout: TimeInterval) async -> TCPProbeOutcome {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .failure(.unknown) }
        let gate = ContinuationGate()
        let errorBox = ErrorBox()
        let queue = DispatchQueue(label: "com.wifipilot.probe.tcp")

        return await withCheckedContinuation { (continuation: CheckedContinuation<TCPProbeOutcome, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let started = DispatchTime.now().uptimeNanoseconds

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    connection.cancel()
                    continuation.resume(returning: .success(milliseconds: elapsed))
                case .failed(let error):
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(returning: .failure(Self.classify(error)))
                case .waiting(let error):
                    // No route yet: keep waiting for the ready state, but remember why so
                    // the timeout reports the real cause instead of a generic timeout.
                    errorBox.store(error)
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(returning: .failure(.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                guard gate.claim() else { return }
                connection.cancel()
                if let pending = errorBox.take() {
                    let failure = Self.classify(pending)
                    if failure == .hostUnreachable || failure == .pathUnavailable {
                        continuation.resume(returning: .failure(failure))
                        return
                    }
                }
                continuation.resume(returning: .failure(.timeout))
            }
        }
    }

    /// DNS resolution health, measured with the system resolver.
    func dnsProbe(host: String) async -> (milliseconds: Double?, healthy: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let started = DispatchTime.now().uptimeNanoseconds
                let status = getaddrinfo(host, "443", &hints, &result)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                if let result { freeaddrinfo(result) }
                continuation.resume(returning: (status == 0 ? elapsed : nil, status == 0))
            }
        }
    }

    /// HTTP verification with a result that distinguishes success, redirects (captive
    /// portals) and intercepted content from a plain failure.
    func httpProbe(timeout: TimeInterval = 4) async -> HTTPProbeResult {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else { return .failure }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("WiFiPilot", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure }
            if (300..<400).contains(http.statusCode) { return .redirect }
            guard http.statusCode == 200, let body = String(data: data, encoding: .utf8) else {
                return .failure
            }
            return body.contains("Success") ? .success : .unexpectedContent
        } catch {
            return .failure
        }
    }

    /// Boolean convenience used for post-switch verification. It requires a *verified*
    /// HTTP result; a successful TCP handshake is not enough.
    func verifyInternet(timeout: TimeInterval = 5) async -> Bool {
        await httpProbe(timeout: timeout) == .success
    }

    /// Controlled, small throughput measurement.
    ///
    /// Downloads a fixed payload (250 KB by default) and reports either a measured
    /// value or a reason it could not be measured. Failures never become zero.
    func measureThroughputOutcome(payloadBytes: Int, timeout: TimeInterval = 20) async -> ThroughputOutcome {
        let bytes = min(2_000_000, max(64_000, payloadBytes))
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else {
            return .unavailable(reason: "invalid measurement URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("WiFiPilot", forHTTPHeaderField: "User-Agent")

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable(reason: "no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .unavailable(reason: "HTTP \(http.statusCode)")
            }
            let seconds = Date().timeIntervalSince(started)
            guard seconds > 0.25 else { return .unavailable(reason: "transfer too short to measure") }
            guard !data.isEmpty else { return .unavailable(reason: "empty response") }
            let mbps = Double(data.count) * 8.0 / seconds / 1_000_000.0
            return .measured(mbps: mbps)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    // MARK: - Error mapping

    /// Maps a Network.framework error onto the shared failure taxonomy.
    static func classify(_ error: NWError) -> ProbeFailure {
        switch error {
        case .dns:
            return .dnsFailure
        case .posix(let code):
            if code == .ECONNREFUSED { return .connectionRefused }
            if code == .ETIMEDOUT { return .timeout }
            if code == .EHOSTUNREACH || code == .ENETUNREACH || code == .ENETDOWN { return .hostUnreachable }
            if code == .ECANCELED { return .cancelled }
            return .unknown
        case .tls:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
