import Foundation

/// Raw byte counters sampled from the Wi-Fi interface.
public struct InterfaceCounters: Codable, Sendable, Equatable {
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    public var timestamp: Date

    public init(receivedBytes: UInt64, sentBytes: UInt64, timestamp: Date) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.timestamp = timestamp
    }
}

/// Result of judging whether significant traffic is in flight.
///
/// The whole point is to stop the app from yanking a connection out from under a
/// video call or a large upload unless the current link is genuinely broken.
public struct TrafficAssessment: Codable, Sendable, Equatable {
    public var isActive: Bool
    public var incomingMbps: Double
    public var outgoingMbps: Double
    public var windowSeconds: TimeInterval
    public var reason: String

    public var totalMbps: Double { max(0, incomingMbps + outgoingMbps) }

    public init(
        isActive: Bool,
        incomingMbps: Double = 0,
        outgoingMbps: Double = 0,
        windowSeconds: TimeInterval = 0,
        reason: String = ""
    ) {
        self.isActive = isActive
        self.incomingMbps = incomingMbps
        self.outgoingMbps = outgoingMbps
        self.windowSeconds = windowSeconds
        self.reason = reason
    }

    public static let idle = TrafficAssessment(isActive: false, reason: "No significant traffic")
}

/// Pure, testable byte-delta → traffic-rate assessment.
public enum TrafficAnalysis {
    /// Minimum interval between counter samples for a meaningful rate.
    public static let minimumInterval: TimeInterval = 0.5

    public static func assess(
        previous: InterfaceCounters?,
        current: InterfaceCounters,
        thresholdMbps: Double
    ) -> TrafficAssessment {
        guard let previous else {
            return TrafficAssessment(
                isActive: false,
                windowSeconds: 0,
                reason: "Collecting interface statistics"
            )
        }
        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        guard interval >= minimumInterval else {
            return TrafficAssessment(
                isActive: false,
                windowSeconds: max(0, interval),
                reason: "Sampling interval too short"
            )
        }

        // Counters can reset when the interface is reconfigured; clamp instead of
        // producing a huge bogus spike.
        let receivedDelta = current.receivedBytes >= previous.receivedBytes
            ? current.receivedBytes - previous.receivedBytes
            : 0
        let sentDelta = current.sentBytes >= previous.sentBytes
            ? current.sentBytes - previous.sentBytes
            : 0

        let incoming = Double(receivedDelta) * 8.0 / interval / 1_000_000.0
        let outgoing = Double(sentDelta) * 8.0 / interval / 1_000_000.0
        let total = incoming + outgoing
        let active = total >= max(0.1, thresholdMbps)

        let reason: String
        if active {
            reason = String(format: "Active transfer at %.1f Mbps", total)
        } else if total > 0.05 {
            reason = String(format: "Light traffic at %.2f Mbps", total)
        } else {
            reason = "No significant traffic"
        }

        return TrafficAssessment(
            isActive: active,
            incomingMbps: incoming,
            outgoingMbps: outgoing,
            windowSeconds: interval,
            reason: reason
        )
    }
}
