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

}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statuses: [AgentStatus] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeProvider: ProviderKind?
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
    private let deviceNotifications = DeviceNotificationClient()
    private let buildIntegrationMonitor = BuildIntegrationMonitor()
    private var autoRefreshTask: Task<Void, Never>?
    private var buildIntegrationTask: Task<Void, Never>?
    private var grokEventOffset: UInt64 = 0
    private var refreshPending = false
    private let observerStore = AppModelObserverStore()
    private var pendingResetEvents: [ResetEvent]

    private static let deviceNotificationsKey = "deviceNotificationsEnabled"
    private static let providerEnabledKeyPrefix = "providerEnabled."
    private static let lowQuotaStateKeyPrefix = "lowQuotaState."
    private static let grokBuildIntegrationKey = "buildIntegration.grokBuild.enabled"
    private static let pendingResetEventsKey = "pendingResetEvents"
    private static let scheduledDeviceResetNotificationsKey = "scheduledDeviceResetNotifications"
    private static let lastActiveProviderKey = "lastActiveProvider"
    private static let menuUsageCacheKey = "menuUsageCache"
    private static let menuAPICacheKey = "menuAPICache"
    private static let cursorMeterKey = "cursorActiveMeter"
    private static let antigravityCreditsActiveKey = "antigravityCreditsActive"

    init() {
        let defaults = UserDefaults.standard
        providerOrder = Self.loadProviderOrder()
        pendingResetEvents = Self.loadPendingResetEvents()
        enabledProviders = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { provider in
            let key = Self.providerEnabledKeyPrefix + provider.rawValue
            return (provider, defaults.object(forKey: key) as? Bool ?? true)
        })
        deviceNotificationsEnabled = UserDefaults.standard.bool(forKey: Self.deviceNotificationsKey)
        grokBuildIntegrationEnabled = defaults.bool(forKey: Self.grokBuildIntegrationKey)
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginRequiresApproval = SMAppService.mainApp.status == .requiresApproval
        let rememberedProvider = defaults.string(forKey: Self.lastActiveProviderKey).flatMap(ProviderKind.init(rawValue:))
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            let provider = provider(for: frontmost)
            activeProvider = provider ?? rememberedProvider.flatMap { providerEnabled($0) ? $0 : nil }
            if let provider { defaults.set(provider.rawValue, forKey: Self.lastActiveProviderKey) }
        } else {
            activeProvider = rememberedProvider.flatMap { providerEnabled($0) ? $0 : nil }
        }
        observerStore.appActivation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                let provider = self?.provider(for: app)
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
        _ = SparkleUpdateController.shared
    }

    deinit {
        autoRefreshTask?.cancel()
        buildIntegrationTask?.cancel()
    }

    func quitApplication() {
        autoRefreshTask?.cancel()
        buildIntegrationTask?.cancel()
        NSApplication.shared.terminate(nil)
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
            providerEnabled(provider)
                && ([provider.title] + provider.executableNames + provider.desktopBundleIdentifiers)
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
        savePendingResetEvents()
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

    func checkForUpdates(force: Bool = true) {
        SparkleUpdateController.shared.checkForUpdates()
    }

    func openRepository() {
        AppUpdateChecker.open(AppUpdateChecker.repositoryURL)
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
            }
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
