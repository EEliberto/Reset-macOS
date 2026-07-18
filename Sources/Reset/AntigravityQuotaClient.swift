import Foundation

struct AntigravityQuotaClient {
    struct Connection: Sendable {
        let pid: Int32
        let port: Int
        let csrfToken: String
    }

    private let fileManager = FileManager.default

    func fetch() async throws -> ProviderUsage {
        var lastError: Error?
        do {
            for connection in try discoverConnections() {
                do {
                    let summary = try await request(
                        connection: connection,
                        path: "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
                        body: Data(#"{"forceRefresh":true}"#.utf8)
                    )
                    var usage = try Self.parseQuotaSummary(summary)
                    if let status = try? await request(
                        connection: connection,
                        path: "exa.language_server_pb.LanguageServerService/GetUserStatus",
                        body: try JSONSerialization.data(withJSONObject: [
                            "metadata": [
                                "ideName": "antigravity",
                                "extensionName": "antigravity",
                                "ideVersion": "unknown",
                                "locale": "en",
                            ],
                        ])
                    ) {
                        usage.aiCredits = Self.parseCredits(status)
                    }
                    try? cache(usage)
                    return usage
                } catch {
                    lastError = error
                }
            }
        } catch {
            lastError = error
        }
        // Antigravity's localhost service exists only while the app is running.
        // Keep the last verified snapshot visible indefinitely while it is closed;
        // the next successful read replaces it immediately.
        if let cached = cachedUsage() {
            return cached
        }
        throw lastError ?? UsageReadError.unavailable("Antigravity 本机额度服务不可用")
    }

    func discoverConnections() throws -> [Connection] {
        guard let processList = command("/bin/ps", ["-ax", "-o", "pid=,command="]) else {
            throw UsageReadError.unavailable("无法枚举 Antigravity 进程")
        }
        var results: [Connection] = []
        for line in processList.split(separator: "\n").map(String.init) {
            let lower = line.lowercased()
            guard (lower.contains("/antigravity.app/") || lower.contains("/antigravity ide.app/")),
                  lower.contains("language_server") || lower.contains("language-server") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let pid = fields.first.flatMap({ Int32($0) }),
                  let token = Self.flagValue("--csrf_token", in: line),
                  !token.isEmpty else { continue }
            for port in listeningPorts(pid: pid) {
                results.append(Connection(pid: pid, port: port, csrfToken: token))
            }
        }
        results.sort {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            return $0.port < $1.port
        }
        guard !results.isEmpty else {
            throw UsageReadError.unavailable("请保持 Antigravity 在后台运行")
        }
        return results
    }

    private func request(connection: Connection, path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(connection.port)/\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(connection.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let (data, response) = try await LocalAntigravitySession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageReadError.unavailable("Antigravity 本机服务没有响应")
        }
        if http.statusCode == 429 {
            throw UsageReadError.unavailable("Antigravity 请求过于频繁，请稍后重试")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageReadError.unavailable("Antigravity 本机接口 HTTP \(http.statusCode)")
        }
        return data
    }

    static func parseQuotaSummary(_ data: Data) throws -> ProviderUsage {
        let envelope = try JSONDecoder().decode(QuotaEnvelope.self, from: data)
        let rawGroups = envelope.response?.groups ?? envelope.summary?.groups ?? envelope.groups ?? []
        let groups = rawGroups.compactMap { raw -> QuotaGroup? in
            let enabled = raw.buckets.filter { $0.disabled != true }
            let five = enabled.first(where: { bucket in
                let key = bucket.searchKey
                return key.contains("5h") || key.contains("five") || key.contains("session")
            }).flatMap { quotaWindow($0, seconds: 5 * 3600) }
            let weekly = enabled.first(where: { $0.searchKey.contains("week") })
                .flatMap { quotaWindow($0, seconds: 7 * 86_400) }
            guard five != nil || weekly != nil else { return nil }
            return QuotaGroup(name: raw.displayName, fiveHour: five, sevenDay: weekly)
        }
        guard !groups.isEmpty else {
            throw UsageReadError.invalidResponse("Antigravity 没有返回可识别的额度窗口")
        }
        return ProviderUsage(
            provider: .googleAntigravity,
            fiveHour: nil,
            sevenDay: nil,
            monthly: nil,
            capturedAt: Date(),
            groups: groups
        )
    }

    private static func quotaWindow(_ bucket: QuotaBucketDTO, seconds: Int) -> QuotaWindow? {
        guard let fraction = bucket.fraction else { return nil }
        return QuotaWindow(
            utilization: 100 - max(0, min(1, fraction)) * 100,
            resetsAt: flexibleDate(bucket.resetTime) ?? relativeDate(bucket.description),
            windowSeconds: seconds
        )
    }

    private static func parseCredits(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any],
              let tier = status["userTier"] as? [String: Any],
              let credits = tier["availableCredits"] as? [[String: Any]] else { return nil }
        let total = credits.reduce(0.0) {
            $0 + (($1["creditAmount"] as? NSNumber)?.doubleValue
                ?? ($1["creditAmount"] as? String).flatMap(Double.init)
                ?? 0)
        }
        return total > 0 ? total : nil
    }

    private static func flagValue(_ flag: String, in command: String) -> String? {
        if let range = command.range(of: "\(flag)=") {
            return command[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        if let range = command.range(of: "\(flag) ") {
            return command[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return nil
    }

    private func listeningPorts(pid: Int32) -> [Int] {
        guard let output = command(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid), "-Fn"]
        ) else { return [] }
        return Array(Set(output.split(separator: "\n").compactMap { row -> Int? in
            guard row.first == "n", row.contains("127.0.0.1"), let colon = row.lastIndex(of: ":") else { return nil }
            return Int(row[row.index(after: colon)...])
        })).sorted()
    }

    private func command(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var cacheURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Reset!/antigravity-quota.json")
    }

    private func cache(_ usage: ProviderUsage) throws {
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(usage)
        try data.write(to: cacheURL, options: .atomic)
    }

    private func cachedUsage() -> ProviderUsage? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return Self.decodeCachedUsage(data)
    }

    static func decodeCachedUsage(_ data: Data) -> ProviderUsage? {
        try? JSONDecoder().decode(ProviderUsage.self, from: data)
    }

    private static func flexibleDate(_ value: FlexibleScalar?) -> Date? {
        guard let value else { return nil }
        switch value {
        case .number(let raw):
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        case .string(let text):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            guard let raw = Double(text) else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
    }

    private static func relativeDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let pattern = #"(\d+(?:\.\d+)?)\s*(day|hour|minute)s?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var seconds = 0.0
        for match in regex.matches(in: text, range: range) {
            guard let amountRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let amount = Double(text[amountRange]) else { continue }
            switch text[unitRange].lowercased() {
            case "day": seconds += amount * 86_400
            case "hour": seconds += amount * 3_600
            default: seconds += amount * 60
            }
        }
        return seconds > 0 ? Date().addingTimeInterval(seconds) : nil
    }
}

private struct QuotaEnvelope: Decodable {
    let response: QuotaContainer?
    let summary: QuotaContainer?
    let groups: [QuotaGroupDTO]?
}

private struct QuotaContainer: Decodable {
    let groups: [QuotaGroupDTO]
}

private struct QuotaGroupDTO: Decodable {
    let displayName: String
    let buckets: [QuotaBucketDTO]
}

private struct QuotaBucketDTO: Decodable {
    let disabled: Bool?
    let window: String?
    let bucketId: String?
    let displayName: String?
    let description: String?
    let resetTime: FlexibleScalar?
    let remainingFraction: Double?
    let remaining: RemainingDTO?

    var fraction: Double? { remainingFraction ?? remaining?.remainingFraction ?? remaining?.value }
    var searchKey: String {
        [window, bucketId, displayName, description].compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

private struct RemainingDTO: Decodable {
    let remainingFraction: Double?
    let value: Double?
}

private enum FlexibleScalar: Decodable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}
