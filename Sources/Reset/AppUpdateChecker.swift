import Foundation
import AppKit

/// Lightweight helpers shared by UI and Sparkle status copy.
enum AppUpdateChecker {
    static let githubOwner = "EEliberto"
    static let githubRepo = "Reset-macOS"
    static let repositoryURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)")!
    static let releasesURL = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases")!
    static let appcastURL = URL(string: "https://raw.githubusercontent.com/\(githubOwner)/\(githubRepo)/main/appcast.xml")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "0"
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func normalizeVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    static func isRemoteVersionNewer(_ remote: String, than local: String) -> Bool {
        let left = versionComponents(normalizeVersion(remote))
        let right = versionComponents(normalizeVersion(local))
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .joined()
            .split(separator: ".")
            .compactMap { Int($0) }
    }
}
