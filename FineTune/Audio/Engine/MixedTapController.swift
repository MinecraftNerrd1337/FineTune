// FineTune/Audio/Engine/MixedTapController.swift
import AudioToolbox
import Foundation
import os

/// An app's tap in the per-DAC routing mode.
///
/// On one plain stereo device the app plays through that device's `DeviceMixer`, in a slot
/// of its shared aggregate: AutoEQ then runs once per DAC, on the sum of its apps. Everywhere
/// else (several devices, a multichannel or virtual device, a full mixer) it plays through a
/// `ProcessTapController` of its own, exactly as in the per-app mode. The engine sees one
/// controller either way, and the controller moves between the two as the app's devices change.
///
/// ## Device switches
/// Moving to another mixer captures the app on the new device first, faded out, waits until its
/// audio arrives there (a newly pointed tap needs 50 to 200 ms), then fades the new slot in and
/// the old one out before releasing it. Both taps mute the app, so it never plays directly and
/// the old device keeps playing it until the new one does. Moves to or from an own aggregate
/// overlap the same way, without the fade on the own side (its own soft-start and ramp).
@MainActor
final class MixedTapController: ProcessTapControlling {

    let app: AudioApp
    private let registry: DeviceMixerRegistry
    private weak var deviceMonitor: AudioDeviceMonitor?
    private let logger: Logger

    private enum Path {
        case none
        case mixed(DeviceMixer, DeviceMixSlot)
        case own(ProcessTapController)
    }

    private var path: Path = .none
    private var targetDeviceUIDs: [String]
    private(set) var currentDeviceUIDs: [String] = []
    private var requestedTapSourceDeviceUID: String?
    private var activated = false
    private var activationHostTime: UInt64 = 0
    /// Device switches run one at a time.
    private var isSwitching = false

    // The app's settings, kept to start either path with them
    private var _volume: Float = 1
    private var _isMuted = false
    private var _currentDeviceVolume: Float = 1
    private var _isDeviceMuted = false
    private var initial = TapInitialState()
    private var autoEQProfilesByDevice: [String: AutoEQProfile?] = [:]
    private var outputGainsByDevice: [String: Float] = [:]

    /// How long a device switch waits for the app's audio on the new device.
    static let arrivalTimeout: Duration = .milliseconds(400)

    init(
        app: AudioApp,
        targetDeviceUIDs: [String],
        registry: DeviceMixerRegistry,
        deviceMonitor: AudioDeviceMonitor?,
        preferredTapSourceDeviceUID: String?
    ) {
        precondition(!targetDeviceUIDs.isEmpty, "Must have at least one target device")
        self.app = app
        self.targetDeviceUIDs = targetDeviceUIDs
        self.registry = registry
        self.deviceMonitor = deviceMonitor
        requestedTapSourceDeviceUID = preferredTapSourceDeviceUID
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "MixedTapController(\(app.name))")
    }

    // MARK: - State

    var volume: Float {
        get { _volume }
        set {
            _volume = newValue
            switch path {
            case .mixed(_, let slot): slot.volume = newValue
            case .own(let tap): tap.volume = newValue
            case .none: break
            }
        }
    }

    var isMuted: Bool {
        get { _isMuted }
        set {
            _isMuted = newValue
            switch path {
            case .mixed(_, let slot): slot.isMuted = newValue
            case .own(let tap): tap.isMuted = newValue
            case .none: break
            }
        }
    }

    var currentDeviceVolume: Float {
        get { _currentDeviceVolume }
        set {
            _currentDeviceVolume = newValue
            if case .own(let tap) = path { tap.currentDeviceVolume = newValue }
        }
    }

    var isDeviceMuted: Bool {
        get { _isDeviceMuted }
        set {
            _isDeviceMuted = newValue
            if case .own(let tap) = path { tap.isDeviceMuted = newValue }
        }
    }

    var audioLevel: Float {
        switch path {
        case .mixed(_, let slot): return slot.peakLevel
        case .own(let tap): return tap.audioLevel
        case .none: return 0
        }
    }

    var currentDeviceUID: String? { currentDeviceUIDs.first }

    var capturedProcessObjectIDs: Set<AudioObjectID> {
        switch path {
        case .mixed(let mixer, let slot): return mixer.capturedProcesses(of: slot)
        case .own(let tap): return tap.capturedProcessObjectIDs
        case .none: return []
        }
    }

    var tapSourceDeviceUID: String? {
        if case .own(let tap) = path { return tap.tapSourceDeviceUID }
        return requestedTapSourceDeviceUID
    }

    /// Whether the app currently plays through a per-DAC mixer (diagnostics, tests).
    var isMixed: Bool {
        if case .mixed = path { return true }
        return false
    }

    // MARK: - Lifecycle

    func activate(initial: TapInitialState) throws {
        guard !activated else { return }
        self.initial = initial
        activationHostTime = mach_absolute_time()
        path = try makePath(for: targetDeviceUIDs, tapSource: requestedTapSourceDeviceUID, fadedIn: true)
        currentDeviceUIDs = targetDeviceUIDs
        activated = true
    }

    func invalidate() {
        let old = path
        path = .none
        activated = false
        release(old)
    }

    func invalidateAsync() async {
        let old = path
        path = .none
        activated = false
        if case .own(let tap) = old {
            await tap.invalidateAsync()
        } else {
            release(old)
        }
    }

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        try await updateDevices(to: [newDeviceUID], preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: sourceDeviceDead)
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        guard !newDeviceUIDs.isEmpty else { return }
        guard activated else {
            targetDeviceUIDs = newDeviceUIDs
            requestedTapSourceDeviceUID = preferredTapSourceDeviceUID
            return
        }
        guard !isSwitching else {
            logger.warning("Device switch already in progress, skipping")
            return
        }
        isSwitching = true
        defer { isSwitching = false }

        let mixable = registry.canMix(deviceUIDs: newDeviceUIDs)
        switch path {
        case .mixed(let mixer, _) where mixable && newDeviceUIDs == [mixer.deviceUID]:
            // Same mixer: only the tap source preference changed, which a mixer does not use
            requestedTapSourceDeviceUID = preferredTapSourceDeviceUID
            return
        case .own(let tap) where !mixable || newDeviceUIDs == currentDeviceUIDs:
            // Own aggregate to own aggregate, or staying on the same device (no overlap of two
            // paths on one device, which would play the app twice): it switches by itself
            requestedTapSourceDeviceUID = preferredTapSourceDeviceUID
            try await tap.updateDevices(to: newDeviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: sourceDeviceDead)
            targetDeviceUIDs = newDeviceUIDs
            currentDeviceUIDs = tap.currentDeviceUIDs
            return
        default:
            break
        }

        // Change of path: start the new one beside the old one, then hand over
        let old = path
        let crossfade = !sourceDeviceDead && !isNone(old)
        let next = try makePath(for: newDeviceUIDs, tapSource: preferredTapSourceDeviceUID, fadedIn: !crossfade)
        requestedTapSourceDeviceUID = preferredTapSourceDeviceUID
        targetDeviceUIDs = newDeviceUIDs
        path = next
        currentDeviceUIDs = newDeviceUIDs

        if crossfade {
            await handOver(from: old, to: next)
        } else {
            release(old)
        }
        logger.info("\(self.app.name) moved to \(newDeviceUIDs, privacy: .public) (\(self.isMixed ? "per-DAC mixer" : "own aggregate", privacy: .public))")
    }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        requestedTapSourceDeviceUID = preferredDeviceUID
        if case .own(let tap) = path {
            try await tap.refreshTapSource(preferredDeviceUID)
        }
    }

    // MARK: - Settings

    func updateEQSettings(_ settings: EQSettings) {
        initial.eqSettings = settings
        switch path {
        case .mixed(_, let slot): slot.updateEQSettings(settings)
        case .own(let tap): tap.updateEQSettings(settings)
        case .none: break
        }
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        initial.autoEQProfile = profile
        switch path {
        case .mixed(let mixer, _): mixer.updateAutoEQProfile(profile)
        case .own(let tap): tap.updateAutoEQProfile(profile)
        case .none: break
        }
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?, for deviceUID: String) {
        autoEQProfilesByDevice.updateValue(profile, forKey: deviceUID)
        if case .own(let tap) = path { tap.updateAutoEQProfile(profile, for: deviceUID) }
    }

    func setOutputGain(_ gain: Float, for deviceUID: String) {
        outputGainsByDevice[deviceUID] = gain
        if case .own(let tap) = path { tap.setOutputGain(gain, for: deviceUID) }
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        initial.autoEQPreampEnabled = enabled
        switch path {
        case .mixed(let mixer, _): mixer.setAutoEQPreampEnabled(enabled)
        case .own(let tap): tap.setAutoEQPreampEnabled(enabled)
        case .none: break
        }
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        initial.loudnessVolume = volume
        initial.loudnessCompensationEnabled = enabled
        switch path {
        case .mixed(_, let slot): slot.updateLoudnessCompensation(volume: volume, enabled: enabled)
        case .own(let tap): tap.updateLoudnessCompensation(volume: volume, enabled: enabled)
        case .none: break
        }
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        initial.loudnessEqualizerSettings = settings
        switch path {
        case .mixed(let mixer, let slot): slot.updateLoudnessEqualization(settings, sampleRate: mixer.sampleRate)
        case .own(let tap): tap.updateLoudnessEqualization(settings)
        case .none: break
        }
    }

    // MARK: - Health and format changes

    func hasRecentAudioCallback(within seconds: Double) -> Bool {
        switch path {
        case .mixed(let mixer, _):
            let last = mixer.lastRenderHostTime
            guard last != 0 else { return false }
            return DeviceMixer.nanoseconds(from: last, to: mach_absolute_time()) <= seconds * 1_000_000_000
        case .own(let tap):
            return tap.hasRecentAudioCallback(within: seconds)
        case .none:
            return false
        }
    }

    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool {
        switch path {
        case .mixed(_, let slot):
            guard slot.lastRenderHostTime != 0, activationHostTime != 0 else { return false }
            return DeviceMixer.nanoseconds(from: activationHostTime, to: mach_absolute_time()) >= minActiveSeconds * 1_000_000_000
        case .own(let tap):
            return tap.isHealthCheckEligible(minActiveSeconds: minActiveSeconds)
        case .none:
            return false
        }
    }

    func hasOutputSampleRateMismatch() -> Bool {
        switch path {
        case .mixed(let mixer, _): return mixer.hasOutputSampleRateMismatch()
        case .own(let tap): return tap.hasOutputSampleRateMismatch()
        case .none: return false
        }
    }

    func prepareForOutputFormatChange() {
        switch path {
        case .mixed(let mixer, _): mixer.prepareForOutputFormatChange()
        case .own(let tap): tap.prepareForOutputFormatChange()
        case .none: break
        }
    }

    func cancelOutputFormatChangePreparation() {
        switch path {
        case .mixed(let mixer, _): mixer.cancelOutputFormatChangePreparation()
        case .own(let tap): tap.cancelOutputFormatChangePreparation()
        case .none: break
        }
    }

    func recreateForOutputRateChange() async throws {
        switch path {
        case .mixed(let mixer, _): try mixer.recreateForOutputRateChange()
        case .own(let tap): try await tap.recreateForOutputRateChange()
        case .none: break
        }
    }

    // MARK: - Paths

    private func makePath(for deviceUIDs: [String], tapSource: String?, fadedIn: Bool) throws -> Path {
        if registry.canMix(deviceUIDs: deviceUIDs) {
            do {
                let mixer = try registry.mixer(
                    for: deviceUIDs[0], autoEQ: initial.autoEQProfile, preampEnabled: initial.autoEQPreampEnabled
                )
                if let slot = mixer.acquireSlot(processes: app.processObjectIDs, settings: slotSettings, fadedIn: fadedIn) {
                    // The device's correction is shared: an app whose profile is not resolved
                    // yet (nil until the engine's async resolve) must not switch it off
                    if let profile = initial.autoEQProfile {
                        mixer.updateAutoEQProfile(profile)
                    }
                    mixer.setAutoEQPreampEnabled(initial.autoEQPreampEnabled)
                    return .mixed(mixer, slot)
                }
                logger.info("The mixer of \(deviceUIDs[0], privacy: .public) is full; \(self.app.name) gets its own aggregate")
                registry.releaseIfIdle(deviceUIDs[0])
            } catch {
                logger.error("Mixer unavailable (\(error.localizedDescription, privacy: .public)); \(self.app.name) gets its own aggregate")
            }
        }

        let tap = ProcessTapController(
            app: app,
            targetDeviceUIDs: deviceUIDs,
            deviceMonitor: deviceMonitor,
            preferredTapSourceDeviceUID: tapSource
        )
        tap.volume = _volume
        tap.isMuted = _isMuted
        tap.currentDeviceVolume = _currentDeviceVolume
        tap.isDeviceMuted = _isDeviceMuted
        for (uid, gain) in outputGainsByDevice { tap.setOutputGain(gain, for: uid) }
        for (uid, profile) in autoEQProfilesByDevice { tap.updateAutoEQProfile(profile, for: uid) }
        try tap.activate(initial: initial)
        return .own(tap)
    }

    private var slotSettings: DeviceMixSlot.Settings {
        DeviceMixSlot.Settings(
            volume: _volume,
            isMuted: _isMuted,
            eqSettings: initial.eqSettings,
            loudnessEqualizerSettings: initial.loudnessEqualizerSettings,
            loudnessCompensationEnabled: initial.loudnessCompensationEnabled,
            loudnessVolume: initial.loudnessVolume
        )
    }

    /// Plays `next` in place of `old`, both running: waits for the app's audio to reach a new
    /// mixer slot, fades it in and the old slot out, then releases `old`.
    private func handOver(from old: Path, to next: Path) async {
        if case .mixed(_, let slot) = next {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.arrivalTimeout)
            while slot.lastAudibleHostTime == 0, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            slot.fadeTarget = 1
        } else {
            // An own aggregate soft-starts by itself; let its audio arrive
            try? await Task.sleep(for: .milliseconds(150))
        }
        if case .mixed(_, let oldSlot) = old {
            oldSlot.fadeTarget = 0
        }
        try? await Task.sleep(for: .seconds(DeviceMixer.fadeSeconds + 0.03))
        release(old)
    }

    private func release(_ old: Path) {
        switch old {
        case .mixed(let mixer, let slot):
            mixer.releaseSlot(slot)
            registry.releaseIfIdle(mixer.deviceUID)
        case .own(let tap):
            tap.invalidate()
        case .none:
            break
        }
    }

    private func isNone(_ path: Path) -> Bool {
        if case .none = path { return true }
        return false
    }
}
