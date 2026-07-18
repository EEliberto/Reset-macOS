import Foundation
import SwiftUI

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case claudeCode = "cc"
    case chatGPT = "chatgpt"
    case cursor
    case googleAntigravity = "antigravity"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .chatGPT: "ChatGPT"
        case .cursor: "Cursor"
        case .googleAntigravity: "Antigravity"
        }
    }

    var company: String {
        switch self {
        case .claudeCode: "Anthropic"
        case .chatGPT: "OpenAI"
        case .cursor: "Anysphere"
        case .googleAntigravity: "Google"
        }
    }

    var iconResource: String {
        switch self {
        case .claudeCode: "claude"
        case .chatGPT: "chatgpt"
        case .cursor: "cursor"
        case .googleAntigravity: "antigravity"
        }
    }

    var accent: Color {
        switch self {
        case .claudeCode: .orange
        case .chatGPT: .mint
        case .cursor: .indigo
        case .googleAntigravity: .blue
        }
    }

    // Brand-derived colors from the bundled provider icons, kept subtle for quota UI.
    var accentGradient: [Color] {
        switch self {
        case .claudeCode:
            [Color(red: 1.0, green: 0.38, blue: 0.18), Color(red: 1.0, green: 0.62, blue: 0.18)]
        case .chatGPT:
            [Color(red: 0.18, green: 0.72, blue: 0.66), Color(red: 0.30, green: 0.82, blue: 0.72)]
        case .cursor:
            [Color(red: 0.30, green: 0.25, blue: 0.85), Color(red: 0.52, green: 0.42, blue: 0.95)]
        case .googleAntigravity:
            [Color(red: 0.18, green: 0.48, blue: 0.98), Color(red: 0.34, green: 0.74, blue: 1.0)]
        }
    }

    var executableNames: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .chatGPT: ["codex"]
        case .cursor: ["cursor-agent", "cursor"]
        case .googleAntigravity: ["agy", "antigravity", "antigravity-cli"]
        }
    }

    var applicationPaths: [String] {
        switch self {
        case .claudeCode: []
        case .chatGPT: ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        case .cursor: ["/Applications/Cursor.app/Contents/MacOS/Cursor"]
        case .googleAntigravity: [
            "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            "/Applications/Antigravity.app/Contents/MacOS/antigravity"
        ]
        }
    }

    /// Process markers include both CLI launches and the desktop app's worker processes.
    /// They intentionally do not depend on whether the app is frontmost.
    var activityProcessMarkers: [String] {
        switch self {
        case .chatGPT:
            // Desktop liveness is deliberately handled by com.openai.codex below.
            // Do not match ChatGPT Classic by its process name.
            ["/codex"]
        case .claudeCode:
            ["/.local/bin/claude", "/claude", "claude-code"]
        case .cursor:
            ["cursor.app/contents/macos/cursor", "cursor-agent"]
        case .googleAntigravity:
            ["antigravity.app/contents/macos/antigravity", "antigravity-cli", "/agentapi"]
        }
    }

    var desktopBundleIdentifiers: [String] {
        switch self {
        case .chatGPT: ["com.openai.codex"]
        case .claudeCode: ["com.anthropic.claudefordesktop"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .googleAntigravity: ["com.google.antigravity"]
        }
    }

}

enum AgentState: String, Codable, Sendable {
    case connected
    case installed
    case needsLogin
    case tokenStale
    case unavailable
    case notInstalled

    var title: String {
        switch self {
        case .connected: "已连接"
        case .installed: "已安装"
        case .needsLogin: "需要登录"
        case .tokenStale: "令牌需刷新"
        case .unavailable: "暂不可用"
        case .notInstalled: "未安装"
        }
    }
}

enum AgentActivityState: String, Codable, Sendable {
    case running
    case waiting
    case completed
    case failed
    case opened
    case idle
    case unavailable

    var title: String {
        switch self {
        case .running: "正在执行"
        case .waiting: "等待你的操作"
        case .completed: "刚刚完成"
        case .failed: "任务失败"
        case .opened: "已打开"
        case .idle: "空闲"
        case .unavailable: "未运行"
        }
    }
}

struct AgentActivity: Codable, Equatable, Sendable {
    var state: AgentActivityState
    var processID: Int32?
    var command: String?
    var observedAt: Date
}

enum ProviderHealth: String, Codable, Sendable {
    case healthy
    case stale
    case failing
    case authorizationRequired

    var title: String {
        switch self {
        case .healthy: "数据正常"
        case .stale: "数据暂时不可用"
        case .failing: "持续读取失败"
        case .authorizationRequired: "需要重新授权"
        }
    }
}

struct ProviderDiagnostics: Codable, Equatable, Sendable {
    var health: ProviderHealth
    var lastSuccessfulRead: Date?
    var consecutiveFailures: Int
    var message: String?
    var source: String
}

struct UsageForecast: Codable, Equatable, Sendable {
    var percentPerHour: Double
    var estimatedExhaustion: Date?
    var isLikelyToExhaustBeforeReset: Bool
}

struct UsageHistoryPoint: Codable, Equatable, Sendable {
    var date: Date
    var provider: ProviderKind
    var utilization: Double
    var estimatedCostUSD: Double?
    var originDeviceID: String? = nil
}

struct UsageHistorySummary: Identifiable, Equatable, Sendable {
    var provider: ProviderKind
    var samples: Int
    var utilizationChange24h: Double
    var estimatedCostUSD: Double?

    var id: ProviderKind { provider }
}

struct QuotaWindow: Codable, Equatable, Sendable {
    var utilization: Double
    var resetsAt: Date?
    var windowSeconds: Int

    /// Matches CodexBar session-quota depleted threshold.
    static let depletedRemainingThreshold: Double = 0.0001
    /// Only remind about resets when remaining is this low (or lower).
    static let criticalRemainingThreshold: Double = 20

    var remaining: Double { max(0, min(100, 100 - utilization)) }
    /// True when this window is actively consuming quota and has a known reset boundary.
    var hasActiveResetWindow: Bool { utilization > Self.depletedRemainingThreshold && resetsAt != nil }
    /// True when remaining is effectively zero (eligible for a one-shot restore notification).
    var isDepleted: Bool { remaining <= Self.depletedRemainingThreshold }
    /// True when remaining is low enough that a reset reminder is useful.
    var isCriticallyLow: Bool { remaining <= Self.criticalRemainingThreshold }
    var isSessionWindow: Bool { windowSeconds > 0 && windowSeconds <= 6 * 3600 }
    var isWeeklyOrLongerWindow: Bool { windowSeconds > 6 * 3600 }
}

enum SessionQuotaTransition: Equatable, Sendable {
    case none
    case depleted
    case restored
}

enum SessionQuotaNotificationLogic {
    static func transition(previousRemaining: Double?, currentRemaining: Double?) -> SessionQuotaTransition {
        guard let previousRemaining, let currentRemaining else { return .none }
        let wasDepleted = previousRemaining <= QuotaWindow.depletedRemainingThreshold
        let isDepleted = currentRemaining <= QuotaWindow.depletedRemainingThreshold
        if !wasDepleted, isDepleted { return .depleted }
        if wasDepleted, !isDepleted { return .restored }
        return .none
    }

    /// Schedule a restore reminder for 5h / weekly / monthly windows that are
    /// critically low (≤20% remaining), including fully depleted.
    static func shouldScheduleRestoreReminder(window: QuotaWindow?, now: Date = Date()) -> Bool {
        guard let window,
              window.windowSeconds > 0,
              window.isCriticallyLow,
              let resetAt = window.resetsAt,
              resetAt > now else { return false }
        return true
    }

    /// Live "额度已重置" alerts only when the prior sample was critically low.
    static func shouldNotifyRestore(previousRemaining: Double?, currentRemaining: Double?) -> Bool {
        guard let previousRemaining, let currentRemaining else { return false }
        return previousRemaining <= QuotaWindow.criticalRemainingThreshold
            && currentRemaining > QuotaWindow.criticalRemainingThreshold
    }
}

struct ProviderUsage: Codable, Equatable, Sendable {
    var provider: ProviderKind
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var monthly: QuotaWindow?
    var capturedAt: Date
    var groups: [QuotaGroup] = []
    var aiCredits: Double? = nil
    var subscriptionTier: String? = nil
    var api: QuotaWindow? = nil
    var apiActive: Bool? = nil
    var cursorAutoComposer: QuotaWindow? = nil
    var cursorAPI: QuotaWindow? = nil

    /// A zero balance represents unavailable credits, not a quota worth showing.
    var displayableAPIWindow: QuotaWindow? {
        guard let api, api.remaining > 0 else { return nil }
        return api
    }

    var displayableAICredits: Double? {
        guard let aiCredits, aiCredits > 0 else { return nil }
        return aiCredits
    }

    var displayableCursorAPIWindow: QuotaWindow? {
        guard let cursorAPI, cursorAPI.remaining > 0 else { return nil }
        return cursorAPI
    }

}

struct QuotaGroup: Identifiable, Codable, Equatable, Sendable {
    var name: String
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?

    var id: String { name }
}

struct AgentStatus: Identifiable, Codable, Equatable, Sendable {
    var provider: ProviderKind
    var state: AgentState
    var executable: String?
    var usage: ProviderUsage?
    var detail: String?
    var activity: AgentActivity? = nil
    var diagnostics: ProviderDiagnostics? = nil
    var forecast: UsageForecast? = nil

    var id: String { provider.rawValue }

}
