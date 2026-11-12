import Foundation

/// Identifies a Wi-Fi network.
///
/// WiFiPilot reasons about networks at *SSID* level: a router that advertises the
/// same SSID on several BSSIDs (bands, mesh nodes) is one network for switching
/// purposes, because macOS roams between those BSSIDs itself at no cost. BSSID is
/// retained for display and for signal-quality attribution.
public struct NetworkIdentity: Hashable, Codable, Sendable, Identifiable, Comparable {
    /// SSID as reported by CoreWLAN. Empty string for hidden networks.
    public let ssid: String
    /// BSSID of the observed access point (e.g. "a4:83:e7:11:22:33"). Optional because
    /// a saved network remembered from history may not have a BSSID at that moment.
    public let bssid: String?

    public init(ssid: String, bssid: String? = nil) {
        self.ssid = ssid
        self.bssid = bssid
    }

    /// Stable identifier including the BSSID, used for per-AP observations.
    public var id: String {
        guard let bssid, !bssid.isEmpty else { return "\(ssid)|*" }
        return "\(ssid)|\(bssid)"
    }

    /// Identifier used for network-level reasoning (saved-network matching, scoring).
    public var networkKey: String { Self.key(forSSID: ssid) }

    public static func key(forSSID ssid: String) -> String { ssid.lowercased() }

    public var displayName: String {
        ssid.isEmpty ? "Hidden Network" : ssid
    }

    public var isHidden: Bool { ssid.isEmpty }

    /// Strips the BSSID so the value can be used as a dictionary key per network.
    public var asNetwork: NetworkIdentity { NetworkIdentity(ssid: ssid) }

    public static func < (lhs: NetworkIdentity, rhs: NetworkIdentity) -> Bool {
        if lhs.ssid != rhs.ssid { return lhs.ssid < rhs.ssid }
        return (lhs.bssid ?? "") < (rhs.bssid ?? "")
    }
}

/// Radio band a channel belongs to.
public enum WiFiBand: String, Codable, Sendable, CaseIterable {
    case twoGHz
    case fiveGHz
    case sixGHz
    case unknown

    public init(channel: Int?) {
        guard let channel else {
            self = .unknown
            return
        }
        switch channel {
        case 1...14: self = .twoGHz
        case 32...196: self = .fiveGHz
        case 200...233: self = .sixGHz
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .twoGHz: "2.4 GHz"
        case .fiveGHz: "5 GHz"
        case .sixGHz: "6 GHz"
        case .unknown: "Unknown"
        }
    }
}

/// Security scheme of a network, normalized from CoreWLAN security types.
public enum WiFiSecurity: String, Codable, Sendable, CaseIterable {
    case open
    case wep
    case wpaPersonal
    case wpa2Personal
    case wpa3Personal
    case enterprise
    case unknown

    public var displayName: String {
        switch self {
        case .open: "Open"
        case .wep: "WEP"
        case .wpaPersonal: "WPA Personal"
        case .wpa2Personal: "WPA2 Personal"
        case .wpa3Personal: "WPA3 Personal"
        case .enterprise: "Enterprise"
        case .unknown: "Unknown"
        }
    }

    public var isSecure: Bool { self != .open }
}
