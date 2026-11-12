import SwiftUI
import WiFiPilotCore

struct SettingsInterface: View {
    let state: AppState

    @State private var newPreferred = ""
    @State private var newAvoided = ""
    @State private var newNever = ""

    var body: some View {
        Form {
            automationSection
            timingSection
            trafficSection
            weightsSection
            networksSection
            generalSection
            privacySection
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 700)
    }

    // MARK: - Sections

    private var automationSection: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { state.mode },
                set: { state.setMode($0) }
            )) {
                ForEach(AutomationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(state.mode.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            LabeledContent("Stability preference") {
                HStack(spacing: 10) {
                    Text("Speed").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: binding(\.policy.scoringWeights.stabilityPreference), in: 0...1)
                        .frame(minWidth: 180)
                    Text("Consistency").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(String(format: "%.0f %%", state.settings.policy.scoringWeights.stabilityPreference * 100))
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            LabeledContent("Minimum score advantage") {
                HStack(spacing: 10) {
                    Slider(value: binding(\.policy.minimumScoreAdvantage), in: 2...40, step: 1)
                        .frame(minWidth: 180)
                    Text(String(format: "%.0f pts", state.settings.policy.minimumScoreAdvantage))
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }

            Toggle("Only switch to saved networks", isOn: binding(\.policy.requireCandidateSavedNetwork))
        } header: {
            Text("Automation")
        } footer: {
            Text("Switching requires a sustained improvement, not a momentary peak. Raising the advantage makes WiFiPilot more conservative.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var timingSection: some View {
        Section {
            LabeledContent("Observation window") {
                HStack(spacing: 10) {
                    Stepper(
                        value: binding(\.policy.observationWindow),
                        in: 15...300,
                        step: 15
                    ) {
                        Text("\(Int(state.settings.policy.observationWindow)) s")
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
            LabeledContent("Degradation must last") {
                Stepper(
                    value: binding(\.policy.degradationDuration),
                    in: 0...180,
                    step: 5
                ) {
                    Text("\(Int(state.settings.policy.degradationDuration)) s")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                }
            }
            LabeledContent("Candidate qualification") {
                Stepper(
                    value: binding(\.policy.candidateQualificationDuration),
                    in: 0...180,
                    step: 5
                ) {
                    Text("\(Int(state.settings.policy.candidateQualificationDuration)) s")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                }
            }
            LabeledContent("Post-switch cooldown") {
                Stepper(
                    value: binding(\.policy.cooldownDuration),
                    in: 0...1200,
                    step: 30
                ) {
                    Text("\(Int(state.settings.policy.cooldownDuration)) s")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                }
            }
            LabeledContent("Manual choice protection") {
                Stepper(
                    value: binding(\.policy.manualSwitchProtection),
                    in: 0...1200,
                    step: 30
                ) {
                    Text("\(Int(state.settings.policy.manualSwitchProtection)) s")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Timing and hysteresis")
        } footer: {
            Text("Default values are starting points (60 s window, 10 s degradation, 15 s qualification, 120 s cooldown), not universal optima.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var trafficSection: some View {
        Section {
            Toggle("Protect active transfers", isOn: binding(\.activeTrafficProtectionEnabled))
            LabeledContent("Active traffic threshold") {
                HStack(spacing: 10) {
                    Slider(value: binding(\.policy.activeTrafficThresholdMbps), in: 0.5...50, step: 0.5)
                        .frame(minWidth: 180)
                    Text(String(format: "%.1f Mbps", state.settings.policy.activeTrafficThresholdMbps))
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
            }
            LabeledContent("Extra advantage during traffic") {
                HStack(spacing: 10) {
                    Slider(value: binding(\.policy.activeTrafficAdvantageBonus), in: 0...40, step: 1)
                        .frame(minWidth: 180)
                    Text(String(format: "%.0f pts", state.settings.policy.activeTrafficAdvantageBonus))
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
        } header: {
            Text("Active traffic")
        } footer: {
            Text("While a significant transfer is in progress the switching bar is raised. A genuinely unusable connection is still abandoned.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var weightsSection: some View {
        Section {
            weightRow("Throughput", keyPath: \.policy.scoringWeights.throughput)
            weightRow("Latency", keyPath: \.policy.scoringWeights.latency)
            weightRow("Jitter", keyPath: \.policy.scoringWeights.jitter)
            weightRow("Probe loss", keyPath: \.policy.scoringWeights.packetLoss)
            weightRow("Signal", keyPath: \.policy.scoringWeights.signal)
            weightRow("Stability", keyPath: \.policy.scoringWeights.stability)

            HStack {
                Text("Weights are normalised automatically.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset weights") {
                    state.updateSettings { $0.policy.scoringWeights = .standard }
                }
                .controlSize(.small)
            }
        } header: {
            Text("Score weights")
        } footer: {
            Text("Stability is computed from throughput variation, signal variation, latency spikes and recent disconnections. Jitter is the variation between successive probes to one endpoint, not a comparison of different hosts. 'Probe loss' counts unanswered TCP probes over the rolling window; it is not ICMP packet loss.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func weightRow(_ title: String, keyPath: WritableKeyPath<AppSettings, Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: binding(keyPath), in: 0...1)
                    .frame(minWidth: 180)
                Text(String(format: "%.2f", state.settings[keyPath: keyPath]))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var networksSection: some View {
        Section {
            ssidEditor(
                title: "Preferred",
                subtitle: "Slight threshold relief and tie-break priority.",
                values: state.settings.preferredNetworks,
                draft: $newPreferred
            ) { ssid in
                state.updateSettings { settings in
                    settings.preferredNetworks.append(ssid)
                    settings.avoidedNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
                }
            } onRemove: { ssid in
                state.updateSettings { settings in
                    settings.preferredNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
                }
            }

            ssidEditor(
                title: "Avoided",
                subtitle: "Never selected automatically, even if stronger.",
                values: state.settings.avoidedNetworks,
                draft: $newAvoided
            ) { ssid in
                state.updateSettings { settings in
                    settings.avoidedNetworks.append(ssid)
                    settings.preferredNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
                }
            } onRemove: { ssid in
                state.updateSettings { settings in
                    settings.avoidedNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
                }
            }

            ssidEditor(
                title: "Never auto-join",
                subtitle: "Manual joins only.",
                values: state.settings.neverAutoJoinNetworks,
                draft: $newNever
            ) { ssid in
                state.updateSettings { settings in
                    settings.neverAutoJoinNetworks.append(ssid)
                }
            } onRemove: { ssid in
                state.updateSettings { settings in
                    settings.neverAutoJoinNetworks.removeAll { $0.caseInsensitiveCompare(ssid) == .orderedSame }
                }
            }
        } header: {
            Text("Network lists")
        }
    }

    private func ssidEditor(
        title: String,
        subtitle: String,
        values: [String],
        draft: Binding<String>,
        onAdd: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            if !values.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(values, id: \.self) { ssid in
                        HStack(spacing: 4) {
                            Text(ssid).font(.system(size: 10)).lineLimit(1)
                            Button {
                                onRemove(ssid)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Add SSID", text: draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button("Add") {
                    let value = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    onAdd(value)
                    draft.wrappedValue = ""
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var generalSection: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(
                get: { state.settings.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            HStack(spacing: 8) {
                Text(LaunchAtLogin.statusDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if LaunchAtLogin.statusDescription.contains("approval") {
                    Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
            }

            Toggle("Notifications for switches", isOn: Binding(
                get: { state.settings.notificationsEnabled },
                set: { state.setNotificationsEnabled($0) }
            ))

            LabeledContent("Keep history for") {
                Stepper(value: binding(\.historyRetentionDays), in: 1...365) {
                    Text("\(state.settings.historyRetentionDays) days")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                }
            }

            LabeledContent("Probe interval") {
                Stepper(value: binding(\.probeIntervalSeconds), in: 2...60, step: 1) {
                    Text("\(Int(state.settings.probeIntervalSeconds)) s")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                }
            }

            Toggle("Controlled throughput measurement", isOn: binding(\.throughputProbeEnabled))
            Text("Downloads one 250 KB sample per interval — about 10 MB/hour at the default 90 s cadence — and reports an approximate figure. Measurements are skipped during active transfers and backed off after failures. Off by default to avoid using data.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if state.settings.throughputProbeEnabled {
                LabeledContent("Throughput interval") {
                    Stepper(value: binding(\.throughputProbeIntervalSeconds), in: 30...900, step: 30) {
                        Text("\(Int(state.settings.throughputProbeIntervalSeconds)) s")
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                    }
                }
                if let status = state.throughputStatus {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Prune history now") { state.pruneHistory() }
                    .controlSize(.small)
                Spacer()
                Button("Reset switching policy") {
                    state.updateSettings { $0.policy = .standard }
                }
                .controlSize(.small)
            }
        } header: {
            Text("General")
        }
    }

    private var privacySection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "location")
                    .foregroundStyle(state.locationPermission.isAuthorized ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.locationStatusText)
                        .font(.system(size: 11))
                    HStack(spacing: 8) {
                        if !state.locationPermission.isAuthorized {
                            Button("Request access") { state.requestLocationAccess() }
                                .controlSize(.small)
                        }
                        Button("Open System Settings") { state.openLocationSettings() }
                            .controlSize(.small)
                    }
                }
            }

            Text("All monitoring data stays on this Mac. WiFiPilot never stores Wi-Fi passwords, never reads traffic content and never sends telemetry.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if let error = state.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 10))
                    Spacer()
                    Button("Dismiss") { state.clearError() }.controlSize(.small)
                }
            }
        } header: {
            Text("Permissions and privacy")
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { newValue in
                state.updateSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}
