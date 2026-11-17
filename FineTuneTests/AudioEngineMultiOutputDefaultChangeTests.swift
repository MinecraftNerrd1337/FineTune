// FineTuneTests/AudioEngineMultiOutputDefaultChangeTests.swift
//
// An app set to play on several devices chose its outputs explicitly. Changing the default
// output device must leave it alone: same outputs, and no tap switch at all (so nothing is
// heard). Before, an app that followed the default when it was switched to multi-device mode
// was collapsed to the new default alone, and its tap could capture the old default's stream.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@MainActor
private final class TapLog {
    var all: [MockProcessTapController] = []

    func tap(forPID pid: pid_t) -> MockProcessTapController? {
        all.last { $0.app.id == pid }
    }
}

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let volume: MockDeviceVolumeProviding
    let log: TapLog
    let a: AudioDevice
    let b: AudioDevice
    let c: AudioDevice

    /// The system (or the user, in FineTune) picks another default output device.
    func changeDefault(to device: AudioDevice) {
        volume.defaultDeviceID = device.id
        volume.defaultDeviceUID = device.uid
        volume.onDefaultDeviceChanged?(device.uid)
    }

    /// Lets the engine's tap-switching tasks run.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

@MainActor
private func makeApp(pid: pid_t) -> AudioApp {
    AudioApp(id: pid, processObjectIDs: [], name: "Player \(pid)", icon: NSImage(), bundleID: "com.test.multi-default.\(pid)")
}

@MainActor
private func makeFixture(apps: [AudioApp]) -> Fixture {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var config = settings.appSettings
    config.showDeviceDisconnectAlerts = false
    config.lockInputDevice = false
    settings.updateAppSettings(config)

    let deviceMonitor = MockAudioDeviceMonitor()
    let a = AudioDevice(id: AudioDeviceID(71), uid: "uid-multi-a", name: "DAC A", icon: nil, supportsAutoEQ: false)
    let b = AudioDevice(id: AudioDeviceID(72), uid: "uid-multi-b", name: "DAC B", icon: nil, supportsAutoEQ: false)
    let c = AudioDevice(id: AudioDeviceID(73), uid: "uid-multi-c", name: "DAC C", icon: nil, supportsAutoEQ: false)
    for device in [a, b, c] { deviceMonitor.addOutputDevice(device) }

    let volume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    volume.defaultDeviceID = a.id
    volume.defaultDeviceUID = a.uid

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = apps

    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let log = TapLog()
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
    return Fixture(engine: engine, volume: volume, log: log, a: a, b: b, c: c)
}

/// Puts `app` (following the default, on A) on A and B together.
@MainActor
private func routeToAAndB(_ app: AudioApp, in fix: Fixture) async {
    fix.engine.setDevice(for: app, deviceUID: nil)
    fix.engine.setSelectedDeviceUIDs(for: app, to: [fix.a.uid, fix.b.uid])
    fix.engine.setDeviceSelectionMode(for: app, to: .multi)
    await fix.settle()
}

@Suite("AudioEngine multi-device output — unaffected by a change of the default device", .serialized)
@MainActor
struct AudioEngineMultiOutputDefaultChangeTests {

    @Test("A multi-device app keeps its outputs, and its tap is not switched")
    func keepsOutputs() async throws {
        let app = makeApp(pid: 2000)
        let fix = makeFixture(apps: [app])
        await routeToAAndB(app, in: fix)
        let tap = try #require(fix.log.tap(forPID: 2000))
        #expect(tap.currentDeviceUIDs == [fix.a.uid, fix.b.uid])
        let eventsBefore = tap.events.count

        fix.changeDefault(to: fix.c)
        await fix.settle()

        #expect(tap.currentDeviceUIDs == [fix.a.uid, fix.b.uid])
        #expect(tap.events.count == eventsBefore)
        #expect(fix.engine.isMultiRouted(app.id))
    }

    @Test("A multi-device tap captures the device-independent mixdown, never the default's stream")
    func capturesMixdown() async throws {
        let app = makeApp(pid: 2000)
        let fix = makeFixture(apps: [app])
        await routeToAAndB(app, in: fix)
        let tap = try #require(fix.log.tap(forPID: 2000))

        var sources: [String?] = []
        for event in tap.events {
            if case .updateDevices(_, let source, _) = event { sources.append(source) }
        }
        #expect(sources.count == 1)
        let source = try #require(sources.last)
        #expect(source == nil)
    }

    @Test("A single-device app following the default still moves with it")
    func singleAppStillFollows() async throws {
        let multi = makeApp(pid: 2000)
        let single = makeApp(pid: 2001)
        let fix = makeFixture(apps: [multi, single])
        await routeToAAndB(multi, in: fix)
        fix.engine.setDevice(for: single, deviceUID: nil)
        let singleTap = try #require(fix.log.tap(forPID: 2001))

        fix.changeDefault(to: fix.c)
        await fix.settle()

        #expect(singleTap.currentDeviceUIDs == [fix.c.uid])
        #expect(fix.engine.getDeviceUID(for: single) == fix.c.uid)
        #expect(fix.log.tap(forPID: 2000)?.currentDeviceUIDs == [fix.a.uid, fix.b.uid])
    }

    @Test("Back in single-device mode, the app joins the default chosen meanwhile")
    func backToSingleJoinsCurrentDefault() async throws {
        let app = makeApp(pid: 2000)
        let fix = makeFixture(apps: [app])
        await routeToAAndB(app, in: fix)
        let tap = try #require(fix.log.tap(forPID: 2000))
        fix.changeDefault(to: fix.c)
        await fix.settle()

        fix.engine.setDeviceSelectionMode(for: app, to: .single)
        await fix.settle()

        #expect(tap.currentDeviceUIDs == [fix.c.uid])
        #expect(fix.engine.getDeviceUID(for: app) == fix.c.uid)
        #expect(!fix.engine.isMultiRouted(app.id))
    }
}
