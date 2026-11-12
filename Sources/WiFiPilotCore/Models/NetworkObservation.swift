import Foundation

/// One observation of one access point at one instant.
///
/// Observations are the raw material of the whole application: signal statistics,
/// candidate qualification and historical reliability are all derived from them.
public struct NetworkObservation: Codable, Sendable, Hashable {
    public var identity: NetworkIdentity
    /// Received signal strength in dBm, typically -30 (excellent) to -95 (unusable).
    public var rssi: Int
    /// Noise floor in dBm when the platform reports it (CoreWLAN usually does not).
    public var noise: Int?
    public var channel: Int?
    /// Security as reported by the scan.
    public var security: WiFiSecurity
    /// Whether macOS has saved credentials for this SSID, as far as we can tell.
    public var isKnownSaved: Bool
    public var timestamp: Date

    public init(
        identity: NetworkIdentity,
        rssi: Int,
        noise: Int? = nil,
        channel: Int? = nil,
        security: WiFiSecurity = .unknown,
        isKnownSaved: Bool = false,
        timestamp: Date
    ) {
        self.identity = identity
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.security = security
        self.isKnownSaved = isKnownSaved
        self.timestamp = timestamp
    }

    public var band: WiFiBand { WiFiBand(channel: channel) }

    /// Signal-to-noise ratio in dB, only when a noise floor is available.
    public var snr: Int? {
        guard let noise else { return nil }
        return rssi - noise
    }

    /// Coarse 0...1 signal quality derived from RSSI, used for sorting and display.
    /// (The scoring engine uses its own calibrated mapping.)
    public var signalQuality: Double {
        SignalQuality.normalized(rssi: Double(rssi))
    }
}

/// Deterministic RSSI → quality mapping shared by UI and engine.
public enum SignalQuality {
    /// -55 dBm or better is treated as excellent, -90 dBm or worse as unusable.
    public static func normalized(rssi: Double) -> Double {
        guard rssi.isFinite else { return 0 }
        let clamped = min(-30, max(-95, rssi))
        return min(1, max(0, (clamped + 95) / 40))
    }

    /// 0...4 "bars" for compact UI.
    public static func bars(rssi: Double) -> Int {
        let quality = normalized(rssi: rssi)
        return min(4, Int((quality * 4.0).rounded(.down)))
    }

    public static func description(rssi: Double) -> String {
        switch normalized(rssi: rssi) {
        case 0.8...: "Excellent"
        case 0.6..<0.8: "Good"
        case 0.4..<0.6: "Fair"
        case 0.2..<0.4: "Weak"
        default: "Very weak"
        }
    }
}
