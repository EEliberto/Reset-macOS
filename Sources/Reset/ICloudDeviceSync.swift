import Foundation
import CryptoKit

struct DevicePresence: Codable, Sendable {
    let deviceID: String
    let deviceName: String
    let serverPriority: Int
    let lastHeartbeat: Date
    let frontmostProvider: ProviderKind?
    var telegramConfigured: Bool? = nil
}

struct SharedDevicePreference: Codable, Sendable {
    let preferredServerID: String
    let updatedAt: Date
}

struct TelegramServiceLease: Codable, Sendable {
    let holderDeviceID: String
    let holderDeviceName: String
    let leaseID: String
    let expiresAt: Date
}

struct SharedTelegramConfiguration: Codable, Sendable {
    let token: String?
    let chatID: String
    let updatedAt: Date
}

struct SharedUsageHistory: Codable, Sendable {
    let schemaVersion: Int
    let deviceID: String
    let deviceName: String
    let updatedAt: Date
    let points: [UsageHistoryPoint]
}

struct TelegramNotificationClaim: Codable, Sendable {
    let eventID: String
    let claimID: String
    let deviceID: String
    let claimedAt: Date
}

struct TelegramNotificationMessage: Codable, Sendable {
    let messageID: Int
    let chatID: Int64
    let sentAt: Date
}

struct SyncMaintenanceReport: Sendable {
    let activityFiles: Int
    let deviceFiles: Int
    let eventFiles: Int
    var total: Int { activityFiles + deviceFiles + eventFiles }
}

actor ICloudDeviceSync {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent(".Reset!", isDirectory: true)
    }

    var displayPath: String { "iCloud Drive/.Reset!" }

    func isAvailable() -> Bool {
        let available = FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path)
        if available {
            try? ensureDirectory(root, hidden: true)
            requestDownloadIfNeeded(for: root)
            // Kick iCloud downloads for the coordination files secondary Macs need.
            requestDownloadIfNeeded(for: root.appendingPathComponent("configuration", isDirectory: true))
            requestDownloadIfNeeded(for: root.appendingPathComponent("devices", isDirectory: true))
            requestDownloadIfNeeded(for: root.appendingPathComponent("shared", isDirectory: true))
            requestDownloadIfNeeded(for: root.appendingPathComponent("leases", isDirectory: true))
            requestDownloadIfNeeded(for: root.appendingPathComponent("usage-history", isDirectory: true))
        }
        return available
    }

    func telegramConfiguration() -> SharedTelegramConfiguration? {
        let url = root.appendingPathComponent("configuration/telegram.json")
        requestDownloadIfNeeded(for: url)
        if let remote = try? read(SharedTelegramConfiguration.self, from: url) {
            cacheTelegramConfiguration(remote)
            return remote
        }
        return cachedTelegramConfiguration()
    }

    func setTelegramConfiguration(token: String, chatID: String) throws {
        let config = SharedTelegramConfiguration(token: token, chatID: chatID, updatedAt: Date())
        try write(config, to: root.appendingPathComponent("configuration/telegram.json"))
        cacheTelegramConfiguration(config)
    }

    func writePresence(_ presence: DevicePresence) throws {
        try write(presence, to: root.appendingPathComponent("devices/\(presence.deviceID).json"))
    }

    /// Every active Reset! device can coordinate prediction. Devices explicitly
    /// marked as servers always win while they are healthy.
    func electedServer(preferredServerID: String?, now: Date = Date()) -> DevicePresence? {
        let directory = root.appendingPathComponent("devices", isDirectory: true)
        requestDownloadIfNeeded(for: directory)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let active = urls.compactMap { try? read(DevicePresence.self, from: $0) }
            .filter { now.timeIntervalSince($0.lastHeartbeat) < 180 }
        return Self.preferredCoordinator(from: active, preferredServerID: preferredServerID)
    }

    nonisolated static func preferredCoordinator(from active: [DevicePresence], preferredServerID: String? = nil) -> DevicePresence? {
        active.sorted {
            let lhsPreferred = $0.deviceID == preferredServerID
            let rhsPreferred = $1.deviceID == preferredServerID
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            if $0.serverPriority != $1.serverPriority { return $0.serverPriority > $1.serverPriority }
            return $0.deviceID < $1.deviceID
        }.first
    }

    func preferredServerID() -> String? {
        let url = root.appendingPathComponent("configuration/preferred-server.json")
        requestDownloadIfNeeded(for: url)
        return (try? read(SharedDevicePreference.self, from: url))?.preferredServerID
    }

    func setPreferredServerID(_ deviceID: String) throws {
        try write(
            SharedDevicePreference(preferredServerID: deviceID, updatedAt: Date()),
            to: root.appendingPathComponent("configuration/preferred-server.json")
        )
    }

    func acquireOrRenewTelegramLease(device: DevicePresence, now: Date = Date()) throws -> Bool {
        let url = root.appendingPathComponent("leases/telegram.json")
        requestDownloadIfNeeded(for: url)
        if let existing = try? read(TelegramServiceLease.self, from: url),
           existing.expiresAt > now,
           existing.holderDeviceID != device.deviceID {
            // Another healthy coordinator still holds the lease.
            return false
        }
        let leaseID: String
        if let existing = try? read(TelegramServiceLease.self, from: url), existing.holderDeviceID == device.deviceID {
            leaseID = existing.leaseID
        } else {
            leaseID = UUID().uuidString.lowercased()
        }
        let lease = TelegramServiceLease(
            holderDeviceID: device.deviceID,
            holderDeviceName: device.deviceName,
            leaseID: leaseID,
            expiresAt: now.addingTimeInterval(90)
        )
        try write(lease, to: url)
        return (try? read(TelegramServiceLease.self, from: url))?.leaseID == leaseID
    }

    func telegramLease(now: Date = Date()) -> TelegramServiceLease? {
        guard let lease = try? read(TelegramServiceLease.self, from: root.appendingPathComponent("leases/telegram.json")),
              lease.expiresAt > now else { return nil }
        return lease
    }

    func releaseTelegramLease(deviceID: String) {
        let url = root.appendingPathComponent("leases/telegram.json")
        guard let lease = try? read(TelegramServiceLease.self, from: url),
              lease.holderDeviceID == deviceID else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func claimTelegramNotification(eventID: String, deviceID: String, now: Date = Date()) throws -> Bool {
        let key = SHA256.hash(data: Data(eventID.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent("telegram-notifications/claims/\(key).json")
        if (try? read(TelegramNotificationClaim.self, from: url)) != nil { return false }
        let claim = TelegramNotificationClaim(eventID: eventID, claimID: UUID().uuidString, deviceID: deviceID, claimedAt: now)
        try write(claim, to: url)
        return (try? read(TelegramNotificationClaim.self, from: url))?.claimID == claim.claimID
    }

    func claimTelegramUpdate(updateID: Int, deviceID: String, now: Date = Date()) throws -> Bool {
        let url = root.appendingPathComponent("telegram-updates/\(updateID).json")
        let claim = TelegramNotificationClaim(
            eventID: String(updateID),
            claimID: UUID().uuidString,
            deviceID: deviceID,
            claimedAt: now
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try encoder.encode(claim).write(to: url, options: .withoutOverwriting)
            return true
        } catch {
            if (error as? CocoaError)?.code == .fileWriteFileExists { return false }
            throw error
        }
    }

    func releaseTelegramNotificationClaim(eventID: String) {
        let key = SHA256.hash(data: Data(eventID.utf8)).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent("telegram-notifications/claims/\(key).json")
        )
    }

    func recordTelegramNotification(messageID: Int, chatID: Int64, sentAt: Date = Date()) throws {
        try write(
            TelegramNotificationMessage(messageID: messageID, chatID: chatID, sentAt: sentAt),
            to: root.appendingPathComponent("telegram-notifications/messages/\(messageID).json")
        )
    }

    func expiredTelegramNotifications(before cutoff: Date) -> [TelegramNotificationMessage] {
        let directory = root.appendingPathComponent("telegram-notifications/messages", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { try? read(TelegramNotificationMessage.self, from: $0) }.filter { $0.sentAt < cutoff }
    }

    func removeTelegramNotificationRecord(messageID: Int) {
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent("telegram-notifications/messages/\(messageID).json")
        )
    }

    func allDevices() -> [DevicePresence] {
        let directory = root.appendingPathComponent("devices", isDirectory: true)
        requestDownloadIfNeeded(for: directory)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { try? read(DevicePresence.self, from: $0) }
            .sorted { $0.lastHeartbeat > $1.lastHeartbeat }
    }

    func writeUsageHistory(deviceID: String, deviceName: String, points: [UsageHistoryPoint]) throws {
        try write(
            SharedUsageHistory(
                schemaVersion: 1,
                deviceID: deviceID,
                deviceName: deviceName,
                updatedAt: Date(),
                points: points
            ),
            to: root.appendingPathComponent("usage-history/\(deviceID).json")
        )
    }

    func allUsageHistory() -> [UsageHistoryPoint] {
        let directory = root.appendingPathComponent("usage-history", isDirectory: true)
        requestDownloadIfNeeded(for: directory)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls.compactMap { url in
            requestDownloadIfNeeded(for: url)
            return try? read(SharedUsageHistory.self, from: url)
        }
            .filter { $0.schemaVersion == 1 }
            .flatMap(\.points)
    }

    func cleanup(now: Date = Date()) -> SyncMaintenanceReport {
        let activity = cleanupFiles(in: "activity", olderThan: now)
        // Quota snapshots from schema v3 and earlier are obsolete: quotas are local-only.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("shared/current.json"))
        let devices = cleanupPresence(in: "devices", olderThan: now.addingTimeInterval(-30 * 86_400))
        let events = cleanupFiles(in: "events", olderThan: now.addingTimeInterval(-30 * 86_400))
            + cleanupFiles(in: "acknowledgements", olderThan: now.addingTimeInterval(-60 * 86_400))
            + cleanupFiles(in: "telegram-notifications/claims", olderThan: now.addingTimeInterval(-7 * 86_400))
            + cleanupFiles(in: "telegram-updates", olderThan: now.addingTimeInterval(-7 * 86_400))
        return SyncMaintenanceReport(activityFiles: activity, deviceFiles: devices, eventFiles: events)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent(), hidden: false)
        let data = try encoder.encode(value)
        try writeData(data, to: url)
    }

    /// Only the iCloud Drive `/.Reset!` root should be Finder-hidden. Nested
    /// sync files stay normal so packaging/copy paths never inherit UF_HIDDEN.
    private func ensureDirectory(_ url: URL, hidden: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isHidden = hidden
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        final class Box: @unchecked Sendable {
            var error: Error?
        }
        let box = Box()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                try data.write(to: coordinated, options: .atomic)
            } catch {
                box.error = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError = box.error { throw writeError }
    }

    private func requestDownloadIfNeeded(for url: URL) {
        var isUbiquitous: AnyObject?
        try? (url as NSURL).getResourceValue(&isUbiquitous, forKey: .isUbiquitousItemKey)
        guard (isUbiquitous as? Bool) == true else { return }
        var downloaded: AnyObject?
        try? (url as NSURL).getResourceValue(&downloaded, forKey: .ubiquitousItemDownloadingStatusKey)
        let status = downloaded as? URLUbiquitousItemDownloadingStatus
        if status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    private static let telegramCacheKey = "reset.cachedTelegramConfiguration"

    private func cacheTelegramConfiguration(_ config: SharedTelegramConfiguration) {
        guard let data = try? encoder.encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.telegramCacheKey)
    }

    private func cachedTelegramConfiguration() -> SharedTelegramConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: Self.telegramCacheKey) else { return nil }
        return try? decoder.decode(SharedTelegramConfiguration.self, from: data)
    }

    private func cleanupPresence(in directoryName: String, olderThan cutoff: Date) -> Int {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for url in urls {
            guard let presence = try? read(DevicePresence.self, from: url), presence.lastHeartbeat < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private func cleanupFiles(in directoryName: String, olderThan cutoff: Date) -> Int {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var removed = 0
        for url in urls {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try readData(from: url)
        return try decoder.decode(type, from: data)
    }

    private func readData(from url: URL) throws -> Data {
        final class Box: @unchecked Sendable {
            var data: Data?
            var error: Error?
        }
        let box = Box()
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            do {
                box.data = try Data(contentsOf: coordinated)
            } catch {
                box.error = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let error = box.error { throw error }
        guard let data = box.data else { throw CocoaError(.fileReadUnknown) }
        return data
    }
}
