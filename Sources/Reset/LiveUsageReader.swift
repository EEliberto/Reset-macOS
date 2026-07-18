import Foundation
import AppKit

enum UsageReadError: LocalizedError {
    case notLoggedIn(String)
    case unauthorized(String)
    case unavailable(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let message), .unauthorized(let message), .unavailable(let message), .invalidResponse(let message):
            message
        }
    }
}

struct LiveUsageReader: Sendable {
    func read(for provider: ProviderKind) async throws -> ProviderUsage {
        switch provider {
        case .chatGPT:
            return try await readChatGPT()
        case .claudeCode:
            return try await readClaudeCode()
        case .cursor:
            return try await readCursor()
        case .googleAntigravity:
            return try await readAntigravity()
        }
    }

    private func readChatGPT() async throws -> ProviderUsage {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let authData = try? Data(contentsOf: authURL) else {
            throw UsageReadError.notLoggedIn("未找到 ~/.codex/auth.json，请先登录 ChatGPT")
        }
        let auth: CodexAuth
        do {
            auth = try JSONDecoder().decode(CodexAuth.self, from: authData)
        } catch {
            throw UsageReadError.invalidResponse("ChatGPT 登录文件格式异常")
        }
        guard !auth.tokens.accessToken.isEmpty, !auth.tokens.accountID.isEmpty else {
            throw UsageReadError.notLoggedIn("ChatGPT 登录文件缺少 access_token 或 account_id")
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.tokens.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("Reset/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, provider: .chatGPT)
        return try parseChatGPT(data)
    }

    private func readCursor() async throws -> ProviderUsage {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let query = "select value from ItemTable where key='cursorAuth/accessToken';"
        let token = try readSQLiteValue(databaseURL: databaseURL, query: query)
        guard !token.isEmpty else {
            throw UsageReadError.notLoggedIn("Cursor 未登录或本地没有 access token")
        }

        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("3.10.20", forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, provider: .cursor)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let planUsage = root["planUsage"] as? [String: Any] else {
            throw UsageReadError.invalidResponse("Cursor 额度响应缺少 planUsage")
        }
        let reset = (root["billingCycleEnd"] as? NSNumber).flatMap { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            ?? (root["billingCycleEnd"] as? String).flatMap { Double($0).map { Date(timeIntervalSince1970: $0 / 1000) } }
        let seconds = reset.map { max(1, Int($0.timeIntervalSinceNow)) } ?? 30 * 86400
        func meter(_ key: String) -> QuotaWindow? {
            guard let used = planUsage[key] as? NSNumber else { return nil }
            return QuotaWindow(utilization: used.doubleValue, resetsAt: reset, windowSeconds: seconds)
        }
        guard let autoComposer = meter("autoPercentUsed"),
              let cursorAPI = meter("apiPercentUsed") else {
            throw UsageReadError.invalidResponse("Cursor 额度响应缺少 Auto + Composer 或 API 用量")
        }
        let tier = (try? readSQLiteValue(
            databaseURL: databaseURL,
            query: "select value from ItemTable where key='cursorAuth/stripeMembershipType';"
        )) ?? (root["planType"] as? String)
            ?? (root["membershipType"] as? String)
            ?? (planUsage["planType"] as? String)
        return ProviderUsage(
            provider: .cursor,
            fiveHour: nil,
            sevenDay: nil,
            monthly: nil,
            capturedAt: Date(),
            subscriptionTier: tier,
            cursorAutoComposer: autoComposer,
            cursorAPI: cursorAPI
        )
    }

    private func readSQLiteValue(databaseURL: URL, query: String) throws -> String {
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", databaseURL.path, query]
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw UsageReadError.notLoggedIn("无法读取 Cursor 本地登录状态")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw UsageReadError.notLoggedIn("Cursor 未登录或本地状态数据库不可读")
        }
        return value
    }

    private func readClaudeCode() async throws -> ProviderUsage {
        let credential = try readClaudeCredential()
        guard !credential.claudeAIOAuth.accessToken.isEmpty else {
            throw UsageReadError.notLoggedIn("Claude Code 凭据缺少 accessToken")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(credential.claudeAIOAuth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Reset/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, provider: .claudeCode)
        var usage = try parseClaude(data)
        usage.subscriptionTier = credential.claudeAIOAuth.subscriptionType ?? "pro"
        return usage
    }

    private func readClaudeCredential() throws -> ClaudeCredential {
        if let fromKeychain = try? readClaudeCredentialFromKeychain() {
            return fromKeychain
        }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: fileURL) else {
            throw UsageReadError.notLoggedIn("Claude Code 未登录")
        }
        do {
            return try JSONDecoder().decode(ClaudeCredential.self, from: data)
        } catch {
            throw UsageReadError.invalidResponse("Claude Code 登录凭据格式异常")
        }
    }

    private func readClaudeCredentialFromKeychain() throws -> ClaudeCredential {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let credentialData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageReadError.notLoggedIn("Claude Code 未登录")
        }
        do {
            return try JSONDecoder().decode(ClaudeCredential.self, from: credentialData)
        } catch {
            throw UsageReadError.invalidResponse("Claude Code 登录凭据格式异常")
        }
    }

    private func validate(_ response: URLResponse, provider: ProviderKind) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UsageReadError.unavailable("\(provider.title) 返回了无效网络响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageReadError.unauthorized("\(provider.title) 登录已失效或没有额度接口权限")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageReadError.unavailable("\(provider.title) 额度接口 HTTP \(http.statusCode)")
        }
    }

    private func parseChatGPT(_ data: Data) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            throw UsageReadError.invalidResponse("ChatGPT 额度响应缺少 rate_limit")
        }
        let windows = ["primary_window", "secondary_window"].compactMap { rateLimit[$0] as? [String: Any] }
        var fiveHour: QuotaWindow?
        var sevenDay: QuotaWindow?
        var monthly: QuotaWindow?
        for window in windows {
            guard let parsed = parseWindow(window) else { continue }
            if parsed.windowSeconds <= 6 * 3600 {
                fiveHour = parsed
            } else if parsed.windowSeconds <= 10 * 86400 {
                sevenDay = parsed
            } else {
                monthly = parsed
            }
        }
        guard fiveHour != nil || sevenDay != nil || monthly != nil else {
            throw UsageReadError.invalidResponse("ChatGPT 额度窗口解析失败")
        }
        let api = parseAPIWindow(in: root) ?? unavailableChatGPTCredits(in: root)
        return ProviderUsage(
            provider: .chatGPT,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            monthly: monthly,
            capturedAt: Date(),
            subscriptionTier: root["plan_type"] as? String,
            api: api
        )
    }

    private func parseClaude(_ data: Data) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let five = parseClaudeWindow(root["five_hour"], seconds: 5 * 3600) else {
            throw UsageReadError.invalidResponse("Claude Code 额度响应缺少 five_hour")
        }
        let seven = parseClaudeWindow(root["seven_day"], seconds: 7 * 86400)
        let api = parseClaudeWindow(root["extra_usage"], seconds: 30 * 86400)
            ?? parseAPIWindow(in: root)
        return ProviderUsage(provider: .claudeCode, fiveHour: five, sevenDay: seven, monthly: nil, capturedAt: Date(), api: api)
    }

    private func readAntigravity() async throws -> ProviderUsage {
        try await AntigravityQuotaClient().fetch()
    }

#if false
    // Retained temporarily for migration reference; the release path uses
    // AntigravityQuotaClient exclusively and never reads OAuth/agy credentials.
    private func readAntigravityAICredits() async throws -> Double? {
        let connection = try await antigravityFrontendConnection()
        let endpoint = connection.baseURL.appendingPathComponent(
            "exa.language_server_pb.LanguageServerService/GetUserStatus"
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(connection.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let (data, response) = try await LocalAntigravitySession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any],
              let tier = status["userTier"] as? [String: Any],
              let credits = tier["availableCredits"] as? [[String: Any]],
              !credits.isEmpty else { return nil }
        return credits.reduce(0) { total, credit in
            let amount = (credit["creditAmount"] as? NSNumber)?.doubleValue
                ?? (credit["creditAmount"] as? String).flatMap(Double.init)
                ?? 0
            return total + amount
        }
    }

    private func readAntigravityDirectly() async throws -> ProviderUsage {
        var credential = try readAntigravityCredential()
        if shouldRefreshAntigravityToken(expiry: credential.expiry) {
            if let refreshed = try? await refreshAntigravityAccessToken(credential) {
                credential = refreshed
            } else if let expiry = credential.expiry, expiry <= Date() {
                throw UsageReadError.unauthorized("Antigravity 登录令牌已过期，请重新登录一次")
            }
        }

        let load = try await antigravityCloudRequest(
            path: "/v1internal:loadCodeAssist",
            token: credential.accessToken,
            body: [
                "metadata": [
                    "ideType": "ANTIGRAVITY",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI",
                ],
            ]
        )
        let projectValue = load["cloudaicompanionProject"]
        let project = (projectValue as? String)
            ?? (projectValue as? [String: Any])?["id"] as? String
        guard let project, !project.isEmpty else {
            throw UsageReadError.invalidResponse("Antigravity 账号缺少 Cloud Code project")
        }

        let data = try await antigravityCloudData(
            path: "/v1internal:retrieveUserQuotaSummary",
            token: credential.accessToken,
            body: ["project": project]
        )
        return try parseAntigravityQuotaSummary(data)
    }

    private func shouldRefreshAntigravityToken(expiry: Date?) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSinceNow <= 60
    }

    private func refreshAntigravityAccessToken(_ credential: AntigravityCredential) async throws -> AntigravityCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw UsageReadError.unauthorized("Antigravity 缺少 refresh token")
        }
        let discovered = discoverAntigravityOAuthClient()
        guard let clientID = credential.clientID ?? discovered?.clientID,
              let clientSecret = credential.clientSecret ?? discovered?.clientSecret else {
            throw UsageReadError.unavailable("无法发现 Antigravity OAuth client")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw UsageReadError.unauthorized("Antigravity 令牌刷新失败")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        var updated = credential
        updated.accessToken = accessToken
        updated.expiry = Date().addingTimeInterval(expiresIn)
        if let nextRefresh = json["refresh_token"] as? String, !nextRefresh.isEmpty {
            updated.refreshToken = nextRefresh
        }
        try? persistAntigravityCredential(updated)
        return updated
    }

    private func discoverAntigravityOAuthClient() -> (clientID: String, clientSecret: String)? {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        let relativePaths = [
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/bin/language_server",
        ]
        for root in roots {
            let app = root.appendingPathComponent("Antigravity.app", isDirectory: true)
            for relative in relativePaths {
                let url = app.appendingPathComponent(relative)
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard let clientID = firstMatch(#"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#, in: content),
                      let clientSecret = firstMatch(#"GOCSPX-[A-Za-z0-9_-]{28}"#, in: content) else { continue }
                return (clientID, clientSecret)
            }
        }
        return nil
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private func readAntigravityFromLocalService() async throws -> ProviderUsage {
        let connection = try await antigravityFrontendConnection()
        let endpoint = connection.baseURL.appendingPathComponent(
            "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(connection.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let (data, response) = try await LocalAntigravitySession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UsageReadError.unavailable("Antigravity 本机额度服务暂不可用")
        }
        return try parseAntigravityQuotaSummary(data)
    }

    private func readAntigravityFromCLI() async throws -> ProviderUsage {
        guard let binary = antigravityCLIBinary() else {
            throw UsageReadError.unavailable("未找到 agy CLI")
        }
        let pid = try await AntigravityCLIService.shared.start(binary: binary)
        let deadline = Date().addingTimeInterval(8)
        var lastError: Error?
        while Date() < deadline {
            if await AntigravityCLIService.shared.requiresLogin {
                throw UsageReadError.notLoggedIn("agy 需要登录，请先在终端运行一次 agy")
            }
            let ports = listeningPorts(pid: pid)
            for port in ports {
                do {
                    return try await readAntigravityCLIEndpoint(port: port)
                } catch {
                    lastError = error
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw lastError ?? UsageReadError.unavailable("agy 本机额度服务启动超时")
    }

    private func antigravityCLIBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let override = ProcessInfo.processInfo.environment["ANTIGRAVITY_CLI_PATH"]
        let candidates = [
            override,
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func listeningPorts(pid: Int32) -> [Int] {
        guard let output = command(
            "/usr/sbin/lsof",
            ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]
        ) else { return [] }
        return Array(Set(output.split(separator: "\n").compactMap { row -> Int? in
            guard row.first == "n", let colon = row.lastIndex(of: ":") else { return nil }
            return Int(row[row.index(after: colon)...])
        })).sorted()
    }

    private func readAntigravityCLIEndpoint(port: Int) async throws -> ProviderUsage {
        let baseURL = URL(string: "https://127.0.0.1:\(port)")!
        let paths = [
            "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "exa.language_server_pb.LanguageServerService/GetUserStatus",
            "exa.language_server_pb.LanguageServerService/GetCommandModelConfigs",
        ]
        var lastError: Error?
        for path in paths {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = 2
            request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            do {
                let (data, response) = try await LocalAntigravitySession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                if path.hasSuffix("RetrieveUserQuotaSummary") {
                    return try parseAntigravityQuotaSummary(data)
                }
                return try parseAntigravityLegacyUsage(data)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UsageReadError.unavailable("agy 暂未返回额度")
    }

    private func parseAntigravityLegacyUsage(_ data: Data) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageReadError.invalidResponse("agy 返回了无效 JSON")
        }
        let userStatus = root["userStatus"] as? [String: Any]
        let cascade = userStatus?["cascadeModelConfigData"] as? [String: Any]
        let rawConfigs = (cascade?["clientModelConfigs"] as? [[String: Any]])
            ?? (root["clientModelConfigs"] as? [[String: Any]])
            ?? []
        var grouped: [String: [QuotaWindow]] = [:]
        for config in rawConfigs {
            guard let quota = config["quotaInfo"] as? [String: Any] else { continue }
            let fraction = (quota["remainingFraction"] as? NSNumber)?.doubleValue
            let reset = parseFlexibleDate(quota["resetTime"] as? String)
            guard fraction != nil || reset != nil else { continue }
            let label = ((config["label"] as? String)
                ?? ((config["modelOrAlias"] as? [String: Any])?["model"] as? String)
                ?? "Model").lowercased()
            let group = label.contains("gemini") ? "Gemini models" : "Claude/ChatGPT models"
            let window = QuotaWindow(
                utilization: fraction.map { 100 - max(0, min(1, $0)) * 100 } ?? 0,
                resetsAt: reset,
                windowSeconds: 5 * 3600
            )
            grouped[group, default: []].append(window)
        }
        let groups = grouped.compactMap { name, windows -> QuotaGroup? in
            guard let mostConstrained = windows.max(by: { $0.utilization < $1.utilization }) else { return nil }
            return QuotaGroup(name: name, fiveHour: mostConstrained, sevenDay: nil)
        }.sorted { $0.name < $1.name }
        guard !groups.isEmpty else {
            throw UsageReadError.invalidResponse("agy 没有返回可识别的额度窗口")
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

    private func antigravityCloudRequest(
        path: String,
        token: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        let data = try await antigravityCloudData(path: path, token: token, body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageReadError.invalidResponse("Antigravity 后端返回了无效 JSON")
        }
        return root
    }

    private func antigravityCloudData(
        path: String,
        token: String,
        body: [String: Any]
    ) async throws -> Data {
        let url = URL(string: "https://cloudcode-pa.googleapis.com\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/cli/1.0.11 darwin/arm64", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageReadError.unavailable("Antigravity 后端没有返回有效响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageReadError.unauthorized("Antigravity 登录令牌已失效，请重新登录一次")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageReadError.unavailable("Antigravity 额度接口 HTTP \(http.statusCode)")
        }
        return data
    }

    private func readAntigravityCredential() throws -> AntigravityCredential {
        if let fromFile = try? readAntigravityCredentialFromOAuthFile() {
            return fromFile
        }
        if let fromKeychain = try? readAntigravityCredentialFromKeychain() {
            return fromKeychain
        }
        throw UsageReadError.notLoggedIn("Antigravity 未登录或本地没有可用令牌")
    }

    private func readAntigravityCredentialFromOAuthFile() throws -> AntigravityCredential {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/antigravity/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageReadError.notLoggedIn("未找到 Antigravity OAuth 文件")
        }
        return try decodeAntigravityCredential(from: root)
    }

    private func readAntigravityCredentialFromKeychain() throws -> AntigravityCredential {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch {
            throw UsageReadError.notLoggedIn("无法读取 Antigravity 登录状态")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let stored = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let encoded = stored.split(separator: ":", maxSplits: 1).last,
              let decoded = Data(base64Encoded: String(encoded)),
              let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
            throw UsageReadError.notLoggedIn("Antigravity 登录凭据格式异常")
        }
        if let token = root["token"] as? [String: Any] {
            return try decodeAntigravityCredential(from: token, fallbackRoot: root)
        }
        return try decodeAntigravityCredential(from: root)
    }

    private func decodeAntigravityCredential(
        from root: [String: Any],
        fallbackRoot: [String: Any]? = nil
    ) throws -> AntigravityCredential {
        let accessToken = (root["access_token"] as? String)
            ?? (root["accessToken"] as? String)
        guard let accessToken, !accessToken.isEmpty else {
            throw UsageReadError.notLoggedIn("Antigravity 登录凭据缺少 access_token")
        }
        let refreshToken = (root["refresh_token"] as? String)
            ?? (root["refreshToken"] as? String)
            ?? (fallbackRoot?["refresh_token"] as? String)
        let clientID = (root["client_id"] as? String)
            ?? (root["clientID"] as? String)
            ?? (fallbackRoot?["client_id"] as? String)
        let clientSecret = (root["client_secret"] as? String)
            ?? (root["clientSecret"] as? String)
            ?? (fallbackRoot?["client_secret"] as? String)
        let expiry = parseAntigravityExpiry(root["expiry"] ?? root["expiry_date"] ?? root["expiresAt"])
        return AntigravityCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry,
            clientID: clientID,
            clientSecret: clientSecret
        )
    }

    private func parseAntigravityExpiry(_ value: Any?) -> Date? {
        if let text = value as? String {
            return parseFlexibleDate(text)
        }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            // CodexBar stores expiry_date in milliseconds.
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        return nil
    }

    private func persistAntigravityCredential(_ credential: AntigravityCredential) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codexbar/antigravity/oauth_creds.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload: [String: Any] = [
            "access_token": credential.accessToken,
        ]
        if let refreshToken = credential.refreshToken { payload["refresh_token"] = refreshToken }
        if let clientID = credential.clientID { payload["client_id"] = clientID }
        if let clientSecret = credential.clientSecret { payload["client_secret"] = clientSecret }
        if let expiry = credential.expiry {
            payload["expiry_date"] = expiry.timeIntervalSince1970 * 1000
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func antigravityFrontendConnection() async throws -> (baseURL: URL, csrfToken: String) {
        if let fromProcess = try? antigravityConnectionFromProcess() {
            return fromProcess
        }
        let portURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort")
        guard let portText = try? String(contentsOf: portURL, encoding: .utf8),
              let devToolsPort = portText.split(whereSeparator: \.isNewline).first else {
            throw UsageReadError.unavailable("请保持 Antigravity 在后台运行")
        }

        let targetsURL = URL(string: "http://127.0.0.1:\(devToolsPort)/json/list")!
        let (targetsData, _) = try await URLSession.shared.data(from: targetsURL)
        let targets = try JSONDecoder().decode([CDPTarget].self, from: targetsData)
        guard let targetURL = targets.compactMap({ target in
            target.url.flatMap(URL.init(string:))
        }).first(where: { $0.host == "127.0.0.1" }),
              let port = targetURL.port else {
            throw UsageReadError.unavailable("无法发现 Antigravity 本机服务")
        }

        let baseURL = URL(string: "https://127.0.0.1:\(port)")!
        let (htmlData, _) = try await LocalAntigravitySession.shared.data(from: baseURL)
        guard let html = String(data: htmlData, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""csrfToken":"([^"]+)""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw UsageReadError.unavailable("无法读取 Antigravity 本机会话")
        }
        return (baseURL, String(html[range]))
    }

    private func antigravityConnectionFromProcess() throws -> (baseURL: URL, csrfToken: String) {
        guard let processList = command("/bin/ps", ["-axo", "pid=,command="]) else {
            throw UsageReadError.unavailable("无法枚举 Antigravity 进程")
        }
        let line = processList.split(separator: "\n").map(String.init).first {
            ($0.contains("/Applications/Antigravity.app/") || $0.contains("/antigravity/"))
                && ($0.contains("language_server") || $0.contains("language-server"))
                && !$0.contains("antigravity-ide")
                && !$0.contains("antigravity_cli")
        }
        guard let line else {
            throw UsageReadError.unavailable("未发现 Antigravity language_server")
        }
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard let pid = fields.first.flatMap({ Int($0) }),
              let tokenRange = line.range(of: "--csrf_token ") else {
            throw UsageReadError.unavailable("Antigravity 本机进程缺少 CSRF")
        }
        let token = line[tokenRange.upperBound...].split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? ""
        guard !token.isEmpty,
              let sockets = command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]) else {
            throw UsageReadError.unavailable("无法发现 Antigravity 监听端口")
        }
        let ports = sockets.split(separator: "\n").compactMap { row -> Int? in
            guard row.first == "n", let colon = row.lastIndex(of: ":") else { return nil }
            return Int(row[row.index(after: colon)...])
        }
        guard let port = ports.max() else {
            throw UsageReadError.unavailable("Antigravity 没有可用监听端口")
        }
        return (URL(string: "https://127.0.0.1:\(port)")!, token)
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

    private func parseAntigravityQuotaSummary(_ data: Data) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageReadError.invalidResponse("Antigravity 共享额度响应格式异常")
        }
        let response = (root["response"] as? [String: Any])
            ?? (root["summary"] as? [String: Any])
            ?? root
        guard let rawGroups = response["groups"] as? [[String: Any]] else {
            throw UsageReadError.invalidResponse("Antigravity 共享额度响应格式异常")
        }
        let groups = rawGroups.compactMap { raw -> QuotaGroup? in
            guard let name = raw["displayName"] as? String,
                  let buckets = raw["buckets"] as? [[String: Any]] else { return nil }
            func remainingFraction(from bucket: [String: Any]) -> Double? {
                if let fraction = (bucket["remainingFraction"] as? NSNumber)?.doubleValue {
                    return fraction
                }
                if let remaining = bucket["remaining"] as? [String: Any] {
                    if let fraction = (remaining["remainingFraction"] as? NSNumber)?.doubleValue {
                        return fraction
                    }
                    if remaining["case"] as? String == "remainingFraction",
                       let fraction = (remaining["value"] as? NSNumber)?.doubleValue {
                        return fraction
                    }
                }
                return nil
            }
            func quota(for window: String, seconds: Int) -> QuotaWindow? {
                guard let bucket = buckets.first(where: {
                    ($0["window"] as? String) == window
                        || ($0["bucketId"] as? String)?.localizedCaseInsensitiveContains(window) == true
                        || ($0["displayName"] as? String)?.localizedCaseInsensitiveContains(window == "5h" ? "5" : "week") == true
                }),
                      let fraction = remainingFraction(from: bucket) else { return nil }
                let reset = parseFlexibleDate(bucket["resetTime"] as? String)
                return QuotaWindow(
                    utilization: 100 - max(0, min(1, fraction)) * 100,
                    resetsAt: reset,
                    windowSeconds: seconds
                )
            }
            // Prefer explicit window labels first, then CodexBar-style 5h/weekly bucket ids.
            let fiveHour = quota(for: "5h", seconds: 5 * 3600)
                ?? buckets.compactMap { bucket -> QuotaWindow? in
                    let id = ((bucket["bucketId"] as? String) ?? (bucket["displayName"] as? String) ?? "").lowercased()
                    guard id.contains("5") || id.contains("session") || id.contains("hour") else { return nil }
                    guard let fraction = remainingFraction(from: bucket) else { return nil }
                    return QuotaWindow(
                        utilization: 100 - max(0, min(1, fraction)) * 100,
                        resetsAt: parseFlexibleDate(bucket["resetTime"] as? String),
                        windowSeconds: 5 * 3600
                    )
                }.first
            let sevenDay = quota(for: "weekly", seconds: 7 * 86400)
                ?? buckets.compactMap { bucket -> QuotaWindow? in
                    let id = ((bucket["bucketId"] as? String) ?? (bucket["displayName"] as? String) ?? "").lowercased()
                    guard id.contains("week") || id.contains("7") else { return nil }
                    guard let fraction = remainingFraction(from: bucket) else { return nil }
                    return QuotaWindow(
                        utilization: 100 - max(0, min(1, fraction)) * 100,
                        resetsAt: parseFlexibleDate(bucket["resetTime"] as? String),
                        windowSeconds: 7 * 86400
                    )
                }.first
            guard fiveHour != nil || sevenDay != nil else { return nil }
            return QuotaGroup(name: name, fiveHour: fiveHour, sevenDay: sevenDay)
        }
        guard !groups.isEmpty else {
            throw UsageReadError.invalidResponse("Antigravity 没有返回共享额度池")
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

#endif

    private func parseFlexibleDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        return nil
    }

    private func parseWindow(_ value: [String: Any]) -> QuotaWindow? {
        guard let utilization = value["used_percent"] as? NSNumber,
              let seconds = value["limit_window_seconds"] as? NSNumber else { return nil }
        let reset = (value["reset_at"] as? NSNumber).flatMap { Date(timeIntervalSince1970: $0.doubleValue) }
            ?? parseFlexibleDate(value["reset_at"] as? String)
            ?? parseFlexibleDate(value["resets_at"] as? String)
        return QuotaWindow(utilization: utilization.doubleValue, resetsAt: reset, windowSeconds: seconds.intValue)
    }

    private func parseClaudeWindow(_ value: Any?, seconds: Int) -> QuotaWindow? {
        guard let node = value as? [String: Any],
              let utilization = node["utilization"] as? NSNumber else { return nil }
        let reset = parseFlexibleDate(node["resets_at"] as? String)
            ?? parseFlexibleDate(node["reset_at"] as? String)
            ?? (node["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return QuotaWindow(utilization: utilization.doubleValue, resetsAt: reset, windowSeconds: seconds)
    }

    private func parseAPIWindow(in root: [String: Any]) -> QuotaWindow? {
        let keys = ["extra_usage", "api_usage", "credits", "spend_control"]
        for key in keys {
            guard let node = root[key] as? [String: Any] else { continue }
            let utilization = (node["utilization"] as? NSNumber)?.doubleValue
                ?? (node["used_percent"] as? NSNumber)?.doubleValue
                ?? (node["percent_used"] as? NSNumber)?.doubleValue
                ?? ratio(node, used: "used", limit: "limit")
                ?? ratio(node, used: "current_usage", limit: "monthly_limit")
                ?? ratio(node, used: "used_amount", limit: "limit_amount")
            guard let utilization, utilization.isFinite else { continue }
            let reset = parseFlexibleDate(node["resets_at"] as? String)
                ?? (node["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                ?? parseFlexibleDate(node["reset_at"] as? String)
            return QuotaWindow(
                utilization: max(0, min(100, utilization)),
                resetsAt: reset,
                windowSeconds: 30 * 86400
            )
        }
        return nil
    }

    private func ratio(_ node: [String: Any], used: String, limit: String) -> Double? {
        guard let used = node[used] as? NSNumber,
              let limit = node[limit] as? NSNumber,
              limit.doubleValue > 0 else { return nil }
        return used.doubleValue / limit.doubleValue * 100
    }

    private func unavailableChatGPTCredits(in root: [String: Any]) -> QuotaWindow? {
        guard let credits = root["credits"] as? [String: Any],
              credits["has_credits"] as? Bool == false else { return nil }
        return QuotaWindow(utilization: 100, resetsAt: nil, windowSeconds: 30 * 86400)
    }
}

#if false
private struct CDPTarget: Decodable {
    let url: String?
}

private struct AntigravityCredential: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?
    var clientID: String?
    var clientSecret: String?
}

/// Keeps the interactive `agy` process alive in a PTY and reads only its
/// localhost HTTPS API. No terminal output is parsed for quota values.
private actor AntigravityCLIService {
    static let shared = AntigravityCLIService()

    private var process: Process?
    private var primaryFD: Int32 = -1
    private var binaryPath: String?
    private var generation = 0
    private var loginPromptObserved = false

    var requiresLogin: Bool {
        drainOutput()
        return loginPromptObserved
    }

    func start(binary: String) throws -> Int32 {
        if let process, process.isRunning, binaryPath == binary, primaryFD >= 0 {
            drainOutput()
            scheduleIdleStop()
            return process.processIdentifier
        }
        stop()

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var window = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &window) == 0 else {
            throw UsageReadError.unavailable("无法为 agy 创建后台终端")
        }
        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)

        // Own the FDs ourselves. Never use FileHandle.availableData on a PTY —
        // a closed/slave-disconnected descriptor raises an uncatchable NSException.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["PWD"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = environment
        do {
            try process.run()
        } catch {
            _ = Darwin.close(masterFD)
            _ = Darwin.close(slaveFD)
            throw UsageReadError.unavailable("无法启动 agy：\(error.localizedDescription)")
        }
        // Parent keeps master; child already inherited slave duplicates.
        _ = Darwin.close(slaveFD)
        self.process = process
        self.primaryFD = masterFD
        self.binaryPath = binary
        self.loginPromptObserved = false
        self.generation += 1
        scheduleIdleStop()
        return process.processIdentifier
    }

    private func drainOutput() {
        guard primaryFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var chunks = Data()
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return Darwin.read(primaryFD, base, pointer.count)
            }
            if count > 0 {
                chunks.append(contentsOf: buffer.prefix(count))
                continue
            }
            // EAGAIN / EWOULDBLOCK: nothing ready. Other errors / EOF: stop draining.
            break
        }
        guard !chunks.isEmpty else { return }
        let ascii = String(decoding: chunks.map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self)
        if ascii.range(
            of: #"select\s+login\s+method\s*:?"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            loginPromptObserved = true
        }
    }

    private func scheduleIdleStop() {
        generation += 1
        let expected = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            await self?.stopIfIdle(generation: expected)
        }
    }

    private func stopIfIdle(generation expected: Int) {
        guard generation == expected else { return }
        stop()
    }

    private func stop() {
        generation += 1
        if primaryFD >= 0 {
            // Best-effort interrupt/EOF; ignore write failures on a dying PTY.
            let signalBytes: [UInt8] = [0x03, 0x04]
            _ = signalBytes.withUnsafeBytes { pointer in
                Darwin.write(primaryFD, pointer.baseAddress, pointer.count)
            }
        }
        if let process, process.isRunning {
            process.terminate()
        }
        if primaryFD >= 0 {
            _ = Darwin.close(primaryFD)
            primaryFD = -1
        }
        process = nil
        binaryPath = nil
        loginPromptObserved = false
    }
}
#endif

final class LocalAntigravitySession: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let delegate = LocalAntigravitySession()
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct CodexAuth: Decodable {
    let tokens: Tokens
    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

private struct ClaudeCredential: Decodable {
    let claudeAIOAuth: OAuth
    enum CodingKeys: String, CodingKey { case claudeAIOAuth = "claudeAiOauth" }
    struct OAuth: Decodable {
        let accessToken: String
        let subscriptionType: String?
        enum CodingKeys: String, CodingKey { case accessToken, subscriptionType }
    }
}
