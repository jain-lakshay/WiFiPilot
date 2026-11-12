import Foundation
import WiFiPilotCore

// A hardware-free walkthrough of the decision engine.
//
// This is the same engine the app runs, fed with simulated networks and a fake clock,
// so it demonstrates OBSERVE/AUTO behaviour and the anti-flapping gates without
// touching a real Wi-Fi interface.
//
//   swift run wifipilot-simulate

let start = Date(timeIntervalSince1970: 1_700_000_000)
let policy = SwitchingPolicy.standard
let engineForScoring = NetworkScoringEngine(weights: policy.scoringWeights)

func line(_ character: Character = "─", count: Int = 96) -> String {
    String(repeating: character, count: count)
}

func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? String(value.prefix(width)) : value + String(repeating: " ", count: width - value.count)
}

func tableRow(_ columns: [String], widths: [Int]) -> String {
    zip(columns, widths).map { pad($0, $1) }.joined(separator: " │ ")
}

print("")
print("WiFiPilot — decision engine simulation")
print(line("═"))
print("Policy: observation \(Int(policy.observationWindow))s · degradation \(Int(policy.degradationDuration))s · "
    + "qualification \(Int(policy.candidateQualificationDuration))s · advantage \(Int(policy.minimumScoreAdvantage)) pts · "
    + "cooldown \(Int(policy.cooldownDuration))s")
print("")

// MARK: - Networks

let connectedSSID = "Cafe-Guest"
let networks: [(ssid: String, series: NetworkSimulation.Series, basis: ScoreBasis, saved: Bool)] = [
    (connectedSSID, NetworkSimulation.congested, .live, true),
    ("Home-5G", NetworkSimulation.strongFiveGHz, .historical, true),
    ("Home-2.4", NetworkSimulation.steadyFortyFive, .historical, true),
    ("Neighbour-Burst", NetworkSimulation.burstyPeaks, .historical, true),
    ("Airport-Free", NetworkSimulation.strongFiveGHz, .signalOnly, false)
]

print("Networks under consideration")
print(line())
print(tableRow(["SSID", "Basis", "Throughput", "Latency", "Jitter", "Loss", "RSSI", "Score"], widths: [22, 11, 12, 9, 8, 7, 7, 6]))
print(line())
for entry in networks {
    let metrics = NetworkSimulation.metrics(from: entry.series)
    let score = engineForScoring.score(metrics: metrics, basis: entry.basis)
    let throughput = metrics.averageThroughputMbps.map { String(format: "%.1f Mbps", $0) } ?? "—"
    let latency = metrics.averageLatencyMs.map { String(format: "%.0f ms", $0) } ?? "—"
    let jitter = metrics.latencyJitterMs.map { String(format: "%.0f ms", $0) } ?? "—"
    let loss = metrics.packetLossPercent.map { String(format: "%.1f %%", $0) } ?? "—"
    let rssi = metrics.averageRSSI.map { String(format: "%.0f", $0) } ?? "—"
    print(tableRow(
        [entry.ssid + (entry.saved ? "" : " (unsaved)"), entry.basis.shortLabel, throughput, latency, jitter, loss, rssi, String(format: "%.1f", score.total)],
        widths: [22, 11, 12, 9, 8, 7, 7, 6]
    ))
}
print(line())
print("The stable 45 Mbps network still beats the 40–60 Mbps one and the bursty one:")
let steady = engineForScoring.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.steadyFortyFive), basis: .historical)
let fluctuating = engineForScoring.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.fluctuatingFortyToSixty), basis: .historical)
let bursty = engineForScoring.score(metrics: NetworkSimulation.metrics(from: NetworkSimulation.burstyPeaks), basis: .historical)
print(String(
    format: "  steady %.1f  >  fluctuating %.1f  >  bursty %.1f",
    steady.total, fluctuating.total, bursty.total
))
print("")

// MARK: - Snapshots

func snapshots(
    connected: String,
    at date: Date
) -> (current: CandidateSnapshot?, candidates: [CandidateSnapshot]) {
    var current: CandidateSnapshot?
    var candidates: [CandidateSnapshot] = []
    for entry in networks {
        let isConnected = entry.ssid == connected
        // Once associated, the network is measured live rather than from history.
        var snapshot = NetworkSimulation.snapshot(
            ssid: entry.ssid,
            series: entry.series,
            weights: policy.scoringWeights,
            isKnownSaved: entry.saved,
            basis: isConnected ? .live : entry.basis,
            at: date
        )
        if isConnected {
            snapshot.isInternetReachable = true
            current = snapshot
        } else {
            candidates.append(snapshot)
        }
    }
    return (current, candidates)
}

// MARK: - Observe mode

var engine = DecisionEngine(policy: policy)
let observeSteps: [(label: String, seconds: TimeInterval)] = [
    ("t+0s   (first evaluation)", 0),
    ("t+5s   (degradation too short)", 5),
    ("t+12s  (candidate not qualified)", 12),
    ("t+20s  (both windows satisfied)", 20),
    ("t+40s  (observe continues, no switching)", 40)
]

print("OBSERVE mode — every decision is recorded, nothing is switched")
print(line("═"))
for step in observeSteps {
    let now = start.addingTimeInterval(step.seconds)
    let input = snapshots(connected: connectedSSID, at: now)
    let decision = engine.evaluate(
        DecisionInput(
            current: input.current,
            candidates: input.candidates,
            mode: .observe,
            activeTraffic: .idle,
            policy: policy
        ),
        at: now
    )
    print("")
    print("\(pad(step.label, 40)) action=\(pad(decision.action.rawValue, 14)) reason=\(decision.reason.code.rawValue)")
    print("  \(decision.reason.title): \(decision.reason.detail)")
    if let comparison = decision.comparison {
        print(String(
            format: "  score %.1f (%@) → %.1f (%@), advantage %.1f / required %.1f",
            comparison.currentScore, comparison.currentBasis.shortLabel,
            comparison.candidateScore, comparison.candidateBasis.shortLabel,
            comparison.advantage, comparison.minimumRequired
        ))
    }
}
print(line("═"))
print("")

// MARK: - AUTO mode

print("AUTO mode — same networks, engine now allowed to act")
print(line("═"))
engine = DecisionEngine(policy: policy)
var activeSSID = connectedSSID
var switchedAt: Date?

for offset in stride(from: 0.0, through: 200.0, by: 10.0) {
    let now = start.addingTimeInterval(offset)
    let input = snapshots(connected: activeSSID, at: now)
    let decision = engine.evaluate(
        DecisionInput(
            current: input.current,
            candidates: input.candidates,
            mode: .auto,
            activeTraffic: .idle,
            policy: policy
        ),
        at: now
    )
    print(String(format: "t+%-4.0f on %-12@ %@ → %@", offset, activeSSID, pad(decision.action.rawValue, 14), decision.reason.code.rawValue))

    if decision.action == .switchNetwork, let target = decision.target {
        engine.recordAutomatedSwitch(to: target, at: now)
        activeSSID = target.ssid
        switchedAt = now
        print("        associated with \(target.ssid); verification would run here, then cooldown starts")
    }
}
print(line("═"))
if let switchedAt {
    print(String(format: "Switched once at t+%.0fs. The new network is healthy, so subsequent evaluations keep it; the cooldown window is never abused.", switchedAt.timeIntervalSince(start)))
} else {
    print("No switch was justified.")
}
print("")

// MARK: - Emergency

print("Emergency: current network loses internet")
print(line("═"))
var emergencyEngine = DecisionEngine(policy: policy)
activeSSID = connectedSSID
let now = start.addingTimeInterval(0)
let dead = NetworkSimulation.snapshot(
    ssid: connectedSSID,
    series: NetworkSimulation.noInternet,
    weights: policy.scoringWeights,
    basis: .live,
    at: now
)
var deadCurrent = dead
deadCurrent.isInternetReachable = false
let emergencyDecision = emergencyEngine.evaluate(
    DecisionInput(
        current: deadCurrent,
        candidates: snapshots(connected: activeSSID, at: now).candidates,
        mode: .auto,
        activeTraffic: TrafficAssessment(isActive: true, incomingMbps: 60, outgoingMbps: 4, windowSeconds: 5, reason: "Active transfer"),
        policy: policy
    ),
    at: now
)
print("action=\(emergencyDecision.action.rawValue) reason=\(emergencyDecision.reason.code.rawValue) target=\(emergencyDecision.target?.ssid ?? "none")")
print("  \(emergencyDecision.reason.detail)")
print("")
