import Foundation
import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

private final class AppModelObserverStore: @unchecked Sendable {
    var appActivation: NSObjectProtocol?
    var quitRequest: NSObjectProtocol?

    deinit {
        if let appActivation {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivation)
        }
        if let quitRequest {
            NotificationCenter.default.removeObserver(quitRequest)
        }
    }
}

private struct DeviceNotificationClient: Sendable {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    @discardableResult
    func scheduleReset(identifier: String, title: String, body: String, at date: Date, silent: Bool = false) async -> Bool {
        guard date > Date() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    func notifyNow(identifier: String, title: String, body: String, silent: Bool = false) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancel(identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelResetNotifications(identifierPrefixes: [String]) async {
        guard !identifierPrefixes.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { identifier in identifierPrefixes.contains { identifier.hasPrefix($0) } }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        let deliveredIdentifiers = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { identifier in identifierPrefixes.contains { identifier.hasPrefix($0) } }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
    }

    func cleanup(now: Date = Date()) async -> Int {
        let center = UNUserNotificationCenter.current()
        let owns: (String) -> Bool = { $0.hasPrefix("reset.") }
        let pending = await center.pendingNotificationRequests()
        let expiredPending = pending.compactMap { request -> String? in
            guard owns(request.identifier) else { return nil }
            guard let trigger = request.trigger else { return request.identifier }
            let nextDate = (trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                ?? (trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? .distantPast
            return nextDate < now ? request.identifier : nil
        }
        center.removePendingNotificationRequests(withIdentifiers: expiredPending)
        let delivered = await center.deliveredNotifications()
        let oldDelivered = delivered.compactMap { notification -> String? in
            guard owns(notification.request.identifier), notification.date < now.addingTimeInterval(-30 * 86_400) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: oldDelivered)
        return expiredPending.count + oldDelivered.count
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statuses: [AgentStatus] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeProvider: ProviderKind?
    @Published private(set) var frontmostAgentProvider: ProviderKind?
    @Published private(set) var isElectedServer = false
    @Published private(set) var currentServerName = "未发现服务器"
    @Published private(set) var knownDevices: [DevicePresence] = []
    @Published var preferredServerID = ""
    @Published private(set) var iCloudSyncStatus = "尚未协调"
    @Published var telegramToken = ""
    @Published var telegramChatID = ""
    @Published var telegramEnabled = false
    @Published private(set) var isConfirmingTelegram = false
    @Published private(set) var telegramVerificationMessage = ""
    @Published var deviceNotificationsEnabled = false
    @Published private(set) var enabledProviders: [ProviderKind: Bool]
    @Published var grokBuildIntegrationEnabled = false
    @Published private(set) var buildIntegrationStatuses: [BuildIntegrationStatus] = []
    @Published var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published var message = "准备就绪"
    @Published private(set) var providerOrder: [ProviderKind]
    @Published private(set) var appVersion = AppUpdateChecker.currentVersion

    private let detector = AgentDetector()
    private let telegram = TelegramBotClient()
    private let deviceNotifications = DeviceNotificationClient()
    private let buildIntegrationMonitor = BuildIntegrationMonitor()
    private let deviceSync = ICloudDeviceSync()
    private let deviceID: String
    private let deviceName: String
    private var pollingTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private var deviceSyncTask: Task<Void, Never>?
    private var telegramConfigurationTask: Task<Void, Never>?
    private var buildIntegrationTask: Task<Void, Never>?
    private var grokEventOffset: UInt64 = 0
    private var refreshPending = false
    private var holdsTelegramLease = false
    private let observerStore = AppModelObserverStore()
    private var pendingResetEvents: [ResetEvent]

    private static let deviceNotificationsKey = "deviceNotificationsEnabled"
    private static let providerEnabledKeyPrefix = "providerEnabled."
    private static let lowQuotaStateKeyPrefix = "lowQuotaState."
    private static let grokBuildIntegrationKey = "buildIntegration.grokBuild.enabled"
    private static let pendingResetEventsKey = "pendingResetEvents"
    private static let scheduledDeviceResetNotificationsKey = "scheduledDeviceResetNotifications"
    private static let deviceIDKey = "deviceID"
    private static let lastActiveProviderKey = "lastActiveProvider"
    private static let menuUsageCacheKey = "menuUsageCache"
    private static let menuAPICacheKey = "menuAPICache"
    private static let cursorMeterKey = "cursorActiveMeter"
    private static let antigravityCreditsActiveKey = "antigravityCreditsActive"
    private static let lastMaintenanceKey = "lastMaintenanceAt"
    private static let lastServerSeenKey = "lastServerSeenAt"

    init() {
        let defaults = UserDefaults.standard
        if let existingID = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = existingID
        } else {
            let newID = UUID().uuidString.lowercased()
            defaults.set(newID, forKey: Self.deviceIDKey)
            deviceID = newID
        }
        deviceName = Host.current().localizedName ?? "Mac"
        providerOrder = Self.loadProviderOrder()
        pendingResetEvents = Self.loadPendingResetEvents()
        enabledProviders = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { provider in
            let key = Self.providerEnabledKeyPrefix + provider.rawValue
            return (provider, defaults.object(forKey: key) as? Bool ?? true)
        })
        telegramToken = SecureTokenStore.loadTelegramToken() ?? ""
        telegramChatID = ""
        // One-time migration: purge any residual cleartext token data cached by
        // previous versions that stored Telegram tokens in UserDefaults.
        UserDefaults.standard.removeObject(forKey: "reset.cachedTelegramConfiguration")
        deviceNotificationsEnabled = UserDefaults.standard.bool(forKey: Self.deviceNotificationsKey)
        grokBuildIntegrationEnabled = defaults.bool(forKey: Self.grokBuildIntegrationKey)
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginRequiresApproval = SMAppService.mainApp.status == .requiresApproval
        telegramEnabled = false
        let rememberedProvider = defaults.string(forKey: Self.lastActiveProviderKey).flatMap(ProviderKind.init(rawValue:))
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let provider = provider(for: frontmost)
            activeProvider = provider ?? rememberedProvider
            frontmostAgentProvider = provider
            if let provider { defaults.set(provider.rawValue, forKey: Self.lastActiveProviderKey) }
        } else {
            activeProvider = rememberedProvider
        }
        observerStore.appActivation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                let provider = self?.provider(for: app)
                self?.frontmostAgentProvider = provider
                if let provider {
                    self?.activeProvider = provider
                    UserDefaults.standard.set(provider.rawValue, forKey: Self.lastActiveProviderKey)
                }
            }
        }
        observerStore.quitRequest = NotificationCenter.default.addObserver(
            forName: .quitResetRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.quitApplication() }
        }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        deviceSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronizeDevices()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        if grokBuildIntegrationEnabled {
            try? buildIntegrationMonitor.setGrokHookEnabled(true)
        }
        grokEventOffset = buildIntegrationMonitor.currentGrokEventOffset()
        buildIntegrationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollBuildIntegrations()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        UserDefaults.standard.removeObject(forKey: "usageHistory.v1")
        Task { [deviceSync] in await deviceSync.purgeLegacyUsageHistory() }
        _ = SparkleUpdateController.shared
    }

    deinit {
        pollingTask?.cancel()
        autoRefreshTask?.cancel()
        deviceSyncTask?.cancel()
        telegramConfigurationTask?.cancel()
        buildIntegrationTask?.cancel()
    }

    func quitApplication() {
        pollingTask?.cancel()
        autoRefreshTask?.cancel()
        deviceSyncTask?.cancel()
        buildIntegrationTask?.cancel()
        Task {
            await deviceSync.releaseTelegramLease(deviceID: deviceID)
            NSApplication.shared.terminate(nil)
        }
    }

    var deviceRoleSummary: String {
        isElectedServer ? "当前服务器" : "待命"
    }

    func setPreferredServer(_ deviceID: String) {
        preferredServerID = deviceID
        Task {
            try? await deviceSync.setPreferredServerID(deviceID)
            await synchronizeDevices()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "无法更新开机自启：\(error.localizedDescription)"
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginRequiresApproval = SMAppService.mainApp.status == .requiresApproval
        if launchAtLoginRequiresApproval {
            message = "请在系统设置的登录项中允许 Reset!"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setBuildIntegration(_ integration: BuildIntegrationKind, enabled: Bool) {
        Task {
            do {
                try buildIntegrationMonitor.setGrokHookEnabled(enabled)
                grokBuildIntegrationEnabled = enabled
                UserDefaults.standard.set(enabled, forKey: Self.grokBuildIntegrationKey)
                grokEventOffset = buildIntegrationMonitor.currentGrokEventOffset()
                updateBuildIntegrationStatus(integration, event: nil)
            } catch {
                grokBuildIntegrationEnabled = false
                UserDefaults.standard.set(false, forKey: Self.grokBuildIntegrationKey)
                message = "Grok CLI 接入失败：\(error.localizedDescription)"
            }
        }
    }

    private func pollBuildIntegrations() async {
        if grokBuildIntegrationEnabled {
            let batch = buildIntegrationMonitor.grokEvents(fromOffset: grokEventOffset)
            grokEventOffset = batch.nextOffset
            if let event = batch.events.last {
                updateBuildIntegrationStatus(.grokBuild, event: event)
            }
        } else {
            grokEventOffset = buildIntegrationMonitor.currentGrokEventOffset()
        }
    }

    private func updateBuildIntegrationStatus(_ integration: BuildIntegrationKind, event: BuildIntegrationEvent?) {
        let status = BuildIntegrationStatus(
            integration: integration,
            state: event?.state,
            observedAt: event?.observedAt,
            summary: event?.summary
        )
        if let index = buildIntegrationStatuses.firstIndex(where: { $0.integration == integration }) {
            if event != nil {
                buildIntegrationStatuses[index] = status
            } else {
                buildIntegrationStatuses.remove(at: index)
            }
        } else if event != nil {
            buildIntegrationStatuses.append(status)
        }
    }

    var visibleBuildIntegrations: [BuildIntegrationStatus] {
        BuildIntegrationKind.allCases.compactMap { integration in
            guard grokBuildIntegrationEnabled else { return nil }
            return buildIntegrationStatuses.first(where: { $0.integration == integration })
                ?? BuildIntegrationStatus(integration: integration, state: nil, observedAt: nil, summary: nil)
        }
    }

    func providerEnabled(_ provider: ProviderKind) -> Bool {
        enabledProviders[provider] ?? true
    }

    func setProvider(_ provider: ProviderKind, enabled: Bool) {
        enabledProviders[provider] = enabled
        UserDefaults.standard.set(enabled, forKey: Self.providerEnabledKeyPrefix + provider.rawValue)
        if !enabled {
            statuses.removeAll { $0.provider == provider }
            if activeProvider == provider { activeProvider = visibleStatuses.first?.provider }
            let removedEvents = pendingResetEvents.filter { $0.providerName == provider.title }
            pendingResetEvents.removeAll { $0.providerName == provider.title }
            savePendingResetEvents()
            var scheduled = Self.loadScheduledDeviceResetNotifications()
            scheduled = scheduled.filter { !$0.key.hasPrefix("\(provider.title)|") }
            Self.saveScheduledDeviceResetNotifications(scheduled)
            deviceNotifications.cancel(identifiers: removedEvents.map(\.id))
            Task {
                await deviceNotifications.cancelResetNotifications(
                    identifierPrefixes: ["reset.\(provider.title)."]
                )
            }
        }
        Task { await refresh() }
    }

    private func synchronizeDevices() async {
        guard await deviceSync.isAvailable() else {
            iCloudSyncStatus = "iCloud Drive 不可用"
            return
        }
        let now = Date()
        var telegramConfigurationError: String?
        if let sharedTelegram = await deviceSync.telegramConfiguration() {
            telegramChatID = sharedTelegram.chatID
            // Overwrite the iCloud file to strip any residual cleartext token
            // field left by previous app versions.
            try? await deviceSync.setTelegramConfiguration(chatID: sharedTelegram.chatID)
        } else if !telegramChatID.isEmpty {
            do {
                try await deviceSync.setTelegramConfiguration(chatID: telegramChatID)
            } catch {
                telegramConfigurationError = "Telegram 配置写入失败：\(error.localizedDescription)"
            }
        }
        if let keychainToken = SecureTokenStore.loadTelegramToken(), !keychainToken.isEmpty {
            telegramToken = keychainToken
        }
        let presence = DevicePresence(
            deviceID: deviceID,
            deviceName: deviceName,
            serverPriority: 100,
            lastHeartbeat: now,
            frontmostProvider: frontmostAgentProvider,
            telegramConfigured: !telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Int64(telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        )
        do {
            try await deviceSync.writePresence(presence)
            knownDevices = await deviceSync.allDevices()
            var sharedPreferred = await deviceSync.preferredServerID()
            if sharedPreferred == nil {
                let suggested = ICloudDeviceSync.preferredCoordinator(from: knownDevices)?.deviceID ?? deviceID
                try? await deviceSync.setPreferredServerID(suggested)
                sharedPreferred = suggested
            }
            preferredServerID = sharedPreferred ?? ""
            let elected = await deviceSync.electedServer(preferredServerID: sharedPreferred, now: now)
            let wasElected = isElectedServer
            let previouslyHeldTelegramLease = holdsTelegramLease
            isElectedServer = elected?.deviceID == deviceID
            currentServerName = elected.map { $0.deviceID == sharedPreferred ? $0.deviceName : "\($0.deviceName)（接管）" } ?? "未发现推送设备"
            if elected?.deviceID == sharedPreferred {
                UserDefaults.standard.set(now, forKey: Self.lastServerSeenKey)
            }
            // Quotas stay local. iCloud only elects which Mac owns Telegram push.
            let wantsTelegram = !telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Int64(telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            let telegramCandidates = knownDevices.filter {
                $0.telegramConfigured == true && now.timeIntervalSince($0.lastHeartbeat) < 180
            }
            let telegramCoordinator = ICloudDeviceSync.preferredCoordinator(
                from: telegramCandidates,
                preferredServerID: sharedPreferred
            )
            if telegramCoordinator?.deviceID == deviceID && wantsTelegram {
                holdsTelegramLease = (try? await deviceSync.acquireOrRenewTelegramLease(device: presence, now: now)) == true
            } else {
                holdsTelegramLease = false
            }
            if holdsTelegramLease, !previouslyHeldTelegramLease {
                startTelegram()
            } else if !holdsTelegramLease, previouslyHeldTelegramLease || (wasElected && !isElectedServer) {
                suspendTelegramForDeviceRole()
            }
            let lastMaintenance = UserDefaults.standard.object(forKey: Self.lastMaintenanceKey) as? Date ?? .distantPast
            if now.timeIntervalSince(lastMaintenance) > 86_400 {
                _ = await performMaintenance()
            }
            iCloudSyncStatus = telegramConfigurationError
                ?? "已协调于 \(now.formatted(date: .omitted, time: .shortened))"
        } catch {
            iCloudSyncStatus = "协调失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func performMaintenance() async -> String {
        let notificationCount = await deviceNotifications.cleanup()
        var syncCount = 0
        var telegramCount = 0
        if holdsTelegramLease, !telegramToken.isEmpty {
            let expired = await deviceSync.expiredTelegramNotifications(before: Date().addingTimeInterval(-12 * 3600))
            for record in expired {
                do {
                    try await telegram.deleteMessage(
                        token: telegramToken,
                        chatID: record.chatID,
                        messageID: record.messageID
                    )
                    await deviceSync.removeTelegramNotificationRecord(messageID: record.messageID)
                    telegramCount += 1
                } catch {
                    // Retry during the next automatic maintenance pass.
                }
            }
        }
        if isElectedServer {
            syncCount = await deviceSync.cleanup().total
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastMaintenanceKey)
        let result = "已清理 \(syncCount) 个 iCloud 过期文件、\(notificationCount) 条本机通知、\(telegramCount) 条 Telegram 提醒"
        message = result
        return result
    }

    var menuUsageFraction: Double {
        guard let activeProvider else { return 0 }
        if let usage = statuses.first(where: { $0.provider == activeProvider })?.usage {
            return menuFraction(for: usage)
        }
        guard statuses.isEmpty else { return 0 }
        let cache = UserDefaults.standard.dictionary(forKey: Self.menuUsageCacheKey) as? [String: Double]
        return max(0, min(1, cache?[activeProvider.rawValue] ?? 0))
    }

    var menuUsageIsKnown: Bool {
        guard let activeProvider else { return false }
        if statuses.first(where: { $0.provider == activeProvider })?.usage != nil { return true }
        guard statuses.isEmpty else { return false }
        let cache = UserDefaults.standard.dictionary(forKey: Self.menuUsageCacheKey) as? [String: Double]
        return cache?[activeProvider.rawValue] != nil
    }

    var menuUsageUsesAPI: Bool {
        guard let activeProvider else { return false }
        if let usage = statuses.first(where: { $0.provider == activeProvider })?.usage {
            return isUsingAPI(usage)
        }
        guard statuses.isEmpty else { return false }
        let cache = UserDefaults.standard.dictionary(forKey: Self.menuAPICacheKey) as? [String: Bool]
        return cache?[activeProvider.rawValue] ?? false
    }

    private func menuFraction(for usage: ProviderUsage) -> Double {
        if isUsingAPI(usage), let api = usage.api {
            return max(0, min(1, api.remaining / 100))
        }
        if usage.provider == .googleAntigravity, isUsingAPI(usage) {
            return 1
        }
        if usage.provider == .cursor {
            let cursorWindow = UserDefaults.standard.string(forKey: Self.cursorMeterKey) == "api"
                ? usage.cursorAPI : usage.cursorAutoComposer
            return max(0, min(1, (cursorWindow?.remaining ?? 0) / 100))
        }
        let window: QuotaWindow?
        if usage.groups.isEmpty {
            if let weekly = usage.sevenDay, weekly.remaining <= 20 {
                window = weekly
            } else {
                window = usage.fiveHour ?? usage.monthly ?? usage.sevenDay
            }
        } else {
            let weekly = usage.groups.compactMap(\.sevenDay).min(by: { $0.remaining < $1.remaining })
            if let weekly, weekly.remaining <= 20 {
                window = weekly
            } else {
                window = usage.groups.compactMap(\.fiveHour).min(by: { $0.remaining < $1.remaining })
                    ?? weekly
            }
        }
        return max(0, min(1, (window?.remaining ?? 0) / 100))
    }

    private func updateMenuUsageCache() {
        var cache = UserDefaults.standard.dictionary(forKey: Self.menuUsageCacheKey) as? [String: Double] ?? [:]
        var apiCache = UserDefaults.standard.dictionary(forKey: Self.menuAPICacheKey) as? [String: Bool] ?? [:]
        for status in statuses {
            guard let usage = status.usage else { continue }
            cache[status.provider.rawValue] = menuFraction(for: usage)
            apiCache[status.provider.rawValue] = isUsingAPI(usage)
        }
        UserDefaults.standard.set(cache, forKey: Self.menuUsageCacheKey)
        UserDefaults.standard.set(apiCache, forKey: Self.menuAPICacheKey)
    }

    private func isUsingAPI(_ usage: ProviderUsage) -> Bool {
        if usage.provider == .cursor {
            return UserDefaults.standard.string(forKey: Self.cursorMeterKey) == "api"
        }
        if usage.provider == .googleAntigravity {
            let hasExhaustedPool = usage.groups.contains {
                ($0.fiveHour?.remaining ?? 0) <= 0 && ($0.sevenDay?.remaining ?? 0) <= 0
            }
            return hasExhaustedPool && (usage.apiActive == true
                || UserDefaults.standard.bool(forKey: Self.antigravityCreditsActiveKey))
        }
        let includedUnavailable = (usage.fiveHour?.remaining ?? 0) <= 0
            && (usage.sevenDay?.remaining ?? usage.monthly?.remaining ?? 0) <= 0
        return includedUnavailable && (usage.api?.utilization ?? 0) > 0
    }

    private func provider(for app: NSRunningApplication) -> ProviderKind? {
        let identity = [app.localizedName, app.bundleIdentifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return ProviderKind.allCases.first { provider in
            ([provider.title] + provider.executableNames + provider.desktopBundleIdentifiers)
                .map { $0.lowercased() }
                .contains { identity.contains($0) }
        }
    }

    var visibleStatuses: [AgentStatus] {
        providerOrder
            .filter { providerEnabled($0) }
            .compactMap { provider in statuses.first(where: { $0.provider == provider }) }
    }

    private static let defaultProviderOrder: [ProviderKind] = [.chatGPT, .googleAntigravity, .kimiCode, .claudeCode, .cursor]
    private static let orderKey = "providerOrder"
    private static let activityScoresKey = "providerActivityScores"

    private static func loadProviderOrder() -> [ProviderKind] {
        guard let raw = UserDefaults.standard.array(forKey: orderKey) as? [String] else { return defaultProviderOrder }
        let decoded = raw.compactMap(ProviderKind.init(rawValue:))
        return defaultProviderOrder.filter { !decoded.contains($0) } + decoded
    }

    private func saveProviderOrder() {
        UserDefaults.standard.set(providerOrder.map(\.rawValue), forKey: Self.orderKey)
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        message = "正在更新额度…"
        let dueEvents = pendingResetEvents.filter { $0.resetAt <= Date() }
        let previousStatuses = statuses
        let providers = ProviderKind.allCases.filter { providerEnabled($0) }
        statuses = await detector.detect(providers: providers)
        statuses = statuses.map { status in
            var enriched = status
            let previous = previousStatuses.first { $0.provider == status.provider }
            enriched.diagnostics = Self.diagnostics(for: status, previous: previous)
            return enriched
        }
        await notifyLowQuotaTransitions(previous: previousStatuses, current: statuses)
        await notifySessionQuotaTransitions(previous: previousStatuses, current: statuses)
        updateCursorMeterSelection(previous: previousStatuses, current: statuses)
        updateAntigravityCreditsSelection(previous: previousStatuses, current: statuses)
        updateMenuUsageCache()
        let detectedResetEvents = resetEvents(from: statuses)
        await cancelInactiveDeviceResetNotifications(for: statuses)
        let blockedResetEvents = detectedResetEvents.filter { !isResetUsable($0, in: statuses) }
        deviceNotifications.cancel(identifiers: blockedResetEvents.map(\.id))
        pendingResetEvents = detectedResetEvents.filter { $0.resetAt > Date() && isResetUsable($0, in: statuses) }
        await scheduleDeviceNotifications(for: pendingResetEvents)
        let eligibleDueEvents = dueEvents.filter { isResetUsable($0, in: statuses) }
        let handledResetIDs = await sendResetNotifications(eligibleDueEvents)
        if !telegramToken.isEmpty && !telegramChatID.isEmpty {
            pendingResetEvents.append(contentsOf: eligibleDueEvents.filter {
                !handledResetIDs.contains($0.id)
                    && Date().timeIntervalSince($0.resetAt) < 12 * 3600
            })
        }
        savePendingResetEvents()
        await notifySustainedReadFailures(previous: previousStatuses, current: statuses)
        updateAutomaticProviderOrder()
        lastUpdated = Date()
        isRefreshing = false
        message = statuses.isEmpty ? "没有发现 Agent" : "已更新额度状态"
        if refreshPending {
            refreshPending = false
            await refresh()
        }
    }

    nonisolated private static func diagnostics(for status: AgentStatus, previous: AgentStatus?) -> ProviderDiagnostics {
        let prior = previous?.diagnostics
        if status.state == .notInstalled || status.state == .installed {
            return ProviderDiagnostics(
                health: .healthy,
                lastSuccessfulRead: nil,
                consecutiveFailures: 0,
                message: status.detail,
                source: status.executable ?? "本机探测",
                failureStartedAt: nil
            )
        }
        guard status.state == .connected else {
            let failures = (prior?.consecutiveFailures ?? 0) + 1
            let failureStartedAt = prior?.failureStartedAt ?? Date()
            let isSustainedFailure = Date().timeIntervalSince(failureStartedAt) >= 10 * 60
            let health: ProviderHealth
            if status.state == .needsLogin || status.state == .tokenStale {
                health = isSustainedFailure ? .authorizationRequired : .stale
            } else {
                health = isSustainedFailure ? .failing : .stale
            }
            return ProviderDiagnostics(
                health: health,
                lastSuccessfulRead: prior?.lastSuccessfulRead,
                consecutiveFailures: failures,
                message: status.detail,
                source: status.executable ?? "本机探测",
                failureStartedAt: failureStartedAt
            )
        }
        return ProviderDiagnostics(
            health: .healthy,
            lastSuccessfulRead: Date(),
            consecutiveFailures: 0,
            message: nil,
            source: status.executable ?? "Provider API",
            failureStartedAt: nil
        )
    }

    func openAgent(_ provider: ProviderKind) {
        let paths: [String]
        switch provider {
        case .chatGPT: paths = ["/Applications/ChatGPT.app"]
        case .cursor: paths = ["/Applications/Cursor.app"]
        case .googleAntigravity:
            paths = ["/Applications/Antigravity.app", "/Applications/Antigravity IDE.app"]
        case .kimiCode: paths = ["/Applications/Kimi.app", "/System/Applications/Utilities/Terminal.app"]
        case .claudeCode: paths = ["/System/Applications/Utilities/Terminal.app"]
        }
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            message = "未找到 \(provider.title) 的可打开应用"
            return
        }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    private func updateCursorMeterSelection(previous: [AgentStatus], current: [AgentStatus]) {
        guard let old = previous.first(where: { $0.provider == .cursor })?.usage,
              let new = current.first(where: { $0.provider == .cursor })?.usage else { return }
        let autoDelta = (new.cursorAutoComposer?.utilization ?? 0) - (old.cursorAutoComposer?.utilization ?? 0)
        let apiDelta = (new.cursorAPI?.utilization ?? 0) - (old.cursorAPI?.utilization ?? 0)
        if apiDelta > 0.001 || autoDelta > 0.001 {
            UserDefaults.standard.set(apiDelta > autoDelta ? "api" : "auto", forKey: Self.cursorMeterKey)
        }
    }

    private func updateAntigravityCreditsSelection(previous: [AgentStatus], current: [AgentStatus]) {
        guard let index = statuses.firstIndex(where: { $0.provider == .googleAntigravity }),
              var new = statuses[index].usage else { return }
        let hasExhaustedPool = new.groups.contains {
            ($0.fiveHour?.remaining ?? 0) <= 0 && ($0.sevenDay?.remaining ?? 0) <= 0
        }
        guard hasExhaustedPool else {
            UserDefaults.standard.set(false, forKey: Self.antigravityCreditsActiveKey)
            new.apiActive = false
            statuses[index].usage = new
            return
        }
        let oldUsage = previous.first(where: { $0.provider == .googleAntigravity })?.usage
        if let oldCredits = oldUsage?.aiCredits, let newCredits = new.aiCredits, newCredits < oldCredits {
            UserDefaults.standard.set(true, forKey: Self.antigravityCreditsActiveKey)
        }
        new.apiActive = UserDefaults.standard.bool(forKey: Self.antigravityCreditsActiveKey)
            || oldUsage?.apiActive == true
        statuses[index].usage = new
    }

    private func updateAutomaticProviderOrder() {
        var scores = UserDefaults.standard.dictionary(forKey: Self.activityScoresKey) as? [String: Double] ?? [:]
        let runningApps = NSWorkspace.shared.runningApplications
        let frontmost = NSWorkspace.shared.frontmostApplication

        for provider in ProviderKind.allCases {
            let names = ([provider.title] + provider.executableNames).map { $0.lowercased() }
            let isRunning = runningApps.contains { app in
                let identity = [app.localizedName, app.bundleIdentifier]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
                return names.contains { identity.contains($0) }
            }
            guard isRunning else { continue }
            let frontmostIdentity = [frontmost?.localizedName, frontmost?.bundleIdentifier]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            let isFrontmost = names.contains { frontmostIdentity.contains($0) }
            scores[provider.rawValue, default: 0] += isFrontmost ? 5 : 1
        }

        let previousRank = Dictionary(uniqueKeysWithValues: providerOrder.enumerated().map { ($0.element, $0.offset) })
        providerOrder = ProviderKind.allCases.sorted { lhs, rhs in
            let lhsScore = scores[lhs.rawValue, default: 0]
            let rhsScore = scores[rhs.rawValue, default: 0]
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return previousRank[lhs, default: Int.max] < previousRank[rhs, default: Int.max]
        }
        UserDefaults.standard.set(scores, forKey: Self.activityScoresKey)
        saveProviderOrder()
    }

    func confirmTelegramConfiguration() {
        telegramConfigurationTask?.cancel()
        telegramConfigurationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            isConfirmingTelegram = true
            defer { isConfirmingTelegram = false }

            let token = telegramToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let chatIDText = telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                telegramVerificationMessage = "请填写 Bot Token"
                message = telegramVerificationMessage
                return
            }
            guard let chatID = Int64(chatIDText) else {
                telegramVerificationMessage = "请填写有效的 Chat ID（纯数字）"
                message = telegramVerificationMessage
                return
            }

            do {
                telegramVerificationMessage = "正在校验 Bot Token…"
                let bot = try await telegram.getMe(token: token)
                let botLabel = bot.username.map { "@\($0)" } ?? bot.firstName

                telegramVerificationMessage = "正在发送测试消息…"
                let deviceLabel = Host.current().localizedName ?? "Mac"
                _ = try await telegram.sendMessage(
                    token: token,
                    chatID: chatID,
                    text: """
                    <b>Reset! 连接成功</b>

                    机器人：\(htmlEscape(botLabel))
                    设备：\(htmlEscape(deviceLabel))
                    版本：\(htmlEscape(AppUpdateChecker.currentVersion))

                    之后的额度提醒将推送到此对话。
                    """,
                    parseMode: "HTML",
                    silent: false
                )

                try SecureTokenStore.saveTelegramToken(token)
                try await deviceSync.setTelegramConfiguration(chatID: chatIDText)
                telegramVerificationMessage = "已确认：\(botLabel) 测试消息发送成功"
                message = telegramVerificationMessage
                await synchronizeDevices()
                if holdsTelegramLease {
                    startTelegram()
                }
            } catch {
                telegramVerificationMessage = "确认失败：\(error.localizedDescription)"
                message = telegramVerificationMessage
                telegramEnabled = false
            }
        }
    }

    func checkForUpdates(force: Bool = true) {
        SparkleUpdateController.shared.checkForUpdates()
    }

    func openRepository() {
        AppUpdateChecker.open(AppUpdateChecker.repositoryURL)
    }

    private func startTelegram() {
        pollingTask?.cancel()
        guard !telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请先填写 Telegram Bot Token"
            return
        }
        guard Int64(telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            telegramEnabled = false
            message = "请先填写有效的 Telegram Chat ID"
            return
        }
        guard holdsTelegramLease else {
            telegramEnabled = false
            message = "Telegram 配置已保存"
            Task { await synchronizeDevices() }
            return
        }
        telegramEnabled = true
        let telegramClient = telegram
        let token = telegramToken
        pollingTask = Task { [weak self] in
            try? await telegramClient.configureCommands(token: token)
            guard !Task.isCancelled else { return }
            await telegramClient.poll(token: token) { [weak self] update in
                await self?.handle(update)
            }
        }
        message = "Telegram 已启动"
    }

    private func suspendTelegramForDeviceRole() {
        pollingTask?.cancel()
        pollingTask = nil
        telegramEnabled = false
        message = "Telegram 已交由服务器设备运行"
    }

    private func handle(_ update: TelegramUpdate) async {
        guard holdsTelegramLease,
              let lease = await deviceSync.telegramLease(),
              lease.holderDeviceID == deviceID,
              (try? await deviceSync.claimTelegramUpdate(updateID: update.updateID, deviceID: deviceID)) == true else { return }
        guard let chatID = update.chatID,
              let configuredChatID = Int64(telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)),
              configuredChatID == chatID else { return }
        if let callbackData = update.callbackData, let callbackID = update.callbackID {
            await handleTelegramCallback(
                callbackData,
                callbackID: callbackID,
                chatID: chatID,
                messageID: update.messageID
            )
            return
        }
        let text = update.text?.lowercased() ?? ""
        let response: String
        var keyboard: [[TelegramInlineButton]]?
        switch text {
        case "/start", "/menu", "菜单", "menu", "🏠 菜单":
            response = "<b>Reset!</b>\n\n选择下方功能。"
        case "/quota", "额度", "额度管理", "查看额度", "📊 额度":
            response = quotaSummary()
            keyboard = quotaKeyboard
        case "/refresh", "🔄 立即刷新":
            await refresh()
            response = quotaSummary()
        default:
            response = "请选择下方功能。"
        }
        _ = try? await telegram.sendMessage(
            token: telegramToken,
            chatID: chatID,
            text: response,
            parseMode: "HTML",
            keyboard: keyboard,
            replyKeyboard: keyboard == nil ? telegramMainKeyboard : nil,
            silent: false
        )
    }

    private var telegramMainKeyboard: [[String]] {
        [["查看额度"]]
    }

    private var quotaKeyboard: [[TelegramInlineButton]] {
        [[TelegramInlineButton(text: "立即刷新", callbackData: "quota:refresh")]]
    }

    private func handleTelegramCallback(_ data: String, callbackID: String, chatID: Int64, messageID: Int?) async {
        try? await telegram.answerCallback(token: telegramToken, callbackID: callbackID, text: "正在处理…")
        let response: String
        switch data {
        case "quota:refresh":
            await refresh()
            response = quotaSummary()
        default:
            response = "这个操作已经失效，请重新查看额度。"
        }
        let keyboard = quotaKeyboard
        if let messageID {
            try? await telegram.editMessage(
                token: telegramToken,
                chatID: chatID,
                messageID: messageID,
                text: response,
                parseMode: "HTML",
                keyboard: keyboard
            )
        } else {
            _ = try? await telegram.sendMessage(
                token: telegramToken,
                chatID: chatID,
                text: response,
                parseMode: "HTML",
                keyboard: keyboard,
                silent: false
            )
        }
    }

    private func statusSummary() -> String {
        """
        <b>推送设备</b>

        \(htmlEscape(currentServerName))
        协调：\(htmlEscape(iCloudSyncStatus))
        """
    }

    private func devicesSummary() async -> String {
        let devices = await deviceSync.allDevices()
        guard !devices.isEmpty else { return "<b>设备</b>\n\n尚未发现其他设备。" }
        let rows = devices.map { device in
            let online = Date().timeIntervalSince(device.lastHeartbeat) < 180 ? "在线" : "离线"
            return "• <b>\(htmlEscape(device.deviceName))</b>\n　\(online)，\(device.lastHeartbeat.formatted(date: .omitted, time: .shortened))"
        }
        return "<b>设备</b>\n\n" + rows.joined(separator: "\n\n")
    }

    private func quotaSummary() -> String {
        let rows = visibleStatuses.map { status in
            guard let usage = status.usage else {
                return "<b>\(htmlEscape(status.provider.title))</b>\n\(htmlEscape(status.state.title))"
            }
            if !usage.groups.isEmpty {
                let groups = usage.groups.sorted { lhs, rhs in
                    func rank(_ name: String) -> Int {
                        name == "Gemini Models" ? 0 : name == "Claude and GPT models" ? 1 : 2
                    }
                    return rank(lhs.name) < rank(rhs.name)
                }.map { group in
                    let blocks = [
                        group.fiveHour.map { telegramQuotaBlock(label: "5 小时", window: $0) },
                        group.sevenDay.map { telegramQuotaBlock(label: "一周", window: $0) }
                    ].compactMap { $0 }
                    return (["<b>\(htmlEscape(group.name))</b>"] + blocks).joined(separator: "\n")
                }
                let credits = usage.displayableAICredits.map {
                    "\nAPI 额度：剩余 \($0.formatted(.number.precision(.fractionLength(0...2))))"
                } ?? ""
                return "<b>\(htmlEscape(status.provider.title))</b>\n\(groups.joined(separator: "\n"))\(credits)"
            }
            if status.provider == .cursor {
                let blocks = [
                    usage.cursorAutoComposer.map { telegramQuotaBlock(label: "Auto + Composer", window: $0) },
                    usage.displayableCursorAPIWindow
                        .map { telegramQuotaBlock(label: "API", window: $0) }
                ].compactMap { $0 }
                return (["<b>Cursor</b>"] + blocks).joined(separator: "\n")
            }
            let blocks = [
                usage.fiveHour.map { telegramQuotaBlock(label: "5 小时", window: $0) },
                usage.sevenDay.map { telegramQuotaBlock(label: "一周", window: $0) }
                    ?? usage.monthly.map { telegramQuotaBlock(label: "账单", window: $0) },
                usage.displayableAPIWindow
                    .map { telegramQuotaBlock(label: "API", window: $0) }
            ].compactMap { $0 }
            return (["<b>\(htmlEscape(status.provider.title))</b>"] + blocks).joined(separator: "\n")
        }
        return "<b>额度总览</b>\n\n" + rows.joined(separator: "\n\n")
    }

    func setDeviceNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await deviceNotifications.requestAuthorization()
            deviceNotificationsEnabled = granted
            message = granted ? "设备通知已启用" : "设备通知权限未开启"
            if granted { await scheduleDeviceNotifications(for: pendingResetEvents) }
        } else {
            deviceNotificationsEnabled = false
        }
        UserDefaults.standard.set(deviceNotificationsEnabled, forKey: Self.deviceNotificationsKey)
    }

    private func sendResetNotifications(_ events: [ResetEvent]) async -> Set<String> {
        guard !events.isEmpty,
              holdsTelegramLease,
              telegramEnabled,
              let chatID = Int64(telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)) else { return [] }
        var claimed: [ResetEvent] = []
        var handledIDs: Set<String> = []
        for event in events {
            do {
                if try await deviceSync.claimTelegramNotification(eventID: event.id, deviceID: deviceID) {
                    claimed.append(event)
                } else {
                    handledIDs.insert(event.id)
                }
            } catch {
                // Keep this event retryable when iCloud coordination itself is
                // temporarily unavailable.
            }
        }
        guard !claimed.isEmpty else { return handledIDs }
        let lines = claimed.map { event in
            "• <b>\(htmlEscape(event.providerName))</b>：\(htmlEscape(event.quotaName))\n　\(htmlEscape(event.periodName))已恢复。"
        }
        let text = "<b>额度已重置</b>\n\n" + lines.joined(separator: "\n\n")
        do {
            let messageID = try await telegram.sendMessage(
                token: telegramToken,
                chatID: chatID,
                text: text,
                parseMode: "HTML",
                keyboard: nil,
                silent: false
            )
            try? await deviceSync.recordTelegramNotification(messageID: messageID, chatID: chatID)
            handledIDs.formUnion(claimed.map(\.id))
        } catch {
            for event in claimed { await deviceSync.releaseTelegramNotificationClaim(eventID: event.id) }
        }
        return handledIDs
    }

    private func isResetUsable(_ event: ResetEvent, in statuses: [AgentStatus]) -> Bool {
        guard let provider = ProviderKind.allCases.first(where: { $0.title == event.providerName }),
              providerEnabled(provider) else { return false }
        guard event.periodName == "5 小时额度" else { return true }
        // A provider outage at the reset boundary must not silently discard a
        // reminder that was already scheduled from a valid low-quota sample.
        guard let usage = statuses.first(where: { $0.provider.title == event.providerName })?.usage else { return true }
        if let group = usage.groups.first(where: { $0.name == event.quotaName }) {
            return (group.sevenDay?.remaining ?? 100) > 0
        }
        return usage.weeklyRemaining > 0
    }

    private func notifySessionQuotaTransitions(previous: [AgentStatus], current: [AgentStatus]) async {
        guard deviceNotificationsEnabled else { return }
        for status in current {
            guard let usage = status.usage else { continue }
            let previousUsage = previous.first(where: { $0.provider == status.provider })?.usage
            func check(label: String, period: String, previousWindow: QuotaWindow?, currentWindow: QuotaWindow?) async {
                guard let currentWindow else { return }
                guard SessionQuotaNotificationLogic.shouldNotifyRestore(
                    previousRemaining: previousWindow?.remaining,
                    currentRemaining: currentWindow.remaining
                ) else { return }
                let dayBucket = Int(Date().timeIntervalSince1970 / 86_400)
                await deviceNotifications.notifyNow(
                    identifier: "reset.restored.\(status.provider.rawValue).\(label).\(period).\(dayBucket)",
                    title: "\(status.provider.title) 额度已重置",
                    body: "\(label)的\(period)已恢复。",
                    silent: false
                )
            }
            if usage.groups.isEmpty {
                await check(label: status.provider.title, period: "5 小时额度", previousWindow: previousUsage?.fiveHour, currentWindow: usage.fiveHour)
                await check(label: status.provider.title, period: "一周额度", previousWindow: previousUsage?.sevenDay, currentWindow: usage.sevenDay)
                await check(label: status.provider.title, period: "账单周期", previousWindow: previousUsage?.monthly, currentWindow: usage.monthly)
            } else {
                for group in usage.groups {
                    let previousGroup = previousUsage?.groups.first(where: { $0.name == group.name })
                    await check(label: group.name, period: "5 小时额度", previousWindow: previousGroup?.fiveHour, currentWindow: group.fiveHour)
                    await check(label: group.name, period: "一周额度", previousWindow: previousGroup?.sevenDay, currentWindow: group.sevenDay)
                }
            }
        }
    }

    private func notifyLowQuotaTransitions(previous: [AgentStatus], current: [AgentStatus]) async {
        var telegramLines: [String] = []
        for status in current where providerEnabled(status.provider) {
            guard let usage = status.usage else { continue }
            let previousUsage = previous.first(where: { $0.provider == status.provider })?.usage
            var alerts: [(String, String, Double)] = []
            func collect(label: String, period: String, previous: QuotaWindow?, current: QuotaWindow?) {
                let key = Self.lowQuotaStateKeyPrefix
                    + "\(status.provider.rawValue).\(label).\(period)"
                let wasPersistedLow = UserDefaults.standard.bool(forKey: key)
                let remaining = current?.remaining
                let isLow = remaining.map { $0 <= QuotaWindow.criticalRemainingThreshold } ?? false
                let shouldNotify = previous != nil
                    ? LowQuotaNotificationLogic.shouldNotify(
                        previousRemaining: previous?.remaining,
                        currentRemaining: remaining
                    )
                    : (isLow && !wasPersistedLow)
                UserDefaults.standard.set(isLow, forKey: key)
                guard shouldNotify, let remaining else { return }
                alerts.append((label, period, remaining))
            }
            if usage.groups.isEmpty {
                collect(label: status.provider.title, period: "5 小时额度", previous: previousUsage?.fiveHour, current: usage.fiveHour)
                collect(label: status.provider.title, period: "一周额度", previous: previousUsage?.sevenDay, current: usage.sevenDay)
                collect(label: status.provider.title, period: "账单周期", previous: previousUsage?.monthly, current: usage.monthly)
                collect(label: status.provider.title, period: "API 额度", previous: previousUsage?.api, current: usage.api)
                collect(label: "Auto + Composer", period: "账单周期", previous: previousUsage?.cursorAutoComposer, current: usage.cursorAutoComposer)
                collect(label: "API", period: "账单周期", previous: previousUsage?.cursorAPI, current: usage.cursorAPI)
            } else {
                for group in usage.groups {
                    let old = previousUsage?.groups.first(where: { $0.name == group.name })
                    collect(label: group.name, period: "5 小时额度", previous: old?.fiveHour, current: group.fiveHour)
                    collect(label: group.name, period: "一周额度", previous: old?.sevenDay, current: group.sevenDay)
                }
            }
            for (label, period, remaining) in alerts {
                let body = "\(label)的\(period)仅剩 \(Int(remaining))%。"
                if deviceNotificationsEnabled {
                    await deviceNotifications.notifyNow(
                        identifier: "reset.low.\(status.provider.rawValue).\(label).\(period).\(Int(Date().timeIntervalSince1970 / 3600))",
                        title: "\(status.provider.title) 额度偏低",
                        body: body
                    )
                }
                telegramLines.append("• <b>\(htmlEscape(status.provider.title))</b>：\(htmlEscape(body))")
            }
        }
        await sendTelegramAlert(
            title: "低额度预警",
            lines: telegramLines,
            claimPrefix: "low"
        )
    }

    private func notifySustainedReadFailures(previous: [AgentStatus], current: [AgentStatus]) async {
        var telegramLines: [String] = []
        for status in current {
            guard status.diagnostics?.health == .failing
                    || status.diagnostics?.health == .authorizationRequired else { continue }
            let previousHealth = previous.first(where: { $0.provider == status.provider })?.diagnostics?.health
            guard previousHealth != .failing && previousHealth != .authorizationRequired else { continue }
            let body = "固定额度查询入口已连续 10 分钟没有成功响应。\(status.detail ?? "请检查登录状态或网络。")"
            if deviceNotificationsEnabled {
                await deviceNotifications.notifyNow(
                    identifier: "reset.unresponsive.\(status.provider.rawValue).\(Int(Date().timeIntervalSince1970 / 86_400))",
                    title: "\(status.provider.title) 额度查询无响应",
                    body: body
                )
            }
            telegramLines.append("• <b>\(htmlEscape(status.provider.title))</b>：\(htmlEscape(body))")
        }
        await sendTelegramAlert(
            title: "额度查询异常",
            lines: telegramLines,
            claimPrefix: "unresponsive"
        )
    }

    private func sendTelegramAlert(title: String, lines: [String], claimPrefix: String) async {
        guard !lines.isEmpty,
              holdsTelegramLease,
              telegramEnabled,
              let chatID = Int64(telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let bucket = Int(Date().timeIntervalSince1970 / 3600)
        let eventID = "\(claimPrefix).\(bucket).\(lines.joined(separator: "|"))"
        guard (try? await deviceSync.claimTelegramNotification(eventID: eventID, deviceID: deviceID)) == true else { return }
        do {
            let messageID = try await telegram.sendMessage(
                token: telegramToken,
                chatID: chatID,
                text: "<b>\(htmlEscape(title))</b>\n\n" + lines.joined(separator: "\n\n"),
                parseMode: "HTML",
                keyboard: nil,
                silent: false
            )
            try? await deviceSync.recordTelegramNotification(messageID: messageID, chatID: chatID)
        } catch {
            await deviceSync.releaseTelegramNotificationClaim(eventID: eventID)
        }
    }

    private func scheduleDeviceNotifications(for events: [ResetEvent]) async {
        guard deviceNotificationsEnabled else { return }
        let now = Date()
        var scheduled = Self.loadScheduledDeviceResetNotifications()
        // Some providers report a relative reset interval, so the calculated
        // absolute date can drift by a few seconds between refreshes. Keep one
        // entry per provider/quota/period and treat nearby dates as one event.
        scheduled = scheduled.filter { $0.value > now.addingTimeInterval(-30 * 86_400) }
        let activeScopes = Set(events.map(\.notificationScopeID))
        for scope in scheduled.keys where !activeScopes.contains(scope) {
            if let existing = scheduled[scope] {
                let parts = scope.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3 {
                    let oldEvent = ResetEvent(
                        providerName: parts[0],
                        quotaName: parts[1],
                        periodName: parts[2],
                        resetAt: existing
                    )
                    deviceNotifications.cancel(identifiers: [oldEvent.id])
                }
            }
            scheduled.removeValue(forKey: scope)
        }
        for event in events {
            let scope = event.notificationScopeID
            if let existing = scheduled[scope] {
                guard abs(existing.timeIntervalSince(event.resetAt)) >= 30 * 60 else { continue }
                let oldEvent = ResetEvent(
                    providerName: event.providerName,
                    quotaName: event.quotaName,
                    periodName: event.periodName,
                    resetAt: existing
                )
                deviceNotifications.cancel(identifiers: [oldEvent.id])
            }
            let added = await deviceNotifications.scheduleReset(
                identifier: event.id,
                title: "\(event.providerName) 额度已重置",
                body: "\(event.quotaName)的\(event.periodName)已恢复。",
                at: event.resetAt,
                silent: false
            )
            if added { scheduled[scope] = event.resetAt }
        }
        Self.saveScheduledDeviceResetNotifications(scheduled)
    }

    private func cancelInactiveDeviceResetNotifications(for statuses: [AgentStatus]) async {
        var inactiveEvents: [ResetEvent] = []
        func append(provider: ProviderKind, quota: String, period: String, window: QuotaWindow?) {
            // Cancel reminders once remaining rises above the critical threshold.
            guard let window, !window.isCriticallyLow else { return }
            inactiveEvents.append(ResetEvent(
                providerName: provider.title,
                quotaName: quota,
                periodName: period,
                resetAt: window.resetsAt ?? .distantPast
            ))
        }
        for status in statuses {
            guard let usage = status.usage else { continue }
            if usage.groups.isEmpty {
                append(provider: status.provider, quota: status.provider.title, period: "5 小时额度", window: usage.fiveHour)
                append(provider: status.provider, quota: status.provider.title, period: "一周额度", window: usage.sevenDay)
                append(provider: status.provider, quota: status.provider.title, period: "账单周期", window: usage.monthly)
            } else {
                for group in usage.groups {
                    append(provider: status.provider, quota: group.name, period: "5 小时额度", window: group.fiveHour)
                    append(provider: status.provider, quota: group.name, period: "一周额度", window: group.sevenDay)
                }
            }
        }
        guard !inactiveEvents.isEmpty else { return }
        await deviceNotifications.cancelResetNotifications(
            identifierPrefixes: inactiveEvents.map(\.notificationIdentifierPrefix)
        )
        var scheduled = Self.loadScheduledDeviceResetNotifications()
        for event in inactiveEvents { scheduled.removeValue(forKey: event.notificationScopeID) }
        Self.saveScheduledDeviceResetNotifications(scheduled)
    }

    private func resetEvents(from statuses: [AgentStatus]) -> [ResetEvent] {
        var events: [ResetEvent] = []
        func append(provider: ProviderKind, quota: String, period: String, window: QuotaWindow?) {
            // Remind for 5h and weekly/monthly windows only when remaining ≤ 20%.
            guard SessionQuotaNotificationLogic.shouldScheduleRestoreReminder(window: window),
                  let resetAt = window?.resetsAt else { return }
            events.append(ResetEvent(providerName: provider.title, quotaName: quota, periodName: period, resetAt: resetAt))
        }
        for status in statuses {
            guard let usage = status.usage else { continue }
            if usage.groups.isEmpty {
                append(provider: status.provider, quota: status.provider.title, period: "5 小时额度", window: usage.fiveHour)
                append(provider: status.provider, quota: status.provider.title, period: "一周额度", window: usage.sevenDay)
                append(provider: status.provider, quota: status.provider.title, period: "账单周期", window: usage.monthly)
            } else {
                for group in usage.groups {
                    append(provider: status.provider, quota: group.name, period: "5 小时额度", window: group.fiveHour)
                    append(provider: status.provider, quota: group.name, period: "一周额度", window: group.sevenDay)
                }
            }
        }
        return events
    }

    private static func loadPendingResetEvents() -> [ResetEvent] {
        guard let data = UserDefaults.standard.data(forKey: pendingResetEventsKey) else { return [] }
        return (try? JSONDecoder().decode([ResetEvent].self, from: data)) ?? []
    }

    private static func loadScheduledDeviceResetNotifications() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: scheduledDeviceResetNotificationsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private static func saveScheduledDeviceResetNotifications(_ notifications: [String: Date]) {
        guard let data = try? JSONEncoder().encode(notifications) else { return }
        UserDefaults.standard.set(data, forKey: scheduledDeviceResetNotificationsKey)
    }

    private func savePendingResetEvents() {
        guard let data = try? JSONEncoder().encode(pendingResetEvents) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingResetEventsKey)
    }

}

private struct ResetEvent: Codable, Sendable {
    let providerName: String
    let quotaName: String
    let periodName: String
    let resetAt: Date

    var id: String {
        "reset.\(providerName).\(quotaName).\(periodName).\(Int(resetAt.timeIntervalSince1970))"
    }

    var notificationScopeID: String {
        "\(providerName)|\(quotaName)|\(periodName)"
    }


    var notificationIdentifierPrefix: String {
        "reset.\(providerName).\(quotaName).\(periodName)."
    }
}

private func htmlEscape(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func telegramQuotaBlock(label: String, window: QuotaWindow) -> String {
    let value = max(0, min(100, window.remaining))
    let marker = min(10, max(0, Int((value / 10).rounded())))
    let bar = String(repeating: "━", count: marker) + "●" + String(repeating: "─", count: 10 - marker)
    let reset = window.resetsAt.map(telegramChineseDateTime) ?? "未提供"
    let quotaLabel: String
    switch label {
    case "API": quotaLabel = "API 额度"
    case "Auto + Composer": quotaLabel = "Auto + Composer 额度"
    case "5 小时", "一周", "账单": quotaLabel = "\(label)额度"
    default: quotaLabel = "\(label) 额度"
    }
    return "<b>\(htmlEscape(quotaLabel))剩余 \(Int(value))%</b>\n\(bar)\n重置于 \(reset)"
}

private func telegramChineseDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .current
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: date)
}


private extension ProviderUsage {
    var primaryFiveHour: QuotaWindow? {
        fiveHour ?? groups.compactMap(\.fiveHour).min(by: { $0.remaining < $1.remaining })
    }

    var weeklyRemaining: Double {
        if !groups.isEmpty {
            return groups.map { $0.sevenDay?.remaining ?? 0 }.max() ?? 0
        }
        return sevenDay?.remaining ?? monthly?.remaining ?? 0
    }
}
