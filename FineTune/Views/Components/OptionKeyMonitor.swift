// FineTune/Views/Components/OptionKeyMonitor.swift
import AppKit
import Observation

/// Whether ⌥ is held right now. While it is, device sliders adjust the device's software
/// volume instead of its own volume, the way macOS menus reveal their alternate items.
@MainActor
@Observable
final class OptionKeyMonitor {
    static let shared = OptionKeyMonitor()

    private(set) var isOptionDown = false

    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var keyWindowObserver: NSObjectProtocol?

    private init() {}

    /// Installs the monitors on first use; every call also resyncs with the keyboard.
    func start() {
        refresh()
        guard localMonitor == nil else { return }

        // Modifier changes while one of FineTune's windows (the panel) is key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }
        // Modifier changes while another app is active. macOS only delivers these when
        // FineTune is trusted for accessibility; refresh() covers the panel without it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
        }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// Reads the modifier state straight from the keyboard, for when a change happened
    /// while no monitor was listening (e.g. ⌥ released while the panel was closed).
    func refresh() {
        update(NSEvent.modifierFlags)
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        let isDown = flags.contains(.option)
        if isDown != isOptionDown {
            isOptionDown = isDown
        }
    }
}
