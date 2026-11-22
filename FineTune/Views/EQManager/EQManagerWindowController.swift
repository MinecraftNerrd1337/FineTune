// FineTune/Views/EQManager/EQManagerWindowController.swift
import SwiftUI
import AppKit

/// Owns the "FineTune EQ Manager" window.
///
/// FineTune is an LSUIElement agent, so like the Settings window this one gets no Dock icon
/// and no app menu in the menu bar. The window is created on first use and reused afterwards,
/// so it keeps its size and place while FineTune runs.
///
/// It opens at `EQManagerRootView.size`, which is also its minimum size, and can be enlarged.
/// Its place is kept across launches, its size is not: each launch opens it at that size.
@MainActor
final class EQManagerWindowController {
    static let shared = EQManagerWindowController()

    private var settings: SettingsManager?
    private var audioEngine: AudioEngine?
    private var window: NSWindow?
    private var frameObservers: [NSObjectProtocol] = []
    private let comparison = EQManagerComparison()

    private init() {}

    /// Called once at launch; the window follows the user's appearance setting.
    func configure(settings: SettingsManager, audioEngine: AudioEngine) {
        self.settings = settings
        self.audioEngine = audioEngine
    }

    /// Shows the window, with the preset it showed last.
    func show() {
        guard let settings, let audioEngine else { return }
        if window == nil {
            window = makeWindow(settings: settings, audioEngine: audioEngine)
        }
        comparison.resume(engine: audioEngine)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(settings: SettingsManager, audioEngine: AudioEngine) -> NSWindow {
        let root = EQManagerRootView(settings: settings, audioEngine: audioEngine, comparison: comparison)
        let hosting = NSHostingController(rootView: root)
        // The window takes its minimum size from the content and leaves the rest to the user
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = EQManagerRootView.title
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // Size the window before centering: the hosting view has not measured its content yet,
        // so center() would otherwise place a zero-sized frame and the window would grow off-center.
        window.setContentSize(EQManagerRootView.size)
        window.contentMinSize = EQManagerRootView.size
        window.center()

        // Like Settings: centered on first open, then reopened where the user left it.
        // The frame is kept in settings.json with the rest of FineTune's settings, but only its
        // place is restored: the window opens at its standard size, its top-left corner where it was.
        if let savedFrame = settings.eqManagerWindowFrame {
            window.setFrame(from: savedFrame)
            var frame = window.frame
            let top = frame.maxY
            frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: EQManagerRootView.size)).size
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: false)
            if window.screen == nil { window.center() }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.saveFrame() }
            })
        }
        // Closing the window ends the comparison: the devices play their own AutoEQ again
        frameObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let audioEngine = self.audioEngine else { return }
                self.comparison.suspend(engine: audioEngine)
            }
        })
        return window
    }

    private func saveFrame() {
        guard let window else { return }
        settings?.eqManagerWindowFrame = window.frameDescriptor
    }
}
