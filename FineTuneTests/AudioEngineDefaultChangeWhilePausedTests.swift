// FineTuneTests/AudioEngineDefaultChangeWhilePausedTests.swift
//
// An app often stops its output for a moment while the devices change (AirPods connecting,
// for instance). It drops out of the engine's app list but keeps its tap for the cleanup grace
// period. A default change during that moment must still move its tap; before, the tap came
// back on the old device when the app played again, silent on the new default.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@MainActor
private final class PausedTapLog {
    var all: [MockProcessTapController] = []

    func tap(forPID pid: pid_t) -> MockProcessTapController? {
        all.last { $0.app.id == pid }
    }
}

@MainActor
private struct PausedFixture {
    let engine: AudioEngine
    let volume: MockDeviceVolumeProviding
    let processMonitor: StubProcessMonitor
    let log: PausedTapLog
    let a: AudioDevice
    let b: AudioDevice

    func changeDefault(to device: AudioDevice) {
        volume.defaultDeviceID = device.id
        volume.defaultDeviceUID = device.uid
        volume.onDefaultDeviceChanged?(device.uid)
    }

    func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

@MainActor
private func makePausedFixture(app: AudioApp) -> PausedFixture {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var config = settings.appSettings
    config.showDeviceDisconnectAlerts = false
    config.lockInputDevice = false
    settings.updateAppSettings(config)

    let deviceMonitor = MockAudioDeviceMonitor()
    let a = AudioDevice(id: AudioDeviceID(81), uid: "uid-paused-a", name: "Speakers", icon: nil, supportsAutoEQ: false)
    let b = AudioDevice(id: AudioDeviceID(82), uid: "uid-paused-b", name: "Headphones", icon: nil, supportsAutoEQ: false)
    for device in [a, b] { deviceMonitor.addOutputDevice(device) }

    let volume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    volume.defaultDeviceID = a.id
    volume.defaultDeviceUID = a.uid

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let log = PausedTapLog()
    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: volume,
        tapFactory: { app, uids, _ in
            let tap = MockProcessTapController(app: app, deviceUIDs: uids)
            log.all.append(tap)
            return tap
        },
        isAlive: { _ in true },
        startMonitorsAutomatically: false
    )
    return PausedFixture(engine: engine, volume: volume, processMonitor: processMonitor, log: log, a: a, b: b)
}

@Suite("AudioEngine — a default change while an app's output pauses", .serialized)
@MainActor
struct AudioEngineDefaultChangeWhilePausedTests {

    @Test("The tap of an app that is not streaming right now still moves to the new default")
    func pausedAppTapMoves() async throws {
        let app = AudioApp(id: 2200, processObjectIDs: [], name: "Player", icon: NSImage(), bundleID: "com.test.paused-default")
        let fix = makePausedFixture(app: app)
        fix.engine.setDevice(for: app, deviceUID: nil)
        await fix.settle()
        let tap = try #require(fix.log.tap(forPID: 2200))
        #expect(tap.currentDeviceUIDs == [fix.a.uid])

        // The app stops its output while the devices change
        fix.processMonitor.streamingAppIDs = []
        fix.changeDefault(to: fix.b)
        await fix.settle()

        #expect(tap.currentDeviceUIDs == [fix.b.uid])
        #expect(fix.engine.getDeviceUID(for: app) == fix.b.uid)
    }
}
