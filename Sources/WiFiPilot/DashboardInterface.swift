import AppKit
import Charts
import SwiftUI
import WiFiPilotCore

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case networks
    case compare
    case decisions
    case history

    var id: DashboardSection { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .networks: "Networks"
        case .compare: "Compare"
        case .decisions: "Decisions"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .networks: "wifi"
        case .compare: "arrow.left.arrow.right"
        case .decisions: "list.bullet.rectangle"
        case .history: "chart.xyaxis.line"
        }
    }
}

struct DashboardInterface: View {
    let state: AppState
    @State private var section: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(DashboardSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.isRunning ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(state.isRunning ? "Monitoring" : "Stopped")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(state.statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        } detail: {
            Group {
                switch section ?? .overview {
                case .overview: OverviewView(state: state)
                case .networks: NetworksView(state: state)
                case .compare: CompareView(state: state)
                case .decisions: DecisionsView(state: state)
                case .history: HistoryView(state: state)
                }
            }
            .frame(minWidth: 720, minHeight: 580)
        }
        .task { await state.start() }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Overview

private struct OverviewView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ConnectionCard(state: state)
                HStack(alignment: .top, spacing: 14) {
                    DecisionCard(state: state)
                    AlternativesCard(state: state)
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ConnectionCard: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(state.menuBarTitle)
                            .font(.system(size: 20, weight: .semibold))
                        ModeBadge(mode: state.mode)
                        if state.isPaused {
                            Text("PAUSED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(state.healthDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let link = state.link {
                        Text(detailLine(link))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if state.isConnected {
                    ScoreRing(score: state.currentScore.total, size: 76)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                spacing: 8
            ) {
                MetricTile(title: "Signal", value: Fmt.rssi(state.link.map { Double($0.rssi) }), unit: "dBm", systemImage: "antenna.radiowaves.left.and.right")
                MetricTile(title: "SNR", value: Fmt.number(state.link?.snr.map(Double.init), digits: 0), unit: "dB", systemImage: "waveform.path.ecg")
                MetricTile(title: "Latency", value: Fmt.ms(state.currentMetrics.averageLatencyMs), unit: "ms", systemImage: "timer")
                MetricTile(title: "Jitter", value: Fmt.ms(state.currentMetrics.latencyJitterMs), unit: "ms", systemImage: "waveform.path")
                MetricTile(title: "Probe loss", value: Fmt.percent(state.currentMetrics.packetLossPercent), unit: "%", systemImage: "exclamationmark.triangle")
                MetricTile(title: "Throughput", value: Fmt.approxMbps(state.currentMetrics.averageThroughputMbps), unit: "Mbps", systemImage: "arrow.down.circle")
                MetricTile(title: "DNS", value: state.currentMetrics.dnsHealthy == nil ? "—" : (state.currentMetrics.dnsHealthy == true ? "Healthy" : "Failing"), unit: nil, systemImage: "network")
                MetricTile(title: "Internet", value: reachabilityText, unit: nil, systemImage: "globe")
            }

            HStack(spacing: 14) {
                Label(state.activeTraffic.isActive ? "Active traffic" : "Idle", systemImage: state.activeTraffic.isActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(state.activeTraffic.isActive ? .orange : .secondary)
                if state.activeTraffic.isActive {
                    Text(String(format: "%.1f Mbps", state.activeTraffic.totalMbps))
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let paused = state.pauseRemainingText {
                    Label(paused, systemImage: "pause.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Text("Basis: \(state.currentScore.basis.displayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var reachabilityText: String {
        if let connectivity = state.currentMetrics.connectivity {
            return connectivity.classification.displayName
        }
        switch state.currentMetrics.internetReachable {
        case true?: return "Reachable"
        case false?: return "No internet"
        case nil: return "Measuring…"
        }
    }

    private func detailLine(_ link: WiFiLink) -> String {
        var parts: [String] = []
        if let bssid = link.identity.bssid { parts.append("BSSID \(bssid)") }
        if let channel = link.channel {
            parts.append("\(link.band.displayName) · channel \(channel)")
        } else {
            parts.append(link.band.displayName)
        }
        parts.append(link.security.displayName)
        if link.transmitRateMbps > 0 {
            parts.append(String(format: "PHY rate %.0f Mbps", link.transmitRateMbps))
        }
        return parts.joined(separator: " · ")
    }
}

private struct DecisionCard: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Decision engine", subtitle: "Stability first, change only when it is earned")
                Spacer()
                ModeBadge(mode: state.mode)
            }

            Picker("Mode", selection: Binding(
                get: { state.mode },
                set: { state.setMode($0) }
            )) {
                ForEach(AutomationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let decision = state.lastDecision {
                VStack(alignment: .leading, spacing: 4) {
                    Text(decision.reason.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(decision.reason.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let comparison = decision.comparison {
                    VStack(spacing: 6) {
                        comparisonBar(
                            label: decision.currentNetwork?.displayName ?? "Current",
                            score: comparison.currentScore,
                            basis: comparison.currentBasis,
                            highlight: false
                        )
                        comparisonBar(
                            label: decision.target?.displayName ?? "Candidate",
                            score: comparison.candidateScore,
                            basis: comparison.candidateBasis,
                            highlight: comparison.advantage >= comparison.minimumRequired
                        )
                        HStack {
                            Text(String(format: "Advantage %.1f of %.1f required", comparison.advantage, comparison.minimumRequired))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(decision.action == .wouldSwitch ? "Would switch (observe)" : decision.action.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !decision.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(decision.notes.enumerated()), id: \.offset) { entry in
                            Text("· \(entry.element)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                Text("Waiting for the first evaluation…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func comparisonBar(label: String, score: Double, basis: ScoreBasis, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11, weight: highlight ? .semibold : .regular))
                    .lineLimit(1)
                Text(basis.shortLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f", score))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(scoreColor(score))
                        .frame(width: max(3, geometry.size.width * min(1, max(0, score / 100))))
                }
            }
            .frame(height: 5)
        }
    }
}

private struct AlternativesCard: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Alternatives", subtitle: "Signal estimates and past measurements")
                Spacer()
                Button {
                    Task { await state.performScan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(state.isScanning)
            }

            let alternatives = state.rows.filter { !$0.isConnected }
            if alternatives.isEmpty {
                Text("No other saved networks are visible.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(alternatives.prefix(5)) { row in
                    HStack(spacing: 8) {
                        SignalBars(rssi: row.snapshot.rssi)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.snapshot.network.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text("\(Fmt.rssi(row.snapshot.rssi)) dBm · \(row.snapshot.score.basis.shortLabel)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        ScoreBadge(score: row.snapshot.score.total, basis: row.snapshot.score.basis)
                        Button("Join") {
                            Task { await state.selectNetwork(row.snapshot.network) }
                        }
                        .controlSize(.mini)
                        .disabled(state.isSwitching)
                    }
                    .padding(.vertical, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Networks

private struct NetworksView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    title: "Networks",
                    subtitle: "Known networks and nearby access points. Scores for unconnected networks are estimates."
                )
                Spacer()
                Button {
                    Task { await state.performScan() }
                } label: {
                    Label("Scan now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.isScanning)
            }
            .padding(18)

            headerRow

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.rows) { row in
                        networkRow(row)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Network").frame(maxWidth: .infinity, alignment: .leading)
            Text("Signal").frame(width: 70, alignment: .leading)
            Text("Band").frame(width: 70, alignment: .leading)
            Text("Security").frame(width: 100, alignment: .leading)
            Text("Score").frame(width: 74, alignment: .leading)
            Text("Source").frame(width: 80, alignment: .leading)
            Text("Actions").frame(width: 150, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private func networkRow(_ row: NetworkRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(row.isConnected ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(row.snapshot.network.displayName)
                        .font(.system(size: 12, weight: row.isConnected ? .semibold : .regular))
                        .lineLimit(1)
                    if row.snapshot.isKnownSaved {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if row.snapshot.isPreferred {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                    }
                    if row.snapshot.isAvoided {
                        Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
                if let reliability = row.snapshot.historicalReliability {
                    Text(String(format: "reliability %.0f %%", reliability * 100))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                SignalBars(rssi: row.snapshot.rssi)
                Text(Fmt.rssi(row.snapshot.rssi))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 70, alignment: .leading)

            Text(row.band.displayName)
                .font(.system(size: 11))
                .frame(width: 70, alignment: .leading)

            Text(row.security.displayName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            ScoreBadge(score: row.snapshot.score.total, basis: row.snapshot.score.basis)
                .frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.snapshot.score.basis.shortLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(Fmt.relative(row.lastSeen))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .frame(width: 80, alignment: .leading)

            HStack(spacing: 6) {
                if row.isConnected {
                    Text("Connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                } else {
                    Button("Join") {
                        Task { await state.selectNetwork(row.snapshot.network) }
                    }
                    .controlSize(.mini)
                    .disabled(state.isSwitching)
                }
                Menu {
                    Button(row.snapshot.isPreferred ? "Remove preference" : "Mark as preferred") {
                        state.togglePreferred(row.snapshot.network.ssid)
                    }
                    Button(row.snapshot.isAvoided ? "Stop avoiding" : "Mark as avoided") {
                        state.toggleAvoided(row.snapshot.network.ssid)
                    }
                    Button(row.snapshot.isNeverAutoJoin ? "Allow auto-join" : "Never auto-join") {
                        state.toggleNeverAutoJoin(row.snapshot.network.ssid)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }
}

// MARK: - Compare

private struct CompareView: View {
    let state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Network comparison",
                    subtitle: "Only the current network has live internet measurements. Everything else is signal-only or historical."
                )

                if let current = state.rows.first(where: { $0.isConnected }),
                   let alternative = state.bestAlternative {
                    HStack(alignment: .top, spacing: 14) {
                        compareColumn(row: current, label: "Current", accent: .accentColor)
                        compareColumn(row: alternative, label: "Best alternative", accent: scoreColor(alternative.snapshot.score.total))
                    }
                    recommendation(current: current, alternative: alternative)
                } else if state.rows.first(where: { $0.isConnected }) == nil {
                    Text("Connect to a Wi-Fi network to compare it with candidates.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No alternative saved network is visible right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func compareColumn(row: NetworkRow, label: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(row.snapshot.network.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
                ScoreRing(score: row.snapshot.score.total, size: 54)
            }

            HStack(spacing: 6) {
                MetricTile(title: "Signal", value: Fmt.rssi(row.snapshot.rssi), unit: "dBm")
                MetricTile(title: "Band", value: row.band.displayName)
            }
            HStack(spacing: 6) {
                MetricTile(title: "Latency", value: Fmt.ms(row.metrics?.averageLatencyMs), unit: "ms")
                MetricTile(title: "Loss", value: Fmt.percent(row.metrics?.packetLossPercent), unit: "%")
            }
            HStack(spacing: 6) {
                MetricTile(title: "Throughput", value: Fmt.approxMbps(row.metrics?.averageThroughputMbps), unit: "Mbps")
                MetricTile(title: "Variation", value: Fmt.percent(row.metrics?.throughputCoefficientOfVariation.map { $0 * 100 }), unit: "%")
                MetricTile(
                    title: "Signal variation",
                    value: Fmt.number(row.metrics?.rssiStandardDeviation ?? row.snapshot.rssiStandardDeviation, digits: 1),
                    unit: "dB"
                )
            }

            if let reliability = row.snapshot.historicalReliability {
                Label(
                    String(format: "Historical reliability %.0f %%", reliability * 100),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Score components")
                    .font(.system(size: 11, weight: .semibold))
                ForEach(row.snapshot.score.components) { component in
                    ScoreComponentBar(component: component)
                }
            }

            if !row.snapshot.score.penalties.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Penalties")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(row.snapshot.score.penalties) { penalty in
                        Text(String(format: "−%.1f pts · %@", penalty.points, penalty.reason))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(row.snapshot.score.basis == .live
                 ? "Measured on this connection."
                 : (row.snapshot.score.basis == .historical
                    ? "Estimated from history recorded on this Mac."
                    : "Signal-only estimate — no connection measurements available."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func recommendation(current: NetworkRow, alternative: NetworkRow) -> some View {
        let advantage = alternative.snapshot.score.total - current.snapshot.score.total
        let required = state.settings.policy.minimumScoreAdvantage
        let text: String
        let symbol: String
        if advantage >= required {
            text = String(
                format: "%@ leads by %.1f points (%.1f required). If it stays available for %.0f s and the current network remains degraded, %@ will switch when automation is set to AUTO.",
                alternative.snapshot.network.displayName,
                advantage,
                required,
                state.settings.policy.candidateQualificationDuration,
                "WiFiPilot"
            )
            symbol = "arrow.right.circle.fill"
        } else if advantage > 0 {
            text = String(
                format: "%@ is only %.1f points better; %.1f points are required. Staying on %@.",
                alternative.snapshot.network.displayName,
                advantage,
                required,
                current.snapshot.network.displayName
            )
            symbol = "checkmark.circle"
        } else {
            text = "The current network is already the better option. Staying put."
            symbol = "checkmark.seal"
        }

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Recommendation")
                    .font(.system(size: 11, weight: .semibold))
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

// MARK: - Decisions

private struct DecisionsView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Decision log", subtitle: "Every decision, its numbers and its outcome — stored only on this Mac.")
                Spacer()
                Button("Prune old history") { state.pruneHistory() }
                    .controlSize(.small)
            }
            .padding(18)

            if state.decisions.isEmpty {
                Spacer()
                Text("No decisions recorded yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(state.decisions) { record in
                            row(record)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ record: DecisionRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: record.action))
                    .foregroundStyle(color(for: record))
                Text(record.title)
                    .font(.system(size: 12, weight: .semibold))
                if record.wasHypothetical {
                    Text("HYPOTHETICAL")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                }
                Spacer()
                if let succeeded = record.switchSucceeded {
                    Text(succeeded ? "verified" : "not verified")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(succeeded ? .green : .red)
                }
                Text(Fmt.timestamp(record.timestamp))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text(record.reasonDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if let currentScore = record.currentScore, let candidateScore = record.candidateScore {
                    Text(String(format: "%.1f → %.1f pts", currentScore, candidateScore))
                }
                if let metrics = record.currentMetrics, let latency = metrics.averageLatencyMs {
                    Text(String(format: "current latency %.0f ms", latency))
                }
                if record.activeTraffic {
                    Text("active traffic")
                }
                Text(record.mode.displayName)
                Text(record.reasonCode)
                if let detail = record.verificationDetail {
                    Text(detail).lineLimit(1)
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func symbol(for action: DecisionAction) -> String {
        switch action {
        case .switchNetwork: "arrow.right.circle.fill"
        case .wouldSwitch: "eye.circle"
        case .revertToPrevious: "arrow.uturn.backward.circle"
        case .stay: "checkmark.circle"
        }
    }

    private func color(for record: DecisionRecord) -> Color {
        switch record.action {
        case .switchNetwork: .accentColor
        case .wouldSwitch: .orange
        case .revertToPrevious: .red
        case .stay: .secondary
        }
    }
}

// MARK: - History

private enum HistoryMetric: String, CaseIterable, Identifiable {
    case rssi
    case latency
    case throughput
    case loss

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rssi: "Signal"
        case .latency: "Latency"
        case .throughput: "Throughput"
        case .loss: "Probe loss"
        }
    }

    var unit: String {
        switch self {
        case .rssi: "dBm"
        case .latency: "ms"
        case .throughput: "Mbps"
        case .loss: "%"
        }
    }

    func value(from sample: TimelineSample) -> Double? {
        switch self {
        case .rssi: return sample.rssi
        case .latency: return sample.latencyMs
        case .throughput: return sample.throughputMbps
        case .loss: return sample.packetLossPercent
        }
    }
}

private struct HistoryView: View {
    let state: AppState
    @State private var metric: HistoryMetric = .latency

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "History", subtitle: "Samples are kept locally and pruned by your retention setting.")
                    Spacer()
                    Picker("Metric", selection: $metric) {
                        ForEach(HistoryMetric.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }

                if state.timeline.isEmpty {
                    Text("No samples yet. WiFiPilot records a sample about every 10 seconds while connected.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 30)
                } else {
                    Chart {
                        ForEach(state.timeline) { sample in
                            if let value = metric.value(from: sample) {
                                LineMark(
                                    x: .value("Time", sample.timestamp),
                                    y: .value(metric.title, value)
                                )
                                .interpolationMethod(.monotone)
                                .foregroundStyle(by: .value("Network", sample.network))
                            }
                        }
                    }
                    .chartYAxisLabel(metric.unit)
                    .frame(height: 280)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Switching history", subtitle: "Actual switches only")
                    let switches = state.decisions.filter { $0.action == .switchNetwork || $0.action == .revertToPrevious }
                    if switches.isEmpty {
                        Text("No switches recorded yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(switches.prefix(20)) { record in
                            HStack(spacing: 8) {
                                Image(systemName: record.action == .revertToPrevious ? "arrow.uturn.backward" : "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(record.title)
                                    .font(.system(size: 11))
                                Spacer()
                                if let succeeded = record.switchSucceeded {
                                    Text(succeeded ? "verified" : "failed")
                                        .font(.system(size: 9))
                                        .foregroundStyle(succeeded ? .green : .red)
                                }
                                Text(Fmt.relative(record.timestamp))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .card()
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
