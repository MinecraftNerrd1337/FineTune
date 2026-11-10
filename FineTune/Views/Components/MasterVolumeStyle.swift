// FineTune/Views/Components/MasterVolumeStyle.swift
import AppKit
import SwiftUI

extension DesignTokens.Colors {
    /// Fill of the master slider, and of a device slider while ⌥ is held and it shows the
    /// device's master volume. Never the same hue as the accent color of the device volumes.
    @MainActor static var masterVolumeOption: Color { MasterVolumeStyle.shared.color }
}

/// The color of a device slider showing its master volume: orange, or cyan when the system
/// accent color is itself warm (red, orange, yellow), so the device volume and the master
/// volume never look the same. Follows accent color changes while the app runs.
@MainActor
@Observable
final class MasterVolumeStyle {
    static let shared = MasterVolumeStyle()

    private(set) var nsColor: NSColor
    var color: Color { Color(nsColor: nsColor) }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        nsColor = Self.optionColor(forAccent: .controlAccentColor)
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let newColor = Self.optionColor(forAccent: .controlAccentColor)
                if newColor != self.nsColor { self.nsColor = newColor }
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main, using: refresh
        ))
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleColorPreferencesChangedNotification"), object: nil, queue: .main, using: refresh
        ))
    }

    /// Orange unless `accent` is a saturated red, orange or yellow; cyan then.
    nonisolated static func optionColor(forAccent accent: NSColor) -> NSColor {
        guard let rgb = accent.usingColorSpace(.sRGB) else { return .systemOrange }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Hue 0…1: red wraps around 0, orange ≈ 0.08, yellow ≈ 0.14. Pink (≈ 0.92) stays orange.
        let isWarm = saturation > 0.25 && (hue < 0.17 || hue > 0.97)
        return isWarm ? .systemCyan : .systemOrange
    }
}
