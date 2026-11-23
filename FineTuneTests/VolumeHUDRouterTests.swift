// FineTuneTests/VolumeHUDRouterTests.swift
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class RecordingDeviceHUD: MediaKeyHUDPresenting {
    var shown: [(fraction: Double, mute: Bool)] = []
    var swallowCount = 0
    func show(sliderFraction: Double, mute: Bool, deviceName: String) { shown.append((sliderFraction, mute)) }
    func swallowObserved() { swallowCount += 1 }
}

@Suite("VolumeHUDRouter — FineTune's HUD or none")
@MainActor
struct VolumeHUDRouterTests {
    private func makeSettings(fineTuneHUD: Bool) -> SettingsManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory)
        var appSettings = settings.appSettings
        appSettings.fineTuneHUDEnabled = fineTuneHUD
        settings.appSettings = appSettings
        return settings
    }

    @Test("Use FineTune HUD on: FineTune's HUD shows")
    func fineTuneHUD() {
        let hud = RecordingDeviceHUD()
        let router = VolumeHUDRouter(fineTuneHUD: hud, settingsManager: makeSettings(fineTuneHUD: true))
        router.show(sliderFraction: 0.5, mute: false, deviceName: "DAC")
        #expect(hud.shown.count == 1)
    }

    @Test("Use FineTune HUD off: no HUD shows")
    func noHUD() {
        let hud = RecordingDeviceHUD()
        let router = VolumeHUDRouter(fineTuneHUD: hud, settingsManager: makeSettings(fineTuneHUD: false))
        router.show(sliderFraction: 0.25, mute: true, deviceName: "DAC")
        #expect(hud.shown.isEmpty)
    }

    @Test("A swallowed key always reaches FineTune's HUD")
    func swallow() {
        let hud = RecordingDeviceHUD()
        let router = VolumeHUDRouter(fineTuneHUD: hud, settingsManager: makeSettings(fineTuneHUD: false))
        router.swallowObserved()
        #expect(hud.swallowCount == 1)
    }

    @Test("Use FineTune HUD defaults to on, and a settings file without it reads on")
    func defaults() throws {
        #expect(AppSettings().fineTuneHUDEnabled == true)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.fineTuneHUDEnabled == true)
    }
}
