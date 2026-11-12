import AppKit
import Combine
import CoreLocation
import CoreWLAN
import Foundation
import WiFiPilotCore

/// Requests and tracks Location Services authorisation.
///
/// macOS requires location permission for SSID/BSSID visibility and for scan results
/// (since macOS 10.15, enforced more strictly from Sonoma). WiFiPilot never tries to
/// work around that; without permission the UI explains the limitation instead.
@MainActor
final class LocationPermission: NSObject, ObservableObject {
    @Published private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        self.status = .notDetermined
        super.init()
        manager.delegate = self
        self.status = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        status == .authorizedAlways || status == .authorized
    }

    var statusDescription: String {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return "Location access granted — SSIDs and scans available."
        case .denied:
            return "Location access denied. macOS hides Wi-Fi names and scan results until it is enabled in System Settings → Privacy & Security → Location Services."
        case .restricted:
            return "Location access is restricted by system policy."
        case .notDetermined:
            return "Location access has not been requested yet."
        @unknown default:
            return "Unknown location authorisation status."
        }
    }

    func request() {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension LocationPermission: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.status = newStatus
        }
    }
}

/// Reads Wi-Fi state and performs scans through CoreWLAN.
///
/// All CoreWLAN access is confined to this actor. Scan results are converted into
/// plain `Sendable` values before crossing the actor boundary.
actor WiFiScanner {
    enum ScannerError: LocalizedError {
        case noInterface
        case scanFailed(String)
        case associateFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInterface:
                return "No Wi-Fi interface was found. WiFiPilot needs an active 802.11 interface."
            case .scanFailed(let message):
                return "The Wi-Fi scan failed: \(message)"
            case .associateFailed(let message):
                return "Association failed: \(message)"
            }
        }
    }

    private let client = CWWiFiClient.shared()
    private var knownSSIDs: Set<String> = []

    var interfaceName: String? {
        client.interface()?.interfaceName
    }

    /// Current association, or nil when Wi-Fi is off/unassociated.
    func currentLink() -> WiFiLink? {
        guard let interface = client.interface(), interface.powerOn() else { return nil }
        guard let ssid = interface.ssid(), !ssid.isEmpty else { return nil }

        let noise = interface.noiseMeasurement()
        return WiFiLink(
            identity: NetworkIdentity(ssid: ssid, bssid: interface.bssid()),
            rssi: interface.rssiValue(),
            noise: noise != 0 ? noise : nil,
            channel: interface.wlanChannel()?.channelNumber,
            security: Self.map(security: interface.security()),
            transmitRateMbps: interface.transmitRate()
        )
    }

    /// Refreshes the list of SSIDs macOS has credentials for.
    ///
    /// There is no public CoreWLAN API to enumerate saved networks, so this uses the
    /// long-standing `networksetup` command. It only lists SSIDs; no password or key
    /// material is read, stored or transmitted.
    @discardableResult
    func refreshKnownNetworks() -> Set<String> {
        guard let name = client.interface()?.interfaceName else {
            knownSSIDs = []
            return []
        }
        knownSSIDs = Self.preferredNetworks(interfaceName: name)
        return knownSSIDs
    }

    func scan() throws -> [DiscoveredNetwork] {
        guard let interface = client.interface() else { throw ScannerError.noInterface }
        let networks: Set<CWNetwork>
        do {
            networks = try interface.scanForNetworks(withSSID: nil)
        } catch {
            throw ScannerError.scanFailed(error.localizedDescription)
        }

        var results: [DiscoveredNetwork] = []
        results.reserveCapacity(networks.count)
        for network in networks {
            guard let ssid = network.ssid, !ssid.isEmpty else { continue }
            let noise = network.noiseMeasurement
            results.append(
                DiscoveredNetwork(
                    identity: NetworkIdentity(ssid: ssid, bssid: network.bssid),
                    rssi: network.rssiValue,
                    noise: noise != 0 ? noise : nil,
                    channel: network.wlanChannel?.channelNumber,
                    security: Self.map(network: network),
                    isKnownSaved: knownSSIDs.contains(ssid.lowercased())
                )
            )
        }
        return results.sorted { $0.rssi > $1.rssi }
    }

    /// Attempts an association without a password.
    ///
    /// CoreWLAN cannot read Keychain credentials, so this only succeeds for open
    /// networks or where the system supplies the credential. It exists as a fallback
    /// for `networksetup`. Callers never pass a password through WiFiPilot.
    func associateUsingSavedCredentials(ssid: String) throws {
        guard let interface = client.interface() else { throw ScannerError.noInterface }
        let networks: Set<CWNetwork>
        do {
            networks = try interface.scanForNetworks(withSSID: nil)
        } catch {
            throw ScannerError.scanFailed(error.localizedDescription)
        }
        guard let network = networks.first(where: { $0.ssid?.caseInsensitiveCompare(ssid) == .orderedSame }) else {
            throw ScannerError.associateFailed("Network is not visible")
        }
        do {
            try interface.associate(to: network, password: nil)
        } catch {
            throw ScannerError.associateFailed(error.localizedDescription)
        }
    }

    // MARK: - Mapping

    nonisolated static func map(security: CWSecurity) -> WiFiSecurity {
        switch security {
        case .none, .OWE, .oweTransition:
            return .open
        case .WEP, .dynamicWEP:
            return .wep
        case .wpaPersonal, .wpaPersonalMixed:
            return .wpaPersonal
        case .wpa2Personal, .personal:
            return .wpa2Personal
        case .wpa3Personal, .wpa3Transition:
            return .wpa3Personal
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise, .enterprise:
            return .enterprise
        default:
            return .unknown
        }
    }

    nonisolated static func map(network: CWNetwork) -> WiFiSecurity {
        if network.supportsSecurity(.wpa2Enterprise) || network.supportsSecurity(.wpa3Enterprise)
            || network.supportsSecurity(.wpaEnterprise) || network.supportsSecurity(.enterprise) {
            return .enterprise
        }
        if network.supportsSecurity(.wpa3Personal) || network.supportsSecurity(.wpa3Transition) {
            return .wpa3Personal
        }
        if network.supportsSecurity(.wpa2Personal) || network.supportsSecurity(.personal) {
            return .wpa2Personal
        }
        if network.supportsSecurity(.wpaPersonal) || network.supportsSecurity(.wpaPersonalMixed) {
            return .wpaPersonal
        }
        if network.supportsSecurity(.WEP) || network.supportsSecurity(.dynamicWEP) {
            return .wep
        }
        return .open
    }

    // MARK: - Saved networks

    nonisolated static func preferredNetworks(interfaceName: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listpreferredwirelessnetworks", interfaceName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }

        var ssids = Set<String>()
        for line in text.split(separator: "\n").dropFirst() {
            let ssid = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ssid.isEmpty { ssids.insert(ssid.lowercased()) }
        }
        return ssids
    }
}
