import AppKit
import Foundation

@MainActor
struct AgentActivityMonitor {
    func activity(for provider: ProviderKind, now: Date = Date()) async -> AgentActivity {
        let desktopApp = NSWorkspace.shared.runningApplications.first { app in
            guard let identifier = app.bundleIdentifier else { return false }
            return provider.desktopBundleIdentifiers.contains(identifier)
        }

        // Modern ChatGPT is the Codex host (Classic is excluded by bundle ID),
        // but merely opening it is not the same as an active Agent turn. Session
        // records distinguish execution/waiting/completion from an opened app.
        if provider == .chatGPT, let session = CodexSessionActivityReader().latestActivity(now: now) {
            return AgentActivity(
                state: session.state,
                processID: desktopApp?.processIdentifier,
                command: session.threadName,
                observedAt: session.updatedAt
            )
        }

        let output = await command("/bin/ps", ["-axo", "pid=,command="])
        let process = output
            .split(whereSeparator: \.isNewline)
            .compactMap(parseProcess)
            .first { process in
                matchesFallbackProcess(process.command, for: provider)
            }

        if let desktopApp {
            return AgentActivity(state: .opened, processID: desktopApp.processIdentifier, command: desktopApp.localizedName, observedAt: now)
        }
        if let process {
            // A CLI process has no durable turn event available. It is useful
            // fallback evidence, but should never be mistaken for a desktop task.
            return AgentActivity(state: .running, processID: process.pid, command: process.command, observedAt: now)
        }
        return AgentActivity(state: .unavailable, processID: nil, command: nil, observedAt: now)
    }

    private func parseProcess(_ line: Substring) -> (pid: Int32, command: String)? {
        let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
        return (pid, String(parts[1]))
    }

    private func matchesFallbackProcess(_ command: String, for provider: ProviderKind) -> Bool {
        let lowercased = command.lowercased()
        if provider == .chatGPT {
            // ChatGPT Classic can carry similarly named helper processes. Only a
            // standalone Codex CLI is valid fallback evidence; desktop evidence
            // must come from the modern com.openai.codex bundle above.
            return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/.local/bin/codex"].contains {
                lowercased.contains($0)
            }
        }
        return provider.activityProcessMarkers.contains { lowercased.contains($0) }
    }

    private func command(_ executable: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}

private struct CodexSessionActivity {
    let state: AgentActivityState
    let updatedAt: Date
    let threadName: String?
}

private struct CodexSessionActivityReader {
    private let sessionsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    private let indexURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
    private let maximumTailBytes = 524_288

    func latestActivity(now: Date) -> CodexSessionActivity? {
        guard let index = loadIndex().max(by: { $0.updatedAt < $1.updatedAt }),
              let file = sessionFile(id: index.id),
              let content = tail(of: file) else { return nil }

        let fileDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let activityDate = max(index.updatedAt, fileDate ?? .distantPast)
        guard now.timeIntervalSince(activityDate) < 30 * 60 else { return nil }

        let state = state(in: content)
        return CodexSessionActivity(state: state, updatedAt: activityDate, threadName: index.threadName)
    }

    private func loadIndex() -> [CodexSessionIndexRecord] {
        guard let contents = try? String(contentsOf: indexURL, encoding: .utf8) else { return [] }
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            try? JSONDecoder().decode(CodexSessionIndexRecord.self, from: Data(line.utf8))
        }
    }

    private func sessionFile(id: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: sessionsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.contains(id)
        }
    }

    private func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let readSize = min(size, UInt64(maximumTailBytes))
        try? handle.seek(toOffset: size - readSize)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func state(in content: String) -> AgentActivityState {
        var result: AgentActivityState = .opened
        for line in content.split(whereSeparator: \.isNewline) {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = (root["type"] as? String ?? "").lowercased()
            let payload = root["payload"] as? [String: Any]
            let payloadType = (payload?["type"] as? String ?? "").lowercased()
            let payloadStatus = (payload?["status"] as? String ?? "").lowercased()
            let goalStatus = ((payload?["goal"] as? [String: Any])?["status"] as? String ?? "").lowercased()

            if type == "task_complete" || payloadType == "task_complete" || ["complete", "completed", "succeeded", "success"].contains(goalStatus) {
                result = .completed
            } else if ["blocked", "failed"].contains(goalStatus) || ["turn_aborted", "task_failed", "error", "failed"].contains(payloadType) {
                result = .failed
            } else if ["approval_request", "authorization_request", "confirmation_request", "needs_review", "permission_request", "requires_action", "user_input_requested", "waiting_for_approval", "waiting_for_authorization", "waiting_for_user", "waiting_for_user_input"].contains(payloadType)
                        || ["approval_required", "awaiting_user", "needs_review", "pending_approval", "requires_action", "requires_approval", "waiting_for_approval", "waiting_for_user"].contains(payloadStatus) {
                result = .waiting
            } else if type == "turn_context" || payloadType == "task_started" || payloadType == "user_message" || (type == "response_item" && ["custom_tool_call", "custom_tool_call_output", "function_call", "function_call_output", "image_generation_call", "message", "reasoning", "tool_search_call", "tool_search_output", "web_search_call"].contains(payloadType)) {
                result = .running
            }
        }
        return result
    }
}

private struct CodexSessionIndexRecord: Decodable {
    let id: String
    let threadName: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey { case id; case threadName = "thread_name"; case updatedAt = "updated_at" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        threadName = try container.decode(String.self, forKey: .threadName)
        let raw = try container.decode(String.self, forKey: .updatedAt)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let parsed = fractional.date(from: raw) ?? plain.date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: container, debugDescription: "Invalid session timestamp")
        }
        updatedAt = parsed
    }
}

@MainActor
final class UsageHistoryStore {
    private let defaults: UserDefaults
    private let defaultsKey: String
    private let maximumPoints = 8_640 // 90 days of hourly samples across four providers.

    init(defaults: UserDefaults = .standard, defaultsKey: String = "usageHistory.v1") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
    }

    func points() -> [UsageHistoryPoint] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([UsageHistoryPoint].self, from: data)) ?? []
    }

    func record(_ statuses: [AgentStatus], deviceID: String, at now: Date = Date()) {
        var all = points()
        for status in statuses {
            guard let usage = status.usage, let utilization = primaryUtilization(for: usage) else { continue }
            if let last = all.last(where: {
                $0.provider == status.provider && ($0.originDeviceID == deviceID || $0.originDeviceID == nil)
            }), now.timeIntervalSince(last.date) < 55 * 60 {
                continue
            }
            all.append(UsageHistoryPoint(
                date: now,
                provider: status.provider,
                utilization: utilization,
                estimatedCostUSD: nil,
                originDeviceID: deviceID
            ))
        }
        save(all)
    }

    func localPoints(deviceID: String) -> [UsageHistoryPoint] {
        var all = points()
        var changed = false
        for index in all.indices where all[index].originDeviceID == nil {
            all[index].originDeviceID = deviceID
            changed = true
        }
        if changed { save(all) }
        return all.filter { $0.originDeviceID == deviceID }
    }

    func mergeShared(_ remote: [UsageHistoryPoint], localDeviceID: String) {
        let local = localPoints(deviceID: localDeviceID)
        var merged: [String: UsageHistoryPoint] = [:]
        for point in local + remote {
            guard let origin = point.originDeviceID else { continue }
            let millis = Int64((point.date.timeIntervalSince1970 * 1_000).rounded())
            merged["\(origin)|\(point.provider.rawValue)|\(millis)"] = point
        }
        save(Array(merged.values))
    }

    func forecast(for provider: ProviderKind, usage: ProviderUsage, deviceID: String, now: Date = Date()) -> UsageForecast? {
        guard let current = primaryWindow(for: usage) else { return nil }
        let samples = points().filter {
            $0.provider == provider
                && ($0.originDeviceID == deviceID || $0.originDeviceID == nil)
                && now.timeIntervalSince($0.date) <= 24 * 3600
        }
        guard let first = samples.first, now.timeIntervalSince(first.date) >= 5 * 60 else {
            return UsageForecast(percentPerHour: 0, estimatedExhaustion: nil, isLikelyToExhaustBeforeReset: false)
        }
        let elapsedHours = now.timeIntervalSince(first.date) / 3600
        let rate = max(0, (current.utilization - first.utilization) / elapsedHours)
        guard rate > 0.05 else {
            return UsageForecast(percentPerHour: rate, estimatedExhaustion: nil, isLikelyToExhaustBeforeReset: false)
        }
        let exhaustion = now.addingTimeInterval(current.remaining / rate * 3600)
        return UsageForecast(
            percentPerHour: rate,
            estimatedExhaustion: exhaustion,
            isLikelyToExhaustBeforeReset: current.resetsAt.map { exhaustion < $0 } ?? false
        )
    }

    func summaries(now: Date = Date()) -> [UsageHistorySummary] {
        let recent = points().filter { now.timeIntervalSince($0.date) <= 24 * 3600 }
        return ProviderKind.allCases.compactMap { provider in
            let providerPoints = recent.filter { $0.provider == provider }.sorted { $0.date < $1.date }
            guard !providerPoints.isEmpty else { return nil }
            let series = Dictionary(grouping: providerPoints) { $0.originDeviceID ?? "legacy-local" }
            let changes = series.values.compactMap { samples -> Double? in
                let ordered = samples.sorted { $0.date < $1.date }
                guard let first = ordered.first, let last = ordered.last else { return nil }
                return max(0, last.utilization - first.utilization)
            }
            let averageChange = changes.isEmpty ? 0 : changes.reduce(0, +) / Double(changes.count)
            return UsageHistorySummary(
                provider: provider,
                samples: providerPoints.count,
                utilizationChange24h: averageChange,
                estimatedCostUSD: nil
            )
        }
    }

    private func primaryUtilization(for usage: ProviderUsage) -> Double? { primaryWindow(for: usage)?.utilization }

    private func save(_ points: [UsageHistoryPoint]) {
        let trimmed = Array(points.sorted { $0.date < $1.date }.suffix(maximumPoints))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func primaryWindow(for usage: ProviderUsage) -> QuotaWindow? {
        usage.fiveHour
            ?? usage.groups.compactMap(\.fiveHour).max(by: { $0.utilization < $1.utilization })
            ?? usage.cursorAutoComposer
            ?? usage.sevenDay
            ?? usage.monthly
    }
}
