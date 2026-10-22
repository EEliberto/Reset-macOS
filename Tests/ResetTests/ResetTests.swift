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

    func testGeminiKeepsLegacyIdentityAndSupportsBothApps() throws {
        let provider = ProviderKind.googleAntigravity
        XCTAssertEqual(provider.title, "Gemini")
        XCTAssertEqual(provider.iconResource, "gemini")
        XCTAssertEqual(try JSONDecoder().decode(ProviderKind.self, from: Data(#""antigravity""#.utf8)), provider)
        XCTAssertTrue(provider.applicationPaths.contains("/Applications/Gemini.app/Contents/MacOS/Gemini"))
        XCTAssertTrue(provider.applicationPaths.contains("/Applications/Antigravity.app/Contents/MacOS/Antigravity"))
        XCTAssertTrue(provider.desktopBundleIdentifiers.contains("com.google.GeminiMacOS"))
        XCTAssertEqual(Set(ProviderKind.allCases.map(\.rawValue)), ["chatgpt", "cc", "cursor", "antigravity"])
    }

    func testGeminiHubDiscoveryRejectsUnrelatedProcessesAndInvalidPorts() {
        let prefix = "123 /Applications/Gemini.app/Contents/Helpers/agy --hub "
        XCTAssertEqual(AntigravityQuotaClient.geminiHubPort(in: prefix + "--hub-port=52078"), 52078)
        XCTAssertEqual(AntigravityQuotaClient.geminiHubPort(in: prefix + "--hub-port 52078"), 52078)
        XCTAssertNil(AntigravityQuotaClient.geminiHubPort(in: prefix + "--hub-port=70000"))
        XCTAssertNil(AntigravityQuotaClient.geminiHubPort(in: prefix + "--hub-port=0"))
        XCTAssertNil(AntigravityQuotaClient.geminiHubPort(in: "/tmp/agy --hub --hub-port=52078"))
        XCTAssertNil(AntigravityQuotaClient.geminiHubPort(in: prefix.replacingOccurrences(of: "--hub ", with: "") + "--hub-port=52078"))
        XCTAssertTrue(AntigravityQuotaClient.isLegacyLanguageServer("/Applications/Antigravity.app/Contents/Resources/language_server_macos_arm"))
        XCTAssertTrue(AntigravityQuotaClient.isLegacyLanguageServer("/Applications/Antigravity IDE.app/Contents/Resources/language_server"))
        XCTAssertFalse(AntigravityQuotaClient.isLegacyLanguageServer("/Applications/Other.app/language_server"))
    }

    func testGeminiHubConfigParsing() {
        let html = #"<script>window.__APP_CONFIG__ = {"productName":"antigravity","csrfToken":"test-token","devMode":false};</script>"#
        XCTAssertEqual(AntigravityQuotaClient.hubCSRFToken(in: Data(html.utf8)), "test-token")
        XCTAssertNil(AntigravityQuotaClient.hubCSRFToken(in: Data(#"window.__APP_CONFIG__ = {"csrfToken":""};"#.utf8)))
        XCTAssertNil(AntigravityQuotaClient.hubCSRFToken(in: Data("not a config".utf8)))
    }

    func testRetiredGrokHookCleanupPreservesCustomHooks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let hook = home.appendingPathComponent(".grok/hooks/reset-build-notifications.json")
        let script = home.appendingPathComponent("Library/Application Support/Reset!/Integrations/grok-build-hook.sh")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: script)
        let custom = Data(#"{"hooks":{"Stop":[]}}"#.utf8)
        try custom.write(to: hook)
        try RetiredIntegrationCleanup.removeGrokHook(home: home)
        XCTAssertEqual(try Data(contentsOf: hook), custom)
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        let handler: [String: Any] = ["hooks": [["type": "command", "command": "'" + script.path + "'", "timeout": 5]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [handler], "StopFailure": [handler]]]).write(to: hook)
        try RetiredIntegrationCleanup.removeGrokHook(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    func testClaudeDesktopIsSupportedWithoutCLI() throws {
        XCTAssertEqual(ProviderKind.claudeCode.title, "Claude")
        XCTAssertEqual(ProviderKind.claudeCode.rawValue, "cc")
        XCTAssertTrue(ProviderKind.claudeCode.applicationPaths.contains("/Applications/Claude.app/Contents/MacOS/Claude"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Claude.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Claude")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.anthropic.claudefordesktop",
            "CFBundleExecutable": "Claude", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertEqual(AgentDetector.desktopExecutablePath(at: app, for: .claudeCode), executable.path)
        XCTAssertNil(AgentDetector.desktopExecutablePath(at: app, for: .chatGPT))
    }

    func testOnlyExplicitFreeClaudePlanRequiresSubscription() {
        XCTAssertThrowsError(try LiveUsageReader.validateClaudeSubscription(" Free ")) { error in
            guard case UsageReadError.subscriptionRequired = error else {
                return XCTFail("Expected subscription-required error")
            }
        }
        for plan in [nil, "", "pro", "max", "team", "enterprise", "unknown"] as [String?] {
            XCTAssertNoThrow(try LiveUsageReader.validateClaudeSubscription(plan))
        }
        XCTAssertEqual(AgentState.needsSubscription.title, "需订阅")
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

    func testUpdateVersionComparisonHandlesDateStyleTags() {
        XCTAssertTrue(AppUpdateChecker.isRemoteVersionNewer("270718", than: "260713"))
        XCTAssertTrue(AppUpdateChecker.isRemoteVersionNewer("v270719", than: "270718"))
        XCTAssertFalse(AppUpdateChecker.isRemoteVersionNewer("270718", than: "270718"))
        XCTAssertFalse(AppUpdateChecker.isRemoteVersionNewer("260713", than: "270718"))
        XCTAssertEqual(AppUpdateChecker.normalizeVersion("v270718"), "270718")
    }

}
