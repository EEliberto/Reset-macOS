import Foundation
import AppKit
import Sparkle

@MainActor
final class SparkleUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdateController()

    @Published private(set) var statusMessage = "Sparkle 自动检查已启用"
    @Published private(set) var isChecking = false
    @Published private(set) var latestVersion: String?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private override init() {
        super.init()
        _ = controller
    }

    func checkForUpdates() {
        guard controller.updater.canCheckForUpdates else {
            statusMessage = "当前无法检查更新"
            return
        }
        isChecking = true
        statusMessage = "正在通过 Sparkle 检查更新…"
        controller.checkForUpdates(nil)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.isChecking = false
            self.latestVersion = item.displayVersionString
            self.statusMessage = "发现新版本 \(item.displayVersionString)"
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.isChecking = false
            self.latestVersion = nil
            self.statusMessage = "已是最新版本（\(AppUpdateChecker.currentVersion)）"
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { @MainActor in
            self.isChecking = false
            let nsError = error as NSError
            if nsError.domain == "SUSparkleErrorDomain", nsError.code == 1001 {
                self.latestVersion = nil
                self.statusMessage = "已是最新版本（\(AppUpdateChecker.currentVersion)）"
                return
            }
            self.statusMessage = "更新检查失败：\(error.localizedDescription)"
        }
    }
}
