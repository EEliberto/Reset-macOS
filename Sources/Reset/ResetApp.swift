import SwiftUI
import AppKit
import UserNotifications

enum ResetWindow {
    static let settings = "settings"
}

extension Notification.Name {
    static let quitResetRequested = Notification.Name("quitResetRequested")
}

@main
struct ResetApp: App {
    @NSApplicationDelegateAdaptor(ResetAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .frame(width: 330)
        } label: {
            Image(nsImage: menuBarProgressImage(
                progress: model.menuUsageFraction,
                isKnown: model.menuUsageIsKnown,
                usesAPI: model.menuUsageUsesAPI
            ))
            .accessibilityLabel("Reset!")
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: ResetWindow.settings) {
            SettingsView(model: model)
                .frame(minWidth: 700, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 800, height: 620)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsWindowCommand()
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出 Reset!") { model.quitApplication() }
                    .keyboardShortcut("q")
            }
        }
    }
}

@MainActor
final class ResetAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApp.setActivationPolicy(.accessory)
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  window.level == .statusBar || window.className.localizedCaseInsensitiveContains("statusbar") else {
                return event
            }
            let menu = NSMenu()
            let quitItem = NSMenuItem(title: "退出 Reset!", action: #selector(requestQuit), keyEquivalent: "")
            quitItem.target = self
            menu.addItem(quitItem)
            if let view = window.contentView {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
            }
            return nil
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func requestQuit() {
        NotificationCenter.default.post(name: .quitResetRequested, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue == ResetWindow.settings
                || window.title == "设置" else { return }
        let hasVisibleAppWindow = NSApp.windows.contains {
            $0 !== window && $0.isVisible && $0.canBecomeMain && $0.level == .normal
        }
        if !hasVisibleAppWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct SettingsWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("设置…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: ResetWindow.settings)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApp.windows.first {
                    $0.canBecomeKey && $0.level == .normal
                        && ($0.identifier?.rawValue == ResetWindow.settings || $0.title == "设置")
                }
                window?.deminiaturize(nil)
                window?.makeKeyAndOrderFront(nil)
                window?.orderFrontRegardless()
            }
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

private func menuBarProgressImage(progress: Double, isKnown: Bool, usesAPI: Bool) -> NSImage {
    let value = max(0, min(1, progress))
    let progressColor: NSColor = usesAPI
        ? .systemOrange
        : value <= 0.10
        ? .systemRed
        : (value <= 0.20 ? .systemYellow : .labelColor)
    let usesWarningColor = isKnown && (usesAPI || value <= 0.20)
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 6.2
        let lineWidth: CGFloat = 2.2

        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.26).cgColor)
        context.strokeEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        if value > 0 {
            context.setStrokeColor(progressColor.cgColor)
            context.setLineCap(.round)
            context.beginPath()
            context.addArc(
                center: center,
                radius: radius,
                startAngle: .pi / 2,
                endAngle: .pi / 2 - 2 * .pi * value,
                clockwise: true
            )
            context.strokePath()
        }
        return true
    }
    image.isTemplate = !usesWarningColor
    return image
}
