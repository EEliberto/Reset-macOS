import Foundation

struct AgentDetector: Sendable {
    private let usageReader = LiveUsageReader()

    func detect() async -> [AgentStatus] {
        await withTaskGroup(of: AgentStatus.self, returning: [AgentStatus].self) { group in
            for provider in ProviderKind.allCases {
                group.addTask { await detect(provider) }
            }
            return await group.reduce(into: []) { $0.append($1) }.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
    }

    private func detect(_ provider: ProviderKind) async -> AgentStatus {
        // URL requests have their own request timeout. Do not wrap detection in
        // a task group timeout: structured task groups wait for a non-cooperative
        // child to finish on scope exit, which can leave the menu permanently
        // loading after a failed refresh.
        await detectWithoutTimeout(provider)
    }

    private func detectWithoutTimeout(_ provider: ProviderKind) async -> AgentStatus {
        let path = await executablePath(for: provider)
        guard let path else {
            return AgentStatus(provider: provider, state: .notInstalled, executable: nil, usage: nil, detail: "未找到 \(provider.title) 的 CLI 或应用")
        }
        switch provider {
        case .chatGPT, .claudeCode, .cursor, .googleAntigravity:
            do {
                let usage = try await usageReader.read(for: provider)
                return AgentStatus(provider: provider, state: .connected, executable: path, usage: usage, detail: "已读取实时额度")
            } catch let error as UsageReadError {
                switch error {
                case .notLoggedIn(let detail):
                    return AgentStatus(provider: provider, state: .needsLogin, executable: path, usage: nil, detail: detail)
                case .unauthorized(let detail):
                    return AgentStatus(provider: provider, state: .tokenStale, executable: path, usage: nil, detail: detail)
                case .invalidResponse(let detail), .unavailable(let detail):
                    return AgentStatus(provider: provider, state: .unavailable, executable: path, usage: nil, detail: detail)
                }
            } catch {
                return AgentStatus(provider: provider, state: .unavailable, executable: path, usage: nil, detail: error.localizedDescription)
            }
        }
    }

    private func executablePath(for provider: ProviderKind) async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = provider.executableNames.flatMap { name in
            ["/opt/homebrew/bin/\(name)",
             "/usr/local/bin/\(name)",
             "\(home)/.local/bin/\(name)",
             "\(home)/.npm-global/bin/\(name)"]
        } + provider.applicationPaths
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

}
