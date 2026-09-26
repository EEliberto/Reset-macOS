import AppKit
import Foundation

struct AgentDetector: Sendable {
    private let usageReader = LiveUsageReader()

    func detect(providers: [ProviderKind] = ProviderKind.allCases) async -> [AgentStatus] {
        await withTaskGroup(of: AgentStatus.self, returning: [AgentStatus].self) { group in
            for provider in providers {
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
        case .chatGPT, .claudeCode, .cursor, .googleAntigravity, .kimiCode:
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
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        // The desktop app can move or rename its bundled CLI between releases.
        // Resolve its identity instead of depending on a Resources filename.
        guard provider == .chatGPT else { return nil }
        return await MainActor.run {
            provider.desktopBundleIdentifiers.lazy.compactMap { identifier in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil as String? }
                return Self.desktopExecutablePath(at: url, for: provider)
            }.first
        }
    }

    static func desktopExecutablePath(at url: URL, for provider: ProviderKind) -> String? {
        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              provider.desktopBundleIdentifiers.contains(identifier),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable.path
    }

}
