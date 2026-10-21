import Foundation

/// One-way migration for hooks installed by older Reset! releases.
enum RetiredIntegrationCleanup {
    static func removeGrokHook(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let hook = home.appendingPathComponent(".grok/hooks/reset-build-notifications.json")
        let script = home.appendingPathComponent("Library/Application Support/Reset!/Integrations/grok-build-hook.sh")
        guard FileManager.default.fileExists(atPath: hook.path) else { return }
        let command = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let handler: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
        let expected: NSDictionary = ["hooks": ["Stop": [handler], "StopFailure": [handler]]]
        let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: hook)) as? NSDictionary
        // Preserve a hook the user has subsequently customized.
        guard actual == expected else { return }
        try FileManager.default.removeItem(at: hook)
        if FileManager.default.fileExists(atPath: script.path) {
            try FileManager.default.removeItem(at: script)
        }
    }
}
