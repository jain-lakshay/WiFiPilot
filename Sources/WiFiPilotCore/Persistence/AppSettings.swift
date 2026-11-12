import Foundation

/// User-visible configuration, persisted as JSON in Application Support.
public struct AppSettings: Codable, Sendable, Equatable {
    public var automationMode: AutomationMode
    public var policy: SwitchingPolicy
    /// SSIDs the user prefers; they get a small threshold relief and win ties.
    public var preferredNetworks: [String]
    /// SSIDs never eligible for automatic switching.
    public var avoidedNetworks: [String]
    /// SSIDs that may never be joined automatically (manual only).
    public var neverAutoJoinNetworks: [String]
    public var activeTrafficProtectionEnabled: Bool
    public var launchAtLogin: Bool
    public var notificationsEnabled: Bool
    /// Days of samples and decisions kept on disk.
    public var historyRetentionDays: Int
    /// Controlled throughput measurement (opt-in, small download).
    public var throughputProbeEnabled: Bool
    /// Minimum seconds between controlled throughput measurements.
    public var throughputProbeIntervalSeconds: Double
    /// Seconds between health probe rounds.
    public var probeIntervalSeconds: Double

    public init(
        automationMode: AutomationMode = .observe,
        policy: SwitchingPolicy = .standard,
        preferredNetworks: [String] = [],
        avoidedNetworks: [String] = [],
        neverAutoJoinNetworks: [String] = [],
        activeTrafficProtectionEnabled: Bool = true,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = true,
        historyRetentionDays: Int = 30,
        throughputProbeEnabled: Bool = false,
        throughputProbeIntervalSeconds: Double = 90,
        probeIntervalSeconds: Double = 5
    ) {
        self.automationMode = automationMode
        self.policy = policy
        self.preferredNetworks = preferredNetworks
        self.avoidedNetworks = avoidedNetworks
        self.neverAutoJoinNetworks = neverAutoJoinNetworks
        self.activeTrafficProtectionEnabled = activeTrafficProtectionEnabled
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.historyRetentionDays = historyRetentionDays
        self.throughputProbeEnabled = throughputProbeEnabled
        self.throughputProbeIntervalSeconds = throughputProbeIntervalSeconds
        self.probeIntervalSeconds = probeIntervalSeconds
    }

    public static let `default` = AppSettings()

    private enum CodingKeys: String, CodingKey {
        case automationMode, policy, preferredNetworks, avoidedNetworks, neverAutoJoinNetworks
        case activeTrafficProtectionEnabled, launchAtLogin, notificationsEnabled, historyRetentionDays
        case throughputProbeEnabled, throughputProbeIntervalSeconds, probeIntervalSeconds
    }

    /// Tolerant decoding: missing or unknown keys fall back to defaults so an
    /// upgraded build never loses the user's settings file.
    public init(from decoder: Decoder) throws {
        let defaults = AppSettings.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.automationMode = (try? container.decode(AutomationMode.self, forKey: .automationMode)) ?? defaults.automationMode
        self.policy = ((try? container.decode(SwitchingPolicy.self, forKey: .policy)) ?? defaults.policy).sanitized()
        self.preferredNetworks = (try? container.decode([String].self, forKey: .preferredNetworks)) ?? defaults.preferredNetworks
        self.avoidedNetworks = (try? container.decode([String].self, forKey: .avoidedNetworks)) ?? defaults.avoidedNetworks
        self.neverAutoJoinNetworks = (try? container.decode([String].self, forKey: .neverAutoJoinNetworks)) ?? defaults.neverAutoJoinNetworks
        self.activeTrafficProtectionEnabled = (try? container.decode(Bool.self, forKey: .activeTrafficProtectionEnabled)) ?? defaults.activeTrafficProtectionEnabled
        self.launchAtLogin = (try? container.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        self.notificationsEnabled = (try? container.decode(Bool.self, forKey: .notificationsEnabled)) ?? defaults.notificationsEnabled
        self.historyRetentionDays = (try? container.decode(Int.self, forKey: .historyRetentionDays)) ?? defaults.historyRetentionDays
        self.throughputProbeEnabled = (try? container.decode(Bool.self, forKey: .throughputProbeEnabled)) ?? defaults.throughputProbeEnabled
        self.throughputProbeIntervalSeconds = (try? container.decode(Double.self, forKey: .throughputProbeIntervalSeconds)) ?? defaults.throughputProbeIntervalSeconds
        self.probeIntervalSeconds = (try? container.decode(Double.self, forKey: .probeIntervalSeconds)) ?? defaults.probeIntervalSeconds
    }

    /// Effective bandwidth-discipline policy for controlled throughput sampling.
    /// The five-minute window is deliberately longer than the observation window so a
    /// handful of spaced samples can describe variation.
    public var throughputPolicy: ThroughputProbePolicy {
        ThroughputProbePolicy(
            isEnabled: throughputProbeEnabled,
            minimumInterval: throughputProbeIntervalSeconds,
            windowDuration: 300
        ).sanitized()
    }

    public func isPreferred(_ ssid: String) -> Bool {
        preferredNetworks.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame }
    }

    public func isAvoided(_ ssid: String) -> Bool {
        avoidedNetworks.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame }
    }

    public func isNeverAutoJoin(_ ssid: String) -> Bool {
        neverAutoJoinNetworks.contains { $0.caseInsensitiveCompare(ssid) == .orderedSame }
    }

    /// Clamps values that come from UI controls or a hand-edited file.
    public func sanitized() -> AppSettings {
        var copy = self
        copy.policy = policy.sanitized()
        copy.historyRetentionDays = min(365, max(1, historyRetentionDays))
        copy.probeIntervalSeconds = min(120, max(2, probeIntervalSeconds.isFinite ? probeIntervalSeconds : 5))
        copy.throughputProbeIntervalSeconds = min(900, max(30, throughputProbeIntervalSeconds.isFinite ? throughputProbeIntervalSeconds : 90))
        copy.preferredNetworks = Self.unique(preferredNetworks)
        copy.avoidedNetworks = Self.unique(avoidedNetworks)
        copy.neverAutoJoinNetworks = Self.unique(neverAutoJoinNetworks)
        return copy
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value.lowercased()).inserted { result.append(value) }
        }
        return result
    }
}
