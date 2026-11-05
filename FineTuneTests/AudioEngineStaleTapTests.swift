// FineTuneTests/AudioEngineStaleTapTests.swift
//
// A tap belongs to the Core Audio process objects it was created for, not to a PID.
// The stale-tap grace period only covers apps whose processes are still there (paused,
// device-change flicker), and an app is never captured by two taps: macOS re-attaches a
// relaunched app's new processes to the tap of its previous launch, which used to play
// the app twice (about +6 dB) until that tap's 30 s grace period ran out.
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

    func forPID(_ pid: pid_t) -> [RecordingProcessTapController] {
        all.filter { $0.app.id == pid }
    }
}

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let processMonitor: StubProcessMonitor
    let device: AudioDevice
    let log: TapLog

    /// Publishes an app list the way AudioProcessMonitor does. `streaming: nil` means every app streams.
    /// The engine's own stale pass runs on a 350 ms debounce timer; tests call `cleanupStaleTaps()`
    /// directly instead, so they don't depend on that timer firing on time during a parallel run.
    func publish(_ apps: [AudioApp], streaming: Set<pid_t>? = nil) {
        processMonitor.activeApps = apps
        processMonitor.streamingAppIDs = streaming
        processMonitor.onAppsChanged?(apps)
    }
}

@MainActor
private func makeApp(pid: pid_t, objects: [AudioObjectID]) -> AudioApp {
    AudioApp(
        id: pid,
        processObjectIDs: objects,
        name: "Player",
        icon: NSImage(),
        bundleID: "com.test.stale-tap"
    )
}

@MainActor
private func makeFixture(activeApp: AudioApp) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(98),
        uid: "uid-stale-tap-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: false
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = 0.75

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [activeApp]

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

    return Fixture(engine: engine, processMonitor: processMonitor, device: device, log: log)
}

// MARK: - Suite

@Suite("AudioEngine stale taps — a tap belongs to its processes, not to a PID")
@MainActor
struct AudioEngineStaleTapTests {

    @Test("A paused app keeps its tap through the grace period")
    func pausedAppKeepsTap() throws {
        let app = makeApp(pid: 1000, objects: [501])
        let fix = makeFixture(activeApp: app)
        fix.engine.setDevice(for: app, deviceUID: fix.device.uid)
        let tap = try #require(fix.log.all.last)

        // Paused: the process object stays in Core Audio, it only stops streaming.
        fix.publish([app], streaming: [])
        fix.engine.cleanupStaleTaps()

        #expect(!tap.events.contains(.invalidate))
    }

    @Test("A quit app's tap is released without waiting for the grace period")
    func quitAppReleasedAtOnce() throws {
        let app = makeApp(pid: 1000, objects: [501])
        let fix = makeFixture(activeApp: app)
        fix.engine.setDevice(for: app, deviceUID: fix.device.uid)
        let tap = try #require(fix.log.all.last)

        // Quit: the process object leaves Core Audio.
        fix.publish([])
        fix.engine.cleanupStaleTaps()

        #expect(tap.events.contains(.invalidate))
    }

    @Test("An app that quits while paused is released at once, not at the end of the grace period")
    func pausedThenQuitReleasedAtOnce() throws {
        let app = makeApp(pid: 1000, objects: [501])
        let fix = makeFixture(activeApp: app)
        fix.engine.setDevice(for: app, deviceUID: fix.device.uid)
        let tap = try #require(fix.log.all.last)

        fix.publish([app], streaming: [])
        fix.engine.cleanupStaleTaps()
        #expect(!tap.events.contains(.invalidate))

        fix.publish([])
        fix.engine.cleanupStaleTaps()
        #expect(tap.events.contains(.invalidate))
    }

    @Test("A relaunch releases the previous launch's tap before it is tapped")
    func relaunchReleasesPreviousTapFirst() throws {
        let firstLaunch = makeApp(pid: 1000, objects: [501])
        let fix = makeFixture(activeApp: firstLaunch)
        fix.engine.setDevice(for: firstLaunch, deviceUID: fix.device.uid)
        let oldTap = try #require(fix.log.all.last)

        // Quit and relaunch before the stale pass ran; macOS has already moved
        // the relaunch's process into the old tap.
        let relaunch = makeApp(pid: 2000, objects: [601])
        oldTap.capturedProcessObjectIDs = [601]
        fix.processMonitor.activeApps = [relaunch]
        fix.engine.setDevice(for: relaunch, deviceUID: fix.device.uid)

        #expect(oldTap.events.contains(.invalidate))
        #expect(fix.log.forPID(2000).count == 1)
    }

    @Test("A paused app's tap that Core Audio feeds another app's process into is released before that app is tapped")
    func overlappingStaleTapReleased() throws {
        let paused = makeApp(pid: 1000, objects: [501])
        let fix = makeFixture(activeApp: paused)
        fix.engine.setDevice(for: paused, deviceUID: fix.device.uid)
        let pausedTap = try #require(fix.log.all.last)

        let other = makeApp(pid: 2000, objects: [601])
        pausedTap.capturedProcessObjectIDs = [501, 601]
        fix.processMonitor.activeApps = [paused, other]
        fix.processMonitor.streamingAppIDs = [2000]
        fix.engine.setDevice(for: other, deviceUID: fix.device.uid)

        #expect(pausedTap.events.contains(.invalidate))
        #expect(fix.log.forPID(2000).count == 1)
    }

    @Test("A streaming app's tap is left alone when another app is tapped")
    func streamingTapUntouched() throws {
        let playing = makeApp(pid: 1000, objects: [501])
        let fix = makeFixture(activeApp: playing)
        fix.engine.setDevice(for: playing, deviceUID: fix.device.uid)
        let playingTap = try #require(fix.log.all.last)

        let other = makeApp(pid: 2000, objects: [601])
        fix.processMonitor.activeApps = [playing, other]
        fix.engine.setDevice(for: other, deviceUID: fix.device.uid)

        #expect(!playingTap.events.contains(.invalidate))
    }

    @Test("A PID reused by a new process gets a new tap instead of rescuing the old one")
    func reusedPIDGetsNewTap() throws {
        let firstLaunch = makeApp(pid: 1000, objects: [501])
        let fix = makeFixture(activeApp: firstLaunch)
        fix.engine.setDevice(for: firstLaunch, deviceUID: fix.device.uid)
        let oldTap = try #require(fix.log.all.last)

        // Paused: the tap enters its grace period.
        fix.publish([firstLaunch], streaming: [])
        fix.engine.cleanupStaleTaps()
        #expect(!oldTap.events.contains(.invalidate))

        // A new process with the same PID streams before the list ever showed the PID gone.
        let reused = makeApp(pid: 1000, objects: [701])
        fix.publish([reused])
        fix.engine.cleanupStaleTaps()

        #expect(oldTap.events.contains(.invalidate))
        let newTap = try #require(fix.log.all.last)
        #expect(newTap !== oldTap)
        #expect(newTap.app.processObjectIDs == [701])
    }
}
