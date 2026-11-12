
import Foundation
import WiFiPilotCore

/// Error returned when macOS cannot associate with a Wi-Fi network.
struct NetworkAssociationError: Error, Sendable {
    let message: String
}

/// Executes a Wi-Fi association and verifies the connection.
struct SwitchingManager: Sendable {

    struct Outcome: Sendable, Equatable {
        var success: Bool
        var verified: Bool
        var detail: String
        var elapsed: TimeInterval

        static func failure(
            _ detail: String,
            elapsed: TimeInterval = 0
        ) -> Outcome {
            Outcome(
                success: false,
                verified: false,
                detail: detail,
                elapsed: elapsed
            )
        }
    }

    /// How long to wait for the association to appear.
    var associationTimeout: TimeInterval = 25

    /// Internet verification attempts after association (2 seconds apart).
    var verificationAttempts: Int = 3

    func performSwitch(
        to target: NetworkIdentity,
        scanner: WiFiScanner,
        verifier: @Sendable () async -> Bool
    ) async -> Outcome {

        let started = Date()

        // 1. Confirm that the candidate is still visible and saved.
        let visible: [DiscoveredNetwork]

        do {
            visible = try await scanner.scan()
        } catch {
            return .failure(
                "Could not rescan before switching: \(error.localizedDescription)"
            )
        }

        let matches = visible.filter {
            $0.identity.networkKey == target.networkKey
        }

        guard let best = matches.max(by: { $0.rssi < $1.rssi }) else {
            return .failure(
                "\(target.displayName) is no longer visible; switch cancelled."
            )
        }

        guard best.isKnownSaved else {
            return .failure(
                "\(target.displayName) is not a saved network; WiFiPilot does not prompt for credentials."
            )
        }

        // 2. Associate using system-managed credentials.
        let interfaceName = await scanner.interfaceName

        var usedNetworksetup = false
        var networksetupError: String?

        if let interfaceName {
            switch Self.associateWithSystemCredentials(
                ssid: best.identity.ssid,
                interfaceName: interfaceName
            ) {
            case .success:
                usedNetworksetup = true

            case .failure(let error):
                networksetupError = error.message
            }
        }

        if !usedNetworksetup {

            // CoreWLAN's credential-less association is only attempted
            // for open networks. WiFiPilot never handles Wi-Fi passwords.
            guard best.security == .open else {
                let reason = networksetupError.map {
                    " (\($0))"
                } ?? ""

                return .failure(
                    "macOS could not join \(best.identity.displayName) with saved credentials\(reason). "
                    + "WiFiPilot never asks for or stores Wi-Fi passwords."
                )
            }

            do {
                try await scanner.associateUsingSavedCredentials(
                    ssid: best.identity.ssid
                )
            } catch {
                return .failure(
                    "macOS could not join open network \(best.identity.displayName). "
                    + "(\(error.localizedDescription))"
                )
            }
        }

        // 3. Wait for the association to complete.
        let associated = await waitForAssociation(
            ssid: best.identity.ssid,
            scanner: scanner,
            timeout: associationTimeout
        )

        guard associated else {
            return .failure(
                "Wi-Fi did not associate with \(best.identity.displayName) within \(Int(associationTimeout)) s.",
                elapsed: Date().timeIntervalSince(started)
            )
        }

        // 4. Verify that the connection actually reaches the internet.
        var verified = false

        let attempts = max(1, verificationAttempts)

        for attempt in 0..<attempts {
            if await verifier() {
                verified = true
                break
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(for: .seconds(2))
            }
        }

        let elapsed = Date().timeIntervalSince(started)

        let path = usedNetworksetup
            ? "system credentials"
            : "CoreWLAN association"

        if verified {
            return Outcome(
                success: true,
                verified: true,
                detail: "Associated with \(best.identity.displayName) via \(path) and verified internet access in \(String(format: "%.1f", elapsed)) s.",
                elapsed: elapsed
            )
        }

        return Outcome(
            success: true,
            verified: false,
            detail: "Associated with \(best.identity.displayName) via \(path), but internet access could not be verified after \(attempts) attempts.",
            elapsed: elapsed
        )
    }

    // MARK: - Association Verification

    private func waitForAssociation(
        ssid: String,
        scanner: WiFiScanner,
        timeout: TimeInterval
    ) async -> Bool {

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let link = await scanner.currentLink(),
               link.identity.ssid.caseInsensitiveCompare(ssid) == .orderedSame {
                return true
            }

            try? await Task.sleep(for: .milliseconds(900))
        }

        return false
    }

    // MARK: - System Credential Association

    /// Uses credentials already stored by macOS.
    /// The SSID is passed as a separate process argument, never through a shell.
    nonisolated static func associateWithSystemCredentials(
        ssid: String,
        interfaceName: String
    ) -> Result<Void, NetworkAssociationError> {

        let process = Process()

        process.executableURL = URL(
            fileURLWithPath: "/usr/sbin/networksetup"
        )

        process.arguments = [
            "-setairportnetwork",
            interfaceName,
            ssid
        ]

        process.standardOutput = FileHandle.nullDevice

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure(
                NetworkAssociationError(
                    message: error.localizedDescription
                )
            )
        }

        process.waitUntilExit()

        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let message = String(
            data: data,
            encoding: .utf8
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 0 {
            return .success(())
        }

        return .failure(
            NetworkAssociationError(
                message: message.isEmpty
                    ? "networksetup exited with status \(process.terminationStatus)"
                    : message
            )
        )
    }
}

