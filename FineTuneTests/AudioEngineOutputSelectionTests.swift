import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class SelectionVolumeMonitor: DeviceVolumeProviding {
    var defaultDeviceID: AudioDeviceID = 1
    var defaultDeviceUID: String? = "speakers"
    var defaultInputDeviceUID: String?
    var volumes: [AudioDeviceID: Float] = [:]
    var muteStates: [AudioDeviceID: Bool] = [:]
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?
    var writes: [AudioDeviceID] = []

    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
        writes.append(deviceID)
        defaultDeviceID = deviceID
        defaultDeviceUID = deviceID == 1 ? "speakers" : "headphones"
        // Deliberately omit the callback: HAL acknowledgements can be lost.
        return true
    }
    func externalSelection(_ uid: String) {
        defaultDeviceUID = uid
        defaultDeviceID = uid == "speakers" ? 1 : 2
        onDefaultDeviceChanged?(uid)
    }
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool { true }
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) {}
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) {}
    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { .hardware }
    func start() {}
    func stop() {}
}

@MainActor
private struct SelectionFixture {
    let engine: AudioEngine
    let monitor: MockAudioDeviceMonitor
    let volume: SelectionVolumeMonitor
    let settings: SettingsManager
    let app: AudioApp
    let speakers: AudioDevice
    let headphones: AudioDevice
}

@MainActor
private func selectionFixture(headphonesKnown: Bool = true, preferHeadphones: Bool = false) -> SelectionFixture {
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var config = settings.appSettings
    config.showDeviceDisconnectAlerts = false
    config.lockInputDevice = false
    settings.updateAppSettings(config)
    settings.setDevicePriorityOrder(preferHeadphones ? ["headphones", "speakers"] : ["speakers", "headphones"])
    let speakers = AudioDevice(id: 1, uid: "speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    let headphones = AudioDevice(id: 2, uid: "headphones", name: "Headphones", icon: nil, supportsAutoEQ: false)
    let monitor = MockAudioDeviceMonitor()
    monitor.addOutputDevice(speakers)
    if headphonesKnown { monitor.addOutputDevice(headphones) }
    let volume = SelectionVolumeMonitor()
    let processes = StubProcessMonitor()
    let app = AudioApp(id: 54321, processObjectIDs: [], name: "Player", icon: NSImage(), bundleID: "test.player")
    processes.activeApps = [app]
    let permission = AudioRecordingPermission()
    permission.status = .authorized
    let engine = AudioEngine(permission: permission, settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(), deviceProvider: monitor,
        processMonitor: processes, deviceVolumeMonitor: volume,
        tapFactory: { app, uids, _ in RecordingProcessTapController(app: app, deviceUIDs: uids) },
        isAlive: { _ in true }, startMonitorsAutomatically: false)
    engine.setDevice(for: app, deviceUID: nil)
    return SelectionFixture(engine: engine, monitor: monitor, volume: volume, settings: settings,
                            app: app, speakers: speakers, headphones: headphones)
}

@Suite("Output selection respects macOS during reconnects", .serialized)
@MainActor
struct AudioEngineOutputSelectionTests {
    @Test("First macOS selection immediately after reconnect is not reverted")
    func firstSelectionAfterReconnect() {
        let f = selectionFixture()
        f.monitor.onDeviceConnected?(f.headphones.uid, f.headphones.name)
        f.volume.externalSelection("headphones")
        #expect(f.volume.writes.isEmpty)
        #expect(f.volume.defaultDeviceUID == "headphones")
        #expect(f.engine.getDeviceUID(for: f.app) == "headphones")
    }

    @Test("Rapid macOS selections are all honoured")
    func rapidSelections() {
        let f = selectionFixture()
        f.monitor.onDeviceConnected?(f.headphones.uid, f.headphones.name)
        for uid in ["headphones", "speakers", "headphones"] {
            f.volume.externalSelection(uid)
            #expect(f.engine.getDeviceUID(for: f.app) == uid)
        }
        #expect(f.volume.writes.isEmpty)
    }

    @Test("A default event before discovery survives connection-time priorities")
    func selectionBeforeDiscovery() {
        let f = selectionFixture(headphonesKnown: false)
        f.volume.externalSelection("headphones")
        f.monitor.addOutputDevice(f.headphones)
        f.monitor.onDeviceConnected?(f.headphones.uid, f.headphones.name)
        #expect(f.volume.writes.isEmpty)
        #expect(f.engine.getDeviceUID(for: f.app) == "headphones")
    }

    @Test("A missed echo never undoes a newer macOS selection")
    func missedEchoAfterNewSelection() async throws {
        let f = selectionFixture()
        #expect(f.engine.setDefaultOutputDevice(f.speakers.id))
        f.volume.externalSelection("headphones")
        #expect(f.engine.getDeviceUID(for: f.app) == "headphones")
        try await Task.sleep(for: .milliseconds(2200))
        #expect(f.volume.writes == [f.speakers.id])
        #expect(f.volume.defaultDeviceUID == "headphones")
        #expect(f.engine.getDeviceUID(for: f.app) == "headphones")
    }

    @Test("An unacknowledged old command cannot hide a later selection of the same device")
    func manualSelectionMatchingOldEcho() {
        let f = selectionFixture()
        #expect(f.engine.setDefaultOutputDevice(f.headphones.id))
        f.volume.externalSelection("speakers")
        f.volume.externalSelection("headphones")
        #expect(f.engine.getDeviceUID(for: f.app) == "headphones")
        #expect(f.volume.writes == [f.headphones.id])
    }

    @Test("Preferred reconnect still selects a device, then macOS can choose another")
    func preferredReconnectThenExternalSelection() {
        let f = selectionFixture(preferHeadphones: true)
        f.monitor.onDeviceConnected?(f.headphones.uid, f.headphones.name)
        #expect(f.volume.writes == [f.headphones.id])
        #expect(f.engine.getDeviceUID(for: f.app) == "headphones")
        f.volume.externalSelection("speakers")
        #expect(f.engine.getDeviceUID(for: f.app) == "speakers")
        #expect(f.volume.writes == [f.headphones.id])
    }
}
