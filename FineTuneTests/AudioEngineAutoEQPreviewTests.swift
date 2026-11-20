// FineTuneTests/AudioEngineAutoEQPreviewTests.swift
//
// While a preview is on, a device plays the profile it was given instead of its stored AutoEQ
// (AudioEngine.previewAutoEQ), and nothing is stored.
// Reuses RecordingProcessTapController + StubProcessMonitor from AudioEngineTapInitialStateTests.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@MainActor
private final class PreviewTapLog {
    var all: [RecordingProcessTapController] = []

    func last(forPID pid: pid_t) -> RecordingProcessTapController? {
        all.last { $0.app.id == pid }
    }
}

@MainActor
private struct PreviewFixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let dacA: AudioDevice
    let dacB: AudioDevice
    let log: PreviewTapLog
}

@MainActor
private func makePreviewApp(pid: pid_t) -> AudioApp {
    AudioApp(
        id: pid,
        processObjectIDs: [],
        name: "Player \(pid)",
        icon: NSImage(),
        bundleID: "com.test.autoeq-preview.\(pid)"
    )
}

@MainActor
private func makePreviewFixture(apps: [AudioApp]) -> PreviewFixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let dacA = AudioDevice(id: AudioDeviceID(131), uid: "uid-preview-a", name: "DAC A", icon: nil, supportsAutoEQ: true)
    let dacB = AudioDevice(id: AudioDeviceID(132), uid: "uid-preview-b", name: "DAC B", icon: nil, supportsAutoEQ: true)
    deviceMonitor.addOutputDevice(dacA)
    deviceMonitor.addOutputDevice(dacB)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = apps
    let log = PreviewTapLog()
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
    return PreviewFixture(engine: engine, settings: settings, dacA: dacA, dacB: dacB, log: log)
}

private func previewProfile(_ id: String, gainDB: Float = 3) -> AutoEQProfile {
    AutoEQProfile(
        id: id, name: id, source: .created, preampDB: -gainDB,
        filters: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: gainDB, q: 1)]
    )
}

private func lastAutoEQEvent(_ tap: RecordingProcessTapController) -> RecordingProcessTapController.Event? {
    tap.events.last { if case .updateAutoEQProfile = $0 { return true } else { return false } }
}

@Suite("AutoEQ preview — a device plays a profile it was given, without storing it")
@MainActor
struct AudioEngineAutoEQPreviewTests {

    @Test("A preview reaches the taps on the device, and ending it brings back its own AutoEQ")
    func previewAndEnd() throws {
        let app = makePreviewApp(pid: 2100)
        let fix = makePreviewFixture(apps: [app])
        fix.engine.setDevice(for: app, deviceUID: fix.dacA.uid)
        let tap = try #require(fix.log.last(forPID: 2100))

        fix.engine.previewAutoEQ(previewProfile("draft"), on: fix.dacA.uid)
        #expect(lastAutoEQEvent(tap) == .updateAutoEQProfile(profileID: "draft"))

        fix.engine.endAutoEQPreview(on: fix.dacA.uid)
        #expect(lastAutoEQEvent(tap) == .updateAutoEQProfile(profileID: nil))
        #expect(fix.settings.getAutoEQSelection(for: fix.dacA.uid) == nil)
    }

    @Test("A preview on one device leaves the taps on another alone")
    func otherDeviceUntouched() throws {
        let app = makePreviewApp(pid: 2101)
        let fix = makePreviewFixture(apps: [app])
        fix.engine.setDevice(for: app, deviceUID: fix.dacB.uid)
        let tap = try #require(fix.log.last(forPID: 2101))
        let before = tap.events.count

        fix.engine.previewAutoEQ(previewProfile("draft"), on: fix.dacA.uid)
        #expect(tap.events.count == before)
    }

    @Test("A tap created while previewing starts with the preview")
    func newTapStartsWithPreview() throws {
        let app = makePreviewApp(pid: 2102)
        let fix = makePreviewFixture(apps: [app])
        fix.engine.previewAutoEQ(previewProfile("draft"), on: fix.dacA.uid)
        fix.engine.setDevice(for: app, deviceUID: fix.dacA.uid)
        let tap = try #require(fix.log.last(forPID: 2102))

        guard case .activate(let initial) = tap.events.first else {
            Issue.record("first event is not activate: \(tap.events)")
            return
        }
        #expect(initial.autoEQProfileID == "draft")
    }
}
