import AppKit
import SwiftUI
import WiFiPilotCore

/// The menu-bar panel: current connection, mode, pause, quick scan, manual join.
struct MenuBarInterface: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)
            metrics
            Divider().padding(.vertical, 10)
            controls
            Divider().padding(.vertical, 10)
            alternatives
            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isConnected ? scoreColor(state.currentScore.total) : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(state.menuBarTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    ModeBadge(mode: state.mode)
                }
                Text(state.healthDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let paused = state.pauseRemainingText {
                    Label(paused, systemImage: "pause.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            if state.isConnected {
                ScoreRing(score: state.currentScore.total, size: 52)
            }
        }
    }

    // MARK: - Metrics

    private var metrics: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            MetricTile(
                title: "Signal",
                value: Fmt.rssi(state.link.map { Double($0.rssi) }),
                unit: "dBm",
                systemImage: "antenna.radiowaves.left.and.right"
            )
            MetricTile(
                title: "Latency",
                value: Fmt.ms(state.currentMetrics.averageLatencyMs),
                unit: "ms",
                systemImage: "timer"
            )
            MetricTile(
                title: "Jitter",
                value: Fmt.ms(state.currentMetrics.latencyJitterMs),
                unit: "ms",
                systemImage: "waveform.path"
            )
            MetricTile(
                title: "Probe loss",
                value: Fmt.percent(state.currentMetrics.packetLossPercent),
                unit: "%",
                systemImage: "exclamationmark.triangle"
            )
            MetricTile(
                title: "Throughput",
                value: Fmt.approxMbps(state.currentMetrics.averageThroughputMbps),
                unit: "Mbps",
                systemImage: "arrow.down.circle"
            )
            MetricTile(
                title: "Band",
                value: state.link?.band.displayName ?? "—",
                unit: state.link?.channel.map { "ch \($0)" },
                systemImage: "wifi.router"
            )
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            HStack(spacing: 8) {
                Button {
                    state.resumeAutomation()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .disabled(!state.isPaused)

                Menu {
                    Button("Pause for 15 minutes") { state.pause(for: 15 * 60) }
                    Button("Pause for 30 minutes") { state.pause(for: 30 * 60) }
                    Button("Pause for 1 hour") { state.pause(for: 60 * 60) }
                    Button("Pause for 4 hours") { state.pause(for: 4 * 60 * 60) }
                    Divider()
                    Button("Pause until tomorrow") {
                        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
                        state.pause(for: max(60, tomorrow.timeIntervalSinceNow))
                    }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    Task { await state.performScan() }
                } label: {
                    if state.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(state.isScanning)
            }
            .controlSize(.small)

            if state.lastDecision?.action == .wouldSwitch, let target = state.lastDecision?.target {
                Label(
                    "Would switch to \(target.displayName) — observe mode",
                    systemImage: "eye"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .lineLimit(2)
            }
        }
    }

    // MARK: - Alternatives

    private var alternatives: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Nearby networks")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(state.isScanning ? "scanning…" : "\(state.rows.count) known/visible")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if state.rows.filter({ !$0.isConnected }).isEmpty {
                Text("No other saved networks are visible right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(state.rows.filter { !$0.isConnected }.prefix(4)) { row in
                    alternativeRow(row)
                }
            }

            if let error = state.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private func alternativeRow(_ row: NetworkRow) -> some View {
        HStack(spacing: 8) {
            SignalBars(rssi: row.snapshot.rssi)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.snapshot.network.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if row.snapshot.isKnownSaved {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .help("Saved network")
                    }
                    if row.snapshot.isPreferred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                            .help("Preferred network")
                    }
                    if row.snapshot.isAvoided {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("Avoided network")
                    }
                }
                Text("\(Fmt.rssi(row.snapshot.rssi)) dBm · \(row.band.displayName)")
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

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.locationPermission.isAuthorized {
                Button {
                    state.requestLocationAccess()
                } label: {
                    Label("Grant Location access for Wi-Fi details", systemImage: "location")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
            }

            HStack(spacing: 10) {
                Button("Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                SettingsLink {
                    Text("Settings…")
                }
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
    }
}

/// The always-visible status item content.
struct MenuBarLabel: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.menuBarSymbol)
            Text(state.menuBarTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .accessibilityLabel("WiFiPilot, \(state.menuBarTitle), \(state.healthDescription)")
    }
}
