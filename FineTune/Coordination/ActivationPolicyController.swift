// FineTune/Coordination/ActivationPolicyController.swift
import AppKit

/// Turns FineTune into a regular app (Dock icon, own menu bar) while Settings or the
/// EQ Manager is open, and back into a menu bar agent once the last one closes.
///
/// As an agent, FineTune never owns the menu bar: macOS keeps showing the previous app's
/// menus, and any click in the menu bar (including on FineTune's own icon) hands
/// activation back to that app, sending FineTune's windows behind it. Owning the menu bar
/// while a window is open avoids that. Both windows share the one Dock icon.
@MainActor
final class ActivationPolicyController: NSObject {
    static let shared = ActivationPolicyController()

    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            center.addObserver(self, selector: #selector(windowStateChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func windowStateChanged(_ note: Notification) {
        // On willClose the window is still visible: re-check once AppKit has finished.
        Task { @MainActor in self.updatePolicy() }
    }

    private func updatePolicy() {
        guard let app = NSApp else { return }
        let wanted: NSApplication.ActivationPolicy = hasAppWindow(in: app) ? .regular : .accessory
        guard app.activationPolicy() != wanted else { return }
        app.setActivationPolicy(wanted)
        if wanted == .regular {
            // Take the menu bar now, so it shows FineTune's menus right away.
            app.activate(ignoringOtherApps: true)
        }
    }

    /// Closes Settings and the EQ Manager (⌘Q). FineTune keeps running in the menu bar.
    func closeAppWindows() {
        guard let app = NSApp else { return }
        app.windows.filter(isAppWindow).forEach { $0.close() }
    }

    private func hasAppWindow(in app: NSApplication) -> Bool {
        app.windows.contains(where: isAppWindow)
    }

    /// Settings or EQ Manager: titled, non-panel windows that are on screen or minimized
    /// (a minimized window lives in the Dock and must keep the icon).
    private func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
            && window.styleMask.contains(.titled)
            && (window.isVisible || window.isMiniaturized)
    }
}
