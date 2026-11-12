import Foundation

/// Everything WiFiPilot keeps on disk, in one versioned document.
public struct StoredHistory: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var settings: AppSettings
    public var profiles: [String: NetworkProfile]
    public var decisions: [DecisionRecord]
    public var samples: [TimelineSample]

    public init(
        schemaVersion: Int = StoredHistory.currentSchemaVersion,
        settings: AppSettings = .default,
        profiles: [String: NetworkProfile] = [:],
        decisions: [DecisionRecord] = [],
        samples: [TimelineSample] = []
    ) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.profiles = profiles
        self.decisions = decisions
        self.samples = samples
    }
}

/// Local JSON persistence.
///
/// Deliberately plain JSON rather than a database: the dataset is tiny, a human can
/// inspect it, and it has no schema-migration machinery to get wrong. Writes are
/// atomic. Nothing is ever sent off the machine.
public actor PersistenceStore {
    public static let fileName = "wifipilot-history.json"
    public static let maximumDecisions = 2000
    public static let maximumSamples = 5000

    private let directory: URL
    private let fileURL: URL
    private var history: StoredHistory

    /// - Parameter directory: injectable so tests never touch the real Application Support.
    public init(directory: URL = PersistenceStore.defaultDirectory()) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(PersistenceStore.fileName)
        self.history = PersistenceStore.load(from: directory.appendingPathComponent(PersistenceStore.fileName))
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WiFiPilot", isDirectory: true)
    }

    public var location: URL { fileURL }

    // MARK: - Reads

    public func snapshot() -> StoredHistory { history }

    public func settings() -> AppSettings { history.settings }

    public func profile(forSSID ssid: String) -> NetworkProfile? {
        history.profiles[NetworkIdentity.key(forSSID: ssid)]
    }

    public func recentDecisions(limit: Int = 100) -> [DecisionRecord] {
        Array(history.decisions.suffix(max(0, limit)))
    }

    public func samples(since date: Date) -> [TimelineSample] {
        history.samples.filter { $0.timestamp >= date }
    }

    // MARK: - Writes

    public func updateSettings(_ settings: AppSettings) {
        history.settings = settings.sanitized()
    }

    public func upsert(profile: NetworkProfile) {
        history.profiles[profile.networkKey] = profile
    }

    public func record(_ record: DecisionRecord) {
        history.decisions.append(record)
        if history.decisions.count > Self.maximumDecisions {
            history.decisions.removeFirst(history.decisions.count - Self.maximumDecisions)
        }
    }

    /// Records the verified outcome of a switch attempt on its original log entry.
    public func updateVerification(recordID: UUID, succeeded: Bool, detail: String) {
        guard let index = history.decisions.firstIndex(where: { $0.id == recordID }) else { return }
        history.decisions[index].switchSucceeded = succeeded
        history.decisions[index].verificationDetail = detail
    }

    public func append(sample: TimelineSample) {
        history.samples.append(sample)
        if history.samples.count > Self.maximumSamples {
            history.samples.removeFirst(history.samples.count - Self.maximumSamples)
        }
    }

    /// Drops data older than the retention window.
    public func prune(now: Date = Date(), retentionDays: Int? = nil) {
        let days = max(1, retentionDays ?? history.settings.historyRetentionDays)
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        history.decisions.removeAll { $0.timestamp < cutoff }
        history.samples.removeAll { $0.timestamp < cutoff }
    }

    public func replace(history newHistory: StoredHistory) {
        history = newHistory
        history.settings = history.settings.sanitized()
    }

    // MARK: - Disk

    public func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(history)
        try data.write(to: fileURL, options: .atomic)
    }

    public func reload() {
        history = PersistenceStore.load(from: fileURL)
    }

    private static func load(from url: URL) -> StoredHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return StoredHistory() }
        guard var decoded = try? decoder.decode(StoredHistory.self, from: data) else {
            // Corrupt file: keep it for the user, start clean rather than crash.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return StoredHistory()
        }
        decoded.settings = decoded.settings.sanitized()
        return decoded
    }
}
