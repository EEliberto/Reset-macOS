import XCTest
@testable import Reset

final class ResetTests: XCTestCase {
    func testChatGPTSupportsNewAndLegacyCLIPaths() {
        XCTAssertTrue(ProviderKind.chatGPT.applicationPaths.contains("/Applications/ChatGPT.app/Contents/Resources/codex-cli"))
        XCTAssertTrue(ProviderKind.chatGPT.applicationPaths.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
    }

    func testChatGPTDesktopDetectionSurvivesCLIRemovalAndRejectsClassic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, identifier, expected) in [
            ("Renamed", "com.openai.codex", true),
            ("Classic", "com.openai.chat", false)
        ] {
            let app = root.appendingPathComponent("\(name).app")
            let contents = app.appendingPathComponent("Contents")
            let executable = contents.appendingPathComponent("MacOS/Desktop")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": "Desktop",
                "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            XCTAssertEqual(AgentDetector.desktopExecutablePath(at: app, for: .chatGPT), expected ? executable.path : nil)
            try FileManager.default.removeItem(at: executable)
            XCTAssertNil(AgentDetector.desktopExecutablePath(at: app, for: .chatGPT))
        }
    }

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

    func testLowQuotaAlertOnlyFiresOnThresholdEntry() {
        XCTAssertTrue(LowQuotaNotificationLogic.shouldNotify(previousRemaining: nil, currentRemaining: 20))
        XCTAssertTrue(LowQuotaNotificationLogic.shouldNotify(previousRemaining: 21, currentRemaining: 20))
        XCTAssertFalse(LowQuotaNotificationLogic.shouldNotify(previousRemaining: 20, currentRemaining: 19))
        XCTAssertFalse(LowQuotaNotificationLogic.shouldNotify(previousRemaining: 50, currentRemaining: 49))
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

    func testKimiUsageParsesFiveHourWeeklyAndExtraBalance() throws {
        let data = Data(
            """
            {
              "usage": {
                "name": "Weekly limit",
                "used": 40,
                "limit": 100,
                "resetAt": "2026-07-30T12:00:00Z"
              },
              "limits": [{
                "detail": {
                  "remaining": 75,
                  "limit": 100,
                  "reset_in": 3600
                },
                "window": {
                  "duration": 300,
                  "timeUnit": "MINUTE"
                }
              }],
              "boosterWallet": {
                "balance": {
                  "type": "BOOSTER",
                  "amount": "20000000000",
                  "amountLeft": "10000000000"
                },
                "monthlyUsed": {
                  "currency": "CNY",
                  "priceInCents": "5000"
                }
              }
            }
            """.utf8
        )

        let usage = try KimiQuotaClient.parseUsage(data, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(usage.fiveHour?.remaining ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(usage.sevenDay?.remaining ?? -1, 60, accuracy: 0.001)
        XCTAssertNotNil(usage.fiveHour?.resetsAt)
        XCTAssertNotNil(usage.sevenDay?.resetsAt)
        XCTAssertEqual(usage.extraUsageBalance ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(usage.extraUsageCurrency, "CNY")
    }

    func testKimiUsageRejectsMissingQuotaWindows() {
        XCTAssertThrowsError(try KimiQuotaClient.parseUsage(Data(#"{"limits":[]}"#.utf8)))
    }

    func testKimiWeeklyLabelClassification() throws {
        let data = Data(
            #"{"limits":[{"name":"Weekly limit","detail":{"used":20,"limit":100}}]}"#.utf8
        )
        let usage = try KimiQuotaClient.parseUsage(data)
        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.remaining ?? -1, 80, accuracy: 0.001)
    }

    func testUpdateVersionComparisonHandlesDateStyleTags() {
        XCTAssertTrue(AppUpdateChecker.isRemoteVersionNewer("270718", than: "260713"))
        XCTAssertTrue(AppUpdateChecker.isRemoteVersionNewer("v270719", than: "270718"))
        XCTAssertFalse(AppUpdateChecker.isRemoteVersionNewer("270718", than: "270718"))
        XCTAssertFalse(AppUpdateChecker.isRemoteVersionNewer("260713", than: "270718"))
        XCTAssertEqual(AppUpdateChecker.normalizeVersion("v270718"), "270718")
    }

}
