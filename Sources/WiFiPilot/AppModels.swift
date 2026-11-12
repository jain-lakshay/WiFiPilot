import Foundation
import WiFiPilotCore

/// Live association details for the Wi-Fi interface.
struct WiFiLink: Sendable, Equatable {
    var identity: NetworkIdentity
    var rssi: Int
    var noise: Int?
    var channel: Int?
    var security: WiFiSecurity
    var transmitRateMbps: Double

    var band: WiFiBand { WiFiBand(channel: channel) }

    var snr: Int? {
        guard let noise else { return nil }
        return rssi - noise
    }
}

/// One access point seen in a scan.
struct DiscoveredNetwork: Sendable, Equatable, Identifiable {
    var identity: NetworkIdentity
    var rssi: Int
    var noise: Int?
    var channel: Int?
    var security: WiFiSecurity
    var isKnownSaved: Bool

    var id: String { identity.id }
    var band: WiFiBand { WiFiBand(channel: channel) }
}

/// A row in the dashboard's network list / comparison table.
struct NetworkRow: Identifiable, Equatable {
    var snapshot: CandidateSnapshot
    var metrics: NetworkMetrics?
    var isConnected: Bool
    var lastSeen: Date
    var channel: Int?
    var security: WiFiSecurity
    var band: WiFiBand

    var id: String { snapshot.id }
}
