// FineTune/Views/HUD/VolumeHUDRouter.swift
import Foundation

/// Shows a change of the default output device's level in FineTune's HUD, unless Settings →
/// Shortcuts → Use FineTune HUD is off: then none shows, for apps that show their own (a notch
/// app). macOS's own indicator can't be shown for a level FineTune sets: on macOS 26 and later
/// no API brings it up, and the private one of earlier versions only draws the pre-Tahoe one.
/// The media keys and a DAC's own buttons go through it; the per-app hotkeys keep FineTune's
/// HUD.
@MainActor
final class VolumeHUDRouter: MediaKeyHUDPresenting {
    private let fineTuneHUD: MediaKeyHUDPresenting
    private let settingsManager: SettingsManager

    init(fineTuneHUD: MediaKeyHUDPresenting, settingsManager: SettingsManager) {
        self.fineTuneHUD = fineTuneHUD
        self.settingsManager = settingsManager
    }

    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        guard settingsManager.appSettings.fineTuneHUDEnabled else { return }
        fineTuneHUD.show(sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
    }

    func swallowObserved() {
        fineTuneHUD.swallowObserved()
    }
}
