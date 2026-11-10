// FineTuneTests/AudioEngineMasterVolumeTests.swift
//
// The master volume is a gain FineTune applies on top of an output device's own volume,
// whatever its backend, remembered per device. Like a software-backed device's volume, it is
// folded into the gain (`volume`) of the taps playing on that device alone, and leaves that
// gain exactly as is at 100%. The master slider sets the default output device's. The apps
// in these tests are at 100% with no boost, so a tap's gain is the master volume itself.
// Reuses RecordingProcessTapController + StubProcessMonitor from AudioEngineTapInitialStateTests.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Fixture

@MainActor
private final class TapLog {
    var all: [RecordingProcessTapController] = []

    func last(forPID pid: pid_t) -> RecordingProcessTapController? {
        all.last { $0.app.id == pid }
    }
}

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let processMonitor: StubProcessMonitor
    let volumeMonitor: MockDeviceVolumeProviding
    let deviceA: AudioDevice
    let deviceB: AudioDevice
    let log: TapLog
}

@MainActor
private func makeApp(pid: pid_t) -> AudioApp {
    AudioApp(
        id: pid,
        processObjectIDs: [],
        name: "Player \(pid)",
        icon: NSImage(),
        bundleID: "com.test.master-volume.\(pid)"
    )
}

@MainActor
private func makeFixture(apps: [AudioApp]) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let deviceA = AudioDevice(id: AudioDeviceID(96), uid: "uid-master-a", name: "DAC A", icon: nil, supportsAutoEQ: false)
    let deviceB = AudioDevice(id: AudioDeviceID(97), uid: "uid-master-b", name: "DAC B", icon: nil, supportsAutoEQ: false)
    deviceMonitor.addOutputDevice(deviceA)
    deviceMonitor.addOutputDevice(deviceB)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[deviceA.id] = 0.75
    mockVolume.volumes[deviceB.id] = 0.75

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = apps

    let log = TapLog()

    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            log.all.append(tap)
            return tap
        },
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        processMonitor: processMonitor,
        volumeMonitor: mockVolume,
        deviceA: deviceA,
        deviceB: deviceB,
        log: log
    )
}

// MARK: - Suite

@Suite("AudioEngine master volume — per device, in the gain of the taps on that device")
@MainActor
struct AudioEngineMasterVolumeTests {

    @Test("A device's master volume reaches the taps playing on it")
    func reachesTap() throws {
        let app = makeApp(pid: 1000)
        let fix = makeFixture(apps: [app])
        fix.engine.setDevice(for: app, deviceUID: fix.deviceA.uid)
        let tap = try #require(fix.log.last(forPID: 1000))

        fix.engine.setDeviceMasterVolume(0.25, for: fix.deviceA.uid)

        #expect(tap.volume == 0.25)
        #expect(fix.engine.deviceMasterVolume(for: fix.deviceA.uid) == 0.25)
    }

    @Test("Taps on another device keep their own device's master volume")
    func otherDeviceUntouched() throws {
        let onA = makeApp(pid: 1000)
        let onB = makeApp(pid: 2000)
        let fix = makeFixture(apps: [onA, onB])
        fix.engine.setDevice(for: onA, deviceUID: fix.deviceA.uid)
        fix.engine.setDevice(for: onB, deviceUID: fix.deviceB.uid)
        let tapB = try #require(fix.log.last(forPID: 2000))

        fix.engine.setDeviceMasterVolume(0.25, for: fix.deviceA.uid)

        #expect(tapB.volume == 1.0)
    }

    @Test("A tap created on a device starts with that device's master volume")
    func newTapStartsWithDeviceMaster() throws {
        let app = makeApp(pid: 1000)
        let fix = makeFixture(apps: [app])
        fix.engine.setDeviceMasterVolume(0.36, for: fix.deviceA.uid)

        fix.engine.setDevice(for: app, deviceUID: fix.deviceA.uid)
        let tap = try #require(fix.log.last(forPID: 1000))

        #expect(tap.volume == 0.36)
    }

    @Test("A tap moved to another device follows that device's master volume")
    func switchingDeviceFollows() async throws {
        let app = makeApp(pid: 1000)
        let fix = makeFixture(apps: [app])
        fix.engine.setDeviceMasterVolume(0.25, for: fix.deviceA.uid)
        fix.engine.setDevice(for: app, deviceUID: fix.deviceA.uid)
        let tap = try #require(fix.log.last(forPID: 1000))
        #expect(tap.volume == 0.25)

        // The switch itself is async: wait for the engine to re-apply the output state.
        fix.engine.setDevice(for: app, deviceUID: fix.deviceB.uid)
        for _ in 0..<100 where tap.volume != 1.0 {
            await Task.yield()
        }

        #expect(tap.volume == 1.0)
    }

    @Test("The master slider sets the default output device's master volume")
    func masterSliderFollowsDefaultDevice() {
        let fix = makeFixture(apps: [])
        fix.volumeMonitor.defaultDeviceID = fix.deviceA.id
        fix.volumeMonitor.defaultDeviceUID = fix.deviceA.uid

        fix.engine.setMasterVolume(0.5)

        #expect(fix.engine.masterVolume == 0.5)
        #expect(fix.engine.deviceMasterVolume(for: fix.deviceA.uid) == 0.5)
        #expect(fix.engine.deviceMasterVolume(for: fix.deviceB.uid) == 1.0)

        fix.volumeMonitor.defaultDeviceID = fix.deviceB.id
        fix.volumeMonitor.defaultDeviceUID = fix.deviceB.uid
        #expect(fix.engine.masterVolume == 1.0)
    }

    @Test("Back to 100% leaves the tap gain at exactly 1.0 and stores no entry")
    func backToUnity() throws {
        let app = makeApp(pid: 1000)
        let fix = makeFixture(apps: [app])
        fix.engine.setDevice(for: app, deviceUID: fix.deviceA.uid)
        let tap = try #require(fix.log.last(forPID: 1000))

        fix.engine.setDeviceMasterVolume(0.5, for: fix.deviceA.uid)
        fix.engine.setDeviceMasterVolume(1.0, for: fix.deviceA.uid)

        #expect(tap.volume == 1.0)
        #expect(fix.settings.getDeviceMasterVolume(for: fix.deviceA.uid) == 1.0)
    }

    @Test("Out-of-range values are clamped")
    func clamped() {
        let fix = makeFixture(apps: [])

        fix.engine.setDeviceMasterVolume(3.0, for: fix.deviceA.uid)
        #expect(fix.engine.deviceMasterVolume(for: fix.deviceA.uid) == 1.0)

        fix.engine.setDeviceMasterVolume(-1.0, for: fix.deviceA.uid)
        #expect(fix.engine.deviceMasterVolume(for: fix.deviceA.uid) == 0.0)

        fix.engine.setDeviceMasterVolume(.nan, for: fix.deviceA.uid)
        #expect(fix.engine.deviceMasterVolume(for: fix.deviceA.uid) == 1.0)
    }
}

// MARK: - Persistence

@Suite("Settings — per-device master volume decoding")
@MainActor
struct DeviceMasterVolumeDecodingTests {

    @Test("Saved master volumes are clamped, invalid ones dropped, ⌥ is on by default")
    func decoding() throws {
        let json = """
        {
            "deviceMasterVolumes": { "a": 0.5, "b": 2.0, "c": -1.0 },
            "appSettings": {}
        }
        """
        let settings = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))

        #expect(settings.deviceMasterVolumes == ["a": 0.5, "b": 1.0])
        #expect(settings.appSettings.masterVolumeOptionKeyEnabled)
    }
}

// MARK: - Color

@Suite("Master volume color while ⌥ is held")
struct MasterVolumeColorTests {
    private func accent(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    @Test("Orange next to a cool or neutral accent color")
    func orangeByDefault() {
        // Blue, purple, pink, green, graphite
        for color in [accent(0, 122, 255), accent(149, 61, 150), accent(247, 79, 158), accent(98, 186, 70), accent(140, 140, 140)] {
            #expect(MasterVolumeStyle.optionColor(forAccent: color) == .systemOrange)
        }
    }

    @Test("Cyan next to a warm accent color, so the two never match")
    func cyanNextToWarmAccent() {
        // Red, orange, yellow
        for color in [accent(224, 56, 62), accent(247, 130, 27), accent(255, 199, 38)] {
            #expect(MasterVolumeStyle.optionColor(forAccent: color) == .systemCyan)
        }
    }
}
