// FineTuneTests/DeviceKeepAliveTests.swift
//
// DeviceKeepAliveService must never leave a device it is enabled for without a running
// keep-alive stream while the device is connected. These tests drive its supervision pass
// (`check(now:)`) directly with fake streams, so no HAL device is involved.

import Testing
import Foundation
import AudioToolbox
@testable import FineTune

@MainActor
private final class FakeStream: KeepAliveStreaming {
    let deviceID: AudioDeviceID
    var renderedCycles: UInt64 = 0
    var isRunning = false
    var startError: Error?

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    func start() throws {
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

@MainActor
private final class Fixture {
    let settings: SettingsManager
    let devices = MockAudioDeviceMonitor()
    var streams: [FakeStream] = []
    var failNextStarts = 0
    var hogOwner: pid_t = -1
    lazy var service = DeviceKeepAliveService(
        settingsManager: settings,
        deviceProvider: devices,
        makeStream: { [unowned self] deviceID, _ in
            let stream = FakeStream(deviceID: deviceID)
            if self.failNextStarts > 0 {
                self.failNextStarts -= 1
                stream.startError = KeepAliveError.startFailed(-50)
            }
            self.streams.append(stream)
            return stream
        },
        isAlive: { _ in true },
        hogModeOwner: { [unowned self] _ in self.hogOwner }
    )

    let dac = AudioDevice(id: AudioDeviceID(120), uid: "uid-keepalive-dac", name: "DAC", icon: nil, supportsAutoEQ: false)

    init() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        settings = SettingsManager(directory: tempDir)
        devices.addOutputDevice(dac)
    }

    var running: [FakeStream] { streams.filter(\.isRunning) }

    /// Simulates the HAL calling the stream's IO callback.
    func render() {
        for stream in running { stream.renderedCycles += 1 }
    }
}

@Suite("DeviceKeepAliveService — supervision of the keep-alive streams")
@MainActor
struct DeviceKeepAliveTests {

    @Test("Turning it on starts a stream on the device and reports it running once it renders")
    func startsAndRuns() {
        let fix = Fixture()
        fix.service.setEnabled(true, for: fix.dac.uid)

        #expect(fix.running.count == 1)
        #expect(fix.running.first?.deviceID == fix.dac.id)
        #expect(fix.service.status(for: fix.dac.uid) == .starting)

        let now = ContinuousClock.now
        fix.render()
        fix.service.check(now: now)
        fix.render()
        fix.service.check(now: now.advanced(by: .milliseconds(1000)))
        #expect(fix.service.status(for: fix.dac.uid) == .running)
        #expect(fix.settings.isKeepAliveEnabled(for: fix.dac.uid))
    }

    @Test("Turning it off stops the stream")
    func stopsWhenTurnedOff() {
        let fix = Fixture()
        fix.service.setEnabled(true, for: fix.dac.uid)
        fix.service.setEnabled(false, for: fix.dac.uid)

        #expect(fix.running.isEmpty)
        #expect(fix.service.status(for: fix.dac.uid) == nil)
    }

    @Test("Unplugging stops the stream; plugging back in with a new device ID starts a new one")
    func followsReconnection() {
        let fix = Fixture()
        fix.service.setEnabled(true, for: fix.dac.uid)

        fix.devices.outputDevices = []
        fix.service.check()
        #expect(fix.running.isEmpty)

        let reconnected = AudioDevice(id: AudioDeviceID(121), uid: fix.dac.uid, name: "DAC", icon: nil, supportsAutoEQ: false)
        fix.devices.outputDevices = [reconnected]
        fix.service.check()
        #expect(fix.running.count == 1)
        #expect(fix.running.first?.deviceID == reconnected.id)
    }

    @Test("A stream whose IO stops for two checks is rebuilt")
    func rebuildsStalledStream() {
        let fix = Fixture()
        fix.service.setEnabled(true, for: fix.dac.uid)
        let now = ContinuousClock.now
        fix.render()
        fix.service.check(now: now)
        fix.render()
        fix.service.check(now: now.advanced(by: .milliseconds(1000)))
        let first = fix.streams[0]

        // The HAL stops calling the stream (sleep, USB reset, format change gone wrong)
        fix.service.check(now: now.advanced(by: .milliseconds(2000)))
        #expect(first.isRunning)
        fix.service.check(now: now.advanced(by: .milliseconds(3000)))
        #expect(!first.isRunning)

        // Retried on a later pass, as a brand-new stream
        fix.service.check(now: now.advanced(by: .milliseconds(5000)))
        #expect(fix.running.count == 1)
        #expect(fix.running.first !== first)
    }

    @Test("A failed start is retried with a growing delay, and never given up")
    func retriesFailedStart() {
        let fix = Fixture()
        fix.failNextStarts = 2
        let now = ContinuousClock.now
        fix.settings.setKeepAliveEnabled(true, for: fix.dac.uid)

        fix.service.check(now: now)
        #expect(fix.service.status(for: fix.dac.uid) == .failed(-50))
        #expect(fix.streams.count == 1)

        fix.service.check(now: now.advanced(by: .milliseconds(500)))  // before the 1 s retry
        #expect(fix.streams.count == 1)

        fix.service.check(now: now.advanced(by: .milliseconds(1100)))  // fails again, next retry in 2 s
        #expect(fix.streams.count == 2)
        fix.service.check(now: now.advanced(by: .milliseconds(2500)))
        #expect(fix.streams.count == 2)

        fix.service.check(now: now.advanced(by: .milliseconds(3200)))  // succeeds
        #expect(fix.running.count == 1)
    }

    @Test("A device held in exclusive mode by another app is reported, then taken once released")
    func waitsForHogMode() {
        let fix = Fixture()
        fix.hogOwner = 4242
        let now = ContinuousClock.now
        fix.settings.setKeepAliveEnabled(true, for: fix.dac.uid)

        fix.service.check(now: now)
        #expect(fix.service.status(for: fix.dac.uid) == .blockedByHogMode(4242))
        #expect(fix.streams.isEmpty)

        // Polled without backoff: taken on the very next pass after the other app lets go
        fix.service.check(now: now.advanced(by: .milliseconds(100)))
        #expect(fix.streams.isEmpty)
        fix.hogOwner = -1
        fix.service.check(now: now.advanced(by: .milliseconds(200)))
        #expect(fix.running.count == 1)
    }

    @Test("Extra passes right after a heartbeat sample do not count as a stall")
    func eventDrivenChecksAreNotStalls() {
        let fix = Fixture()
        fix.service.setEnabled(true, for: fix.dac.uid)
        let now = ContinuousClock.now
        fix.render()
        fix.service.check(now: now)
        fix.render()
        fix.service.check(now: now.advanced(by: .seconds(1)))
        #expect(fix.service.status(for: fix.dac.uid) == .running)

        // A burst of device-list events, all within one IO cycle: the counter cannot have moved
        for offset in 1...5 {
            fix.service.check(now: now.advanced(by: .milliseconds(1000 + offset)))
        }
        #expect(fix.running.count == 1)
        #expect(fix.streams.count == 1)

        fix.render()
        fix.service.check(now: now.advanced(by: .seconds(2)))
        #expect(fix.streams.count == 1)
        #expect(fix.service.status(for: fix.dac.uid) == .running)
    }

    @Test("A missed wake notification is recovered when the screens wake")
    func screensWakeEndsSleep() {
        let fix = Fixture()
        fix.service.setEnabled(true, for: fix.dac.uid)

        fix.service.handleScreensDidWake()  // display sleep only: nothing to do
        #expect(fix.streams.count == 1)

        fix.service.handleWillSleep()
        #expect(fix.running.isEmpty)
        fix.service.handleScreensDidWake()
        #expect(fix.running.count == 1)
    }

    @Test("Streams stop before system sleep and come back after wake")
    func survivesSleep() {
        let fix = Fixture()
        fix.service.setEnabled(true, for: fix.dac.uid)

        fix.service.handleWillSleep()
        #expect(fix.running.isEmpty)
        fix.service.check()  // nothing restarts while asleep
        #expect(fix.running.isEmpty)

        fix.service.handleDidWake()
        #expect(fix.running.count == 1)
    }

    @Test("Saved keep-alive devices are decoded; none by default")
    func decoding() throws {
        let saved = try JSONDecoder().decode(
            SettingsManager.Settings.self,
            from: Data(#"{ "keepAliveDeviceUIDs": ["a", "b"], "appSettings": {} }"#.utf8)
        )
        #expect(saved.keepAliveDeviceUIDs == ["a", "b"])

        let empty = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(#"{ "appSettings": {} }"#.utf8))
        #expect(empty.keepAliveDeviceUIDs.isEmpty)
    }
}
