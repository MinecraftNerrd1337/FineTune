// FineTune/Audio/Engine/OutputFanOut.swift
import AudioToolbox
import Foundation

/// The per-device half of a tap that plays on several output devices at once.
///
/// FineTune's aggregate for such a tap is not stacked (`ProcessTapController.planAggregate`,
/// `isFannedOut`): each device has its own output buffer. Each buffer is rendered by its own
/// lane, which runs the whole chain of a single-device tap (app EQ, the device's AutoEQ,
/// loudness, limiter) with the device's own master volume. So every DAC gets what it would get
/// if the app played on it alone: its headphone correction, its master volume.
///
/// The chain is duplicated rather than shared because its processors keep filter state from one
/// buffer to the next: one instance fed the buffers of two devices would mix their histories.
///
/// ## Threads
/// `render` runs on the HAL I/O thread; everything else on the main thread. The lanes are
/// fixed at init. A lane's processors update themselves in an RT-safe way (atomic setup swaps,
/// crossfades); its loudness equalizer is replaced as a whole, the old one released later.
final class OutputFanOut: @unchecked Sendable {

    /// What every lane starts from, taken from the tap's single-device chain.
    struct Settings {
        var eqSettings: EQSettings?
        var autoEQPreampEnabled: Bool
        var loudnessEqualizerSettings: LoudnessEqualizerSettings
        var loudnessCompensationEnabled: Bool
        var loudnessVolume: Float
    }

    /// The chain of one output device.
    final class Lane: @unchecked Sendable {
        let deviceUID: String
        let eq: EQProcessor
        let autoEQ: AutoEQProcessor
        let loudnessCompensator: LoudnessCompensator
        /// Replaced as a whole when its settings change (the type is immutable).
        nonisolated(unsafe) var loudnessEqualizer: LoudnessEqualizer
        /// The device's gain on top of the app's: master volume × software output gain.
        /// Written by the main thread, read by the audio thread.
        nonisolated(unsafe) var gain: Float
        /// Position of the volume ramp. Audio thread only once rendering has started.
        nonisolated(unsafe) var currentVolume: Float
        let preferredLeft: Int
        let preferredRight: Int

        init(
            deviceUID: String, sampleRate: Double, settings: Settings, autoEQProfile: AutoEQProfile?,
            gain: Float, initialVolume: Float, preferredChannels: (left: Int, right: Int)
        ) {
            self.deviceUID = deviceUID
            eq = EQProcessor(sampleRate: sampleRate)
            if let eqSettings = settings.eqSettings {
                eq.updateSettings(eqSettings)
            }
            autoEQ = AutoEQProcessor(sampleRate: sampleRate)
            autoEQ.setPreampEnabled(settings.autoEQPreampEnabled)
            if let autoEQProfile {
                autoEQ.updateProfile(autoEQProfile)
            }
            loudnessCompensator = LoudnessCompensator(sampleRate: sampleRate)
            loudnessCompensator.updateForVolume(settings.loudnessVolume)
            if !settings.loudnessCompensationEnabled {
                loudnessCompensator.setEnabled(false)
            }
            loudnessEqualizer = LoudnessEqualizer(settings: settings.loudnessEqualizerSettings, sampleRate: Float(sampleRate))
            self.gain = gain
            currentVolume = initialVolume * gain
            preferredLeft = preferredChannels.left
            preferredRight = preferredChannels.right
        }
    }

    let lanes: [Lane]
    let sampleRate: Double
    /// One-buffer list through which each lane's output buffer is handed to the shared chain.
    /// Audio thread only.
    private let laneList: UnsafeMutableAudioBufferListPointer

    /// - Parameters:
    ///   - deviceUIDs: the aggregate's sub-devices, in the order of its output buffers.
    ///   - autoEQProfile: the correction of each device (nil = none).
    ///   - gain: the master volume × software gain of each device.
    ///   - initialVolume: the app's current gain, so the lanes start without a ramp.
    init?(
        deviceUIDs: [String], sampleRate: Double, settings: Settings,
        autoEQProfile: (String) -> AutoEQProfile?, gain: (String) -> Float, initialVolume: Float,
        preferredChannels: (String) -> (left: Int, right: Int)
    ) {
        guard deviceUIDs.count > 1 else { return nil }
        self.sampleRate = sampleRate
        lanes = deviceUIDs.map { uid in
            Lane(deviceUID: uid, sampleRate: sampleRate, settings: settings, autoEQProfile: autoEQProfile(uid),
                 gain: gain(uid), initialVolume: initialVolume, preferredChannels: preferredChannels(uid))
        }
        laneList = AudioBufferList.allocate(maximumBuffers: 1)
    }

    deinit {
        free(laneList.unsafeMutablePointer)
    }

    var deviceUIDs: [String] { lanes.map(\.deviceUID) }

    func lane(for deviceUID: String) -> Lane? {
        lanes.first { $0.deviceUID == deviceUID }
    }

    // MARK: - Settings (main thread)

    func updateEQSettings(_ settings: EQSettings) {
        for lane in lanes { lane.eq.updateSettings(settings) }
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?, for deviceUID: String) {
        lane(for: deviceUID)?.autoEQ.updateProfile(profile)
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        for lane in lanes { lane.autoEQ.setPreampEnabled(enabled) }
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        for lane in lanes {
            if enabled {
                lane.loudnessCompensator.updateForVolume(volume)
            } else {
                lane.loudnessCompensator.setEnabled(false)
            }
        }
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        for lane in lanes {
            let old = lane.loudnessEqualizer
            lane.loudnessEqualizer = LoudnessEqualizer(settings: settings, sampleRate: Float(sampleRate))
            // The audio thread may still be inside the old one for the buffer in progress
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { _ = old }
        }
    }

    func setGain(_ gain: Float, for deviceUID: String) {
        lane(for: deviceUID)?.gain = gain
    }

    // MARK: - Rendering (RT-safe)

    /// Renders every device's buffer from the tap's input, each through its own lane.
    /// Returns false, having written nothing, when the buffers do not match the lanes
    /// (the caller then falls back to the single-chain path).
    func render(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        targetVolume: Float,
        crossfadeMultiplier: Float,
        outputGateMultiplier: Float,
        rampCoefficient: Float
    ) -> Bool {
        let count = lanes.count
        guard outputBuffers.count == count else { return false }
        let list = laneList
        for index in 0..<count {
            let lane = lanes[index]
            list[0] = outputBuffers[index]
            var currentVolume = lane.currentVolume
            ProcessTapController.processMappedBuffers(
                inputBuffers: inputBuffers,
                outputBuffers: list,
                targetVol: targetVolume * lane.gain,
                crossfadeMultiplier: crossfadeMultiplier,
                outputGateMultiplier: outputGateMultiplier,
                rampCoefficient: rampCoefficient,
                preferredStereoLeft: lane.preferredLeft,
                preferredStereoRight: lane.preferredRight,
                currentVol: &currentVolume,
                eqProc: lane.eq,
                autoEQProc: lane.autoEQ,
                loudnessEqualizerProc: lane.loudnessEqualizer,
                loudnessCompensatorProc: lane.loudnessCompensator
            )
            lane.currentVolume = currentVolume
        }
        return true
    }
}
