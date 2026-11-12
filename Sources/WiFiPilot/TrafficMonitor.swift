import Darwin
import Foundation
import WiFiPilotCore

/// Reads interface byte counters to decide whether a significant transfer is running.
///
/// Uses `getifaddrs` on the Wi-Fi interface only, so VPN or other interfaces cannot
/// inflate the estimate. Counters are 32-bit on macOS; the analysis step treats a
/// decrease as a reset instead of reporting a bogus spike.
final class TrafficMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: InterfaceCounters?

    func sample(interfaceName: String?, thresholdMbps: Double) -> TrafficAssessment {
        guard let counters = Self.readCounters(interfaceName: interfaceName) else {
            return .idle
        }
        lock.lock()
        let previousCounters = previous
        previous = counters
        lock.unlock()
        return TrafficAnalysis.assess(
            previous: previousCounters,
            current: counters,
            thresholdMbps: thresholdMbps
        )
    }

    func reset() {
        lock.lock()
        previous = nil
        lock.unlock()
    }

    static func readCounters(interfaceName: String?) -> InterfaceCounters? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var found = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let entry = cursor {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            if let address = entry.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: entry.pointee.ifa_name)
                let matches = interfaceName.map { $0 == name } ?? name.hasPrefix("en")
                if matches, let rawData = entry.pointee.ifa_data {
                    let data = rawData.assumingMemoryBound(to: if_data.self)
                    received += UInt64(data.pointee.ifi_ibytes)
                    sent += UInt64(data.pointee.ifi_obytes)
                    found = true
                }
            }
            cursor = entry.pointee.ifa_next
        }

        guard found else { return nil }
        return InterfaceCounters(receivedBytes: received, sentBytes: sent, timestamp: Date())
    }
}
