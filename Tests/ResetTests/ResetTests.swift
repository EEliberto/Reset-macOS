import XCTest
@testable import Reset

final class ResetTests: XCTestCase {
    func testQuotaRemaining() {
        let window = QuotaWindow(utilization: 37, resetsAt: nil, windowSeconds: 300)
        XCTAssertEqual(window.remaining, 63)
    }

    func testUnusedQuotaDoesNotHaveActiveResetWindow() {
        let unused = QuotaWindow(utilization: 0, resetsAt: Date().addingTimeInterval(18_000), windowSeconds: 18_000)
        let used = QuotaWindow(utilization: 1, resetsAt: Date().addingTimeInterval(18_000), windowSeconds: 18_000)
        let depleted = QuotaWindow(utilization: 100, resetsAt: Date().addingTimeInterval(18_000), windowSeconds: 18_000)
        XCTAssertFalse(unused.hasActiveResetWindow)
        XCTAssertTrue(used.hasActiveResetWindow)
        XCTAssertFalse(unused.isDepleted)
        XCTAssertFalse(used.isDepleted)
        XCTAssertTrue(depleted.isDepleted)
    }

    func testSessionQuotaTransitionMatchesCodexBar() {
        XCTAssertEqual(SessionQuotaNotificationLogic.transition(previousRemaining: nil, currentRemaining: 0), .none)
        XCTAssertEqual(SessionQuotaNotificationLogic.transition(previousRemaining: 12, currentRemaining: 0), .depleted)
        XCTAssertEqual(SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 5), .restored)
        XCTAssertEqual(SessionQuotaNotificationLogic.transition(previousRemaining: 0, currentRemaining: 0.00001), .none)
        XCTAssertEqual(SessionQuotaNotificationLogic.transition(previousRemaining: 10, currentRemaining: 9), .none)
    }

    func testOnlyDepletedSessionWindowsScheduleRestoreReminders() {
        let depleted = QuotaWindow(utilization: 100, resetsAt: Date().addingTimeInterval(3_600), windowSeconds: 18_000)
        let critical = QuotaWindow(utilization: 85, resetsAt: Date().addingTimeInterval(3_600), windowSeconds: 18_000)
        let lightlyUsed = QuotaWindow(utilization: 1, resetsAt: Date().addingTimeInterval(3_600), windowSeconds: 18_000)
        let weeklyCritical = QuotaWindow(utilization: 90, resetsAt: Date().addingTimeInterval(3_600), windowSeconds: 7 * 86_400)
        let weeklyLight = QuotaWindow(utilization: 1, resetsAt: Date().addingTimeInterval(3_600), windowSeconds: 7 * 86_400)
        XCTAssertTrue(SessionQuotaNotificationLogic.shouldScheduleRestoreReminder(window: depleted))
        XCTAssertTrue(SessionQuotaNotificationLogic.shouldScheduleRestoreReminder(window: critical))
        XCTAssertFalse(SessionQuotaNotificationLogic.shouldScheduleRestoreReminder(window: lightlyUsed))
        XCTAssertTrue(SessionQuotaNotificationLogic.shouldScheduleRestoreReminder(window: weeklyCritical))
        XCTAssertFalse(SessionQuotaNotificationLogic.shouldScheduleRestoreReminder(window: weeklyLight))
    }

    func testRestoreNotifyRequiresCriticalPriorRemaining() {
        XCTAssertTrue(SessionQuotaNotificationLogic.shouldNotifyRestore(previousRemaining: 0, currentRemaining: 100))
        XCTAssertTrue(SessionQuotaNotificationLogic.shouldNotifyRestore(previousRemaining: 15, currentRemaining: 100))
        XCTAssertTrue(SessionQuotaNotificationLogic.shouldNotifyRestore(previousRemaining: 20, currentRemaining: 100))
        XCTAssertFalse(SessionQuotaNotificationLogic.shouldNotifyRestore(previousRemaining: 21, currentRemaining: 100))
        XCTAssertFalse(SessionQuotaNotificationLogic.shouldNotifyRestore(previousRemaining: 1, currentRemaining: 5))
        XCTAssertFalse(SessionQuotaNotificationLogic.shouldNotifyRestore(previousRemaining: nil, currentRemaining: 100))
    }

    func testZeroAPICreditsAreNotDisplayable() {
        let emptyAPI = QuotaWindow(utilization: 100, resetsAt: nil, windowSeconds: 0)
        let usage = ProviderUsage(
            provider: .chatGPT,
            fiveHour: nil,
            sevenDay: nil,
            monthly: nil,
            capturedAt: Date(),
            aiCredits: 0,
            api: emptyAPI
        )
        XCTAssertNil(usage.displayableAPIWindow)
        XCTAssertNil(usage.displayableAICredits)
    }

    func testDesignatedServerWinsCoordinatorElection() {
        let now = Date()
        let ordinary = DevicePresence(deviceID: "a", deviceName: "MacBook", serverPriority: 50, lastHeartbeat: now, frontmostProvider: nil)
        let server = DevicePresence(deviceID: "z", deviceName: "Mac mini", serverPriority: 100, lastHeartbeat: now, frontmostProvider: nil)
        XCTAssertEqual(ICloudDeviceSync.preferredCoordinator(from: [ordinary, server])?.deviceID, "z")
    }

    func testOrdinaryDeviceCanBecomeFallbackCoordinator() {
        let now = Date()
        let first = DevicePresence(deviceID: "a", deviceName: "MacBook", serverPriority: 100, lastHeartbeat: now, frontmostProvider: nil)
        let second = DevicePresence(deviceID: "b", deviceName: "iMac", serverPriority: 100, lastHeartbeat: now, frontmostProvider: nil)
        XCTAssertEqual(ICloudDeviceSync.preferredCoordinator(from: [second, first])?.deviceID, "a")
    }

    func testPreferredServerOverridesPriority() {
        let now = Date()
        let preferred = DevicePresence(deviceID: "book", deviceName: "MacBook", serverPriority: 50, lastHeartbeat: now, frontmostProvider: nil)
        let higherPriority = DevicePresence(deviceID: "mini", deviceName: "Mac mini", serverPriority: 100, lastHeartbeat: now, frontmostProvider: nil)
        XCTAssertEqual(
            ICloudDeviceSync.preferredCoordinator(from: [higherPriority, preferred], preferredServerID: "book")?.deviceID,
            "book"
        )
    }

    func testAntigravityQuotaSummaryParsesFiveHourAndWeeklyBuckets() throws {
        let data = Data(
            """
            {
              "response": {
                "groups": [{
                  "displayName": "Claude and GPT models",
                  "buckets": [
                    {"bucketId":"session-five-hour","remainingFraction":0.72,"resetTime":"2026-07-18T12:00:00Z"},
                    {"bucketId":"weekly-limit","remaining":{"remainingFraction":0.41},"resetTime":1784376000000}
                  ]
                }, {
                  "displayName": "Gemini models",
                  "buckets": [
                    {"bucketId":"gemini-5h","remaining":{"value":0.9}},
                    {"bucketId":"gemini-week","remainingFraction":0.8}
                  ]
                }]
              }
            }
            """.utf8
        )
        let usage = try AntigravityQuotaClient.parseQuotaSummary(data)
        XCTAssertEqual(usage.groups.count, 2)
        XCTAssertEqual(usage.groups[0].fiveHour?.remaining ?? -1, 72, accuracy: 0.001)
        XCTAssertEqual(usage.groups[0].sevenDay?.remaining ?? -1, 41, accuracy: 0.001)
        XCTAssertNotNil(usage.groups[0].sevenDay?.resetsAt)
        XCTAssertEqual(usage.groups[1].fiveHour?.remaining ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(usage.groups[1].sevenDay?.remaining ?? -1, 80, accuracy: 0.001)
    }

    func testAntigravityDisabledBucketsAreIgnored() throws {
        let data = Data(
            """
            {"groups":[{"displayName":"Gemini","buckets":[
              {"bucketId":"5h","disabled":true,"remainingFraction":0.1},
              {"bucketId":"five-hour","remainingFraction":0.6}
            ]}]}
            """.utf8
        )
        let usage = try AntigravityQuotaClient.parseQuotaSummary(data)
        XCTAssertEqual(usage.groups.first?.fiveHour?.remaining ?? -1, 60, accuracy: 0.001)
    }

    func testAntigravityExplicitWindowFieldIsRecognized() throws {
        let data = Data(
            """
            {"summary":{"groups":[{"displayName":"Claude/GPT","buckets":[
              {"bucketId":"primary","window":"5h","remainingFraction":0.55},
              {"bucketId":"secondary","window":"weekly","remainingFraction":0.25}
            ]}]}}
            """.utf8
        )
        let usage = try AntigravityQuotaClient.parseQuotaSummary(data)
        XCTAssertEqual(usage.groups.first?.fiveHour?.remaining ?? -1, 55, accuracy: 0.001)
        XCTAssertEqual(usage.groups.first?.sevenDay?.remaining ?? -1, 25, accuracy: 0.001)
    }

    func testAntigravityCacheDoesNotExpireWhenAppIsClosed() throws {
        let old = ProviderUsage(
            provider: .googleAntigravity,
            fiveHour: nil,
            sevenDay: nil,
            monthly: nil,
            capturedAt: Date().addingTimeInterval(-30 * 86_400),
            groups: [
                QuotaGroup(
                    name: "Claude/GPT",
                    fiveHour: QuotaWindow(utilization: 20, resetsAt: nil, windowSeconds: 18_000),
                    sevenDay: nil
                )
            ]
        )
        let decoded = AntigravityQuotaClient.decodeCachedUsage(try JSONEncoder().encode(old))
        XCTAssertEqual(decoded?.groups.first?.fiveHour?.remaining ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(decoded?.capturedAt, old.capturedAt)
    }

    @MainActor
    func testUsageHistoryMergesDevicesWithoutOverwritingLocalPoints() {
        let suiteName = "ResetTests.UsageHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UsageHistoryStore(defaults: defaults)
        let now = Date()
        let local = UsageHistoryPoint(
            date: now,
            provider: .chatGPT,
            utilization: 10,
            estimatedCostUSD: nil,
            originDeviceID: "mac-a"
        )
        let remote = UsageHistoryPoint(
            date: now.addingTimeInterval(60),
            provider: .claudeCode,
            utilization: 20,
            estimatedCostUSD: nil,
            originDeviceID: "mac-b"
        )
        store.mergeShared([local, remote], localDeviceID: "mac-a")
        XCTAssertEqual(store.points().count, 2)
        XCTAssertEqual(store.localPoints(deviceID: "mac-a"), [local])
    }

    func testUpdateVersionComparisonHandlesDateStyleTags() {
        XCTAssertTrue(AppUpdateChecker.isRemoteVersionNewer("270718", than: "260713"))
        XCTAssertTrue(AppUpdateChecker.isRemoteVersionNewer("v270719", than: "270718"))
        XCTAssertFalse(AppUpdateChecker.isRemoteVersionNewer("270718", than: "270718"))
        XCTAssertFalse(AppUpdateChecker.isRemoteVersionNewer("260713", than: "270718"))
        XCTAssertEqual(AppUpdateChecker.normalizeVersion("v270718"), "270718")
    }

}
