// FineTuneTests/Mocks/MockProcessTapController.swift
//
// Mock implementation of ProcessTapControlling for testing AudioEngine
// and other components that depend on process tap lifecycle.

import Foundation
import AudioToolbox
@testable import FineTune

/// Mock implementation of ProcessTapControlling for testing.
/// Records all method calls for verification in tests.
@MainActor
final class MockProcessTapController: ProcessTapControlling {
    /// Records all method invocations for test assertions.
    enum Event: Equatable {
        case activate(TapInitialStateSnapshot)
        case invalidate
        case invalidateAsync
        case updateEQSettings(EQSettings)
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case switchDevice(to: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool)
        case updateDevices(to: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool)
        case refreshTapSource(String?)
        case recreateForOutputRateChange
    }

    /// Plain snapshot of TapInitialState for test assertions.
    struct TapInitialStateSnapshot: Equatable {
        var eqSettings: EQSettings
        var autoEQProfileID: String?
        var autoEQPreampEnabled: Bool
        var loudnessVolume: Float
        var loudnessCompensationEnabled: Bool
        var loudnessEqualizerSettings: LoudnessEqualizerSettings

        @MainActor
        init(_ s: TapInitialState) {
            self.eqSettings = s.eqSettings
            self.autoEQProfileID = s.autoEQProfile?.id
            self.autoEQPreampEnabled = s.autoEQPreampEnabled
            self.loudnessVolume = s.loudnessVolume
            self.loudnessCompensationEnabled = s.loudnessCompensationEnabled
            self.loudnessEqualizerSettings = s.loudnessEqualizerSettings
        }
    }

    let app: AudioApp
    private(set) var events: [Event] = []
    private(set) var isActive = false

    // Mutable surface — recorded as plain property writes (not events).
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil

    /// Controls whether activate() throws.
    var activateShouldThrow = false

    /// Controls whether switchDevice/updateDevices throw.
    var switchShouldThrow = false

    init(app: AudioApp, deviceUIDs: [String] = []) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        if activateShouldThrow {
            throw NSError(domain: "MockProcessTapController", code: -1)
        }
        events.append(.activate(TapInitialStateSnapshot(initial)))
        isActive = true
    }

    func invalidate() {
        events.append(.invalidate)
        isActive = false
    }

    func invalidateAsync() async {
        events.append(.invalidateAsync)
        isActive = false
    }

    func updateEQSettings(_ settings: EQSettings) {
        events.append(.updateEQSettings(settings))
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        events.append(.updateAutoEQProfile(profileID: profile?.id))
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        events.append(.setAutoEQPreampEnabled(enabled))
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        events.append(.updateLoudnessCompensation(volume: volume, enabled: enabled))
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        events.append(.updateLoudnessEqualization(settings))
    }

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        if switchShouldThrow {
            throw NSError(domain: "MockProcessTapController", code: -2)
        }
        events.append(.switchDevice(to: newDeviceUID, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: sourceDeviceDead))
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        if switchShouldThrow {
            throw NSError(domain: "MockProcessTapController", code: -3)
        }
        events.append(.updateDevices(to: newDeviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: sourceDeviceDead))
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        events.append(.refreshTapSource(preferredDeviceUID))
        tapSourceDeviceUID = preferredDeviceUID
    }

    func recreateForOutputRateChange() async throws {
        events.append(.recreateForOutputRateChange)
    }
}
