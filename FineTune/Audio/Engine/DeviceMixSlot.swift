// FineTune/Audio/Engine/DeviceMixSlot.swift
import Accelerate
import AudioToolbox
import Foundation

/// One app's place in a `DeviceMixer`: the real-time chain of one app in the per-DAC mix.
///
/// In the per-DAC routing mode, the apps that play on an output device go through a single
/// aggregate for that device (`DeviceMixer`) instead of one aggregate each. The aggregate holds
/// a fixed set of process taps from the start, and each slot owns one of them. When an app
/// arrives, the mixer points the slot's tap at the app's processes; when it leaves, at none.
/// The aggregate's tap list never changes, so its IO never restarts (a tap-list change while
/// running restarts it, with a 50 ms gap in every app it plays).
///
/// The slot runs the app's chain on its tap's buffer: the chain of a single-device
/// `ProcessTapController` (volume ramp, soft-start gate, app EQ, loudness equalization and
/// compensation, limiter) without AutoEQ. `DeviceMixRenderer` adds the result to the device's
/// mix, then runs AutoEQ and the limiter once on the sum.
///
/// ## Threads
/// The main thread writes the settings, and the processors while the slot is inactive. The audio
/// thread reads them and owns the ramps, the gate and the meters. Aligned single-word loads and
/// stores are atomic on Apple CPUs (as in `ProcessTapController`); `OSMemoryBarrier` orders an
/// activation after its setup. Replaced processors are released half a second later, as the
/// audio thread may still be in the buffer it started with them.
final class DeviceMixSlot: @unchecked Sendable {

    /// What an app's chain starts from.
    struct Settings {
        var volume: Float = 1
        var isMuted = false
        var eqSettings: EQSettings = .flat
        var loudnessEqualizerSettings = LoudnessEqualizerSettings()
        var loudnessCompensationEnabled = false
        var loudnessVolume: Float = 1
    }

    /// Input below this peak is silence (about -80 dBFS), as for `ProcessTapController`'s gate.
    static let silenceThreshold: Float = 0.0001
    /// VU meter smoothing, as in `ProcessTapController`.
    static let levelSmoothing: Float = 0.3

    let index: Int
    let maxFrames: Int

    // MARK: Written by the main thread

    /// The renderer mixes the slot only while this is true.
    nonisolated(unsafe) var isActive = false
    /// Target gain (volume × boost × the device's software gain, as given by the engine).
    nonisolated(unsafe) var volume: Float = 1
    nonisolated(unsafe) var isMuted = false
    /// Zeroes the slot's output at once (a device switch that cannot crossfade).
    nonisolated(unsafe) var forceSilence = false
    /// 1 = playing, 0 = faded out. The audio thread ramps `fade` toward it (device switches).
    nonisolated(unsafe) var fadeTarget: Float = 1
    nonisolated(unsafe) var eq: EQProcessor?
    nonisolated(unsafe) var loudnessEqualizer: LoudnessEqualizer?
    nonisolated(unsafe) var loudnessCompensator: LoudnessCompensator?
    /// Bumped by every activation, so a stale deferred action can tell it is stale.
    private(set) var generation = 0
    /// The chain's settings as last given, to rebuild it at another sample rate.
    private(set) var settings = Settings()

    // MARK: Audio thread

    nonisolated(unsafe) var currentVolume: Float = 1
    nonisolated(unsafe) var fade: Float = 1
    nonisolated(unsafe) var gatePhase: UInt8 = 0
    nonisolated(unsafe) var gateProgress: Float = 0
    nonisolated(unsafe) var gateWasMuted = false
    /// Smoothed peak of the app's input, for the VU meter.
    nonisolated(unsafe) var peakLevel: Float = 0
    /// Host time of the last buffer whose input carried audio (0 = none since activation).
    nonisolated(unsafe) var lastAudibleHostTime: UInt64 = 0
    /// Host time of the last buffer the renderer gave this slot (0 = none since activation).
    nonisolated(unsafe) var lastRenderHostTime: UInt64 = 0

    /// The app's processed buffer, stereo interleaved. Audio thread only.
    private let scratch: UnsafeMutablePointer<Float>
    /// One-buffer lists through which the tap's buffer and the scratch reach the chain.
    private let inputList: UnsafeMutableAudioBufferListPointer
    private let outputList: UnsafeMutableAudioBufferListPointer

    init(index: Int, maxFrames: Int) {
        self.index = index
        self.maxFrames = maxFrames
        scratch = .allocate(capacity: maxFrames * 2)
        scratch.initialize(repeating: 0, count: maxFrames * 2)
        inputList = AudioBufferList.allocate(maximumBuffers: 1)
        outputList = AudioBufferList.allocate(maximumBuffers: 1)
    }

    deinit {
        scratch.deallocate()
        free(inputList.unsafeMutablePointer)
        free(outputList.unsafeMutablePointer)
    }

    // MARK: - Main thread

    /// Gives the slot to an app. The slot must be inactive. `fadedIn: false` starts it faded
    /// out (the receiving side of a device switch), to be faded in with `fadeTarget`.
    func activate(settings: Settings, sampleRate: Double, fadedIn: Bool = true) {
        precondition(!isActive, "DeviceMixSlot \(index) activated twice")
        generation += 1
        self.settings = settings
        Self.retire(eq)
        Self.retire(loudnessEqualizer)
        Self.retire(loudnessCompensator)

        let newEQ = EQProcessor(sampleRate: sampleRate)
        newEQ.updateSettings(settings.eqSettings)
        let newCompensator = LoudnessCompensator(sampleRate: sampleRate)
        newCompensator.setEnabled(settings.loudnessCompensationEnabled)
        if settings.loudnessCompensationEnabled {
            newCompensator.updateForVolume(settings.loudnessVolume)
        }
        eq = newEQ
        loudnessCompensator = newCompensator
        loudnessEqualizer = LoudnessEqualizer(settings: settings.loudnessEqualizerSettings, sampleRate: Float(sampleRate))

        volume = settings.volume
        currentVolume = settings.volume
        isMuted = settings.isMuted
        forceSilence = false
        fade = fadedIn ? 1 : 0
        fadeTarget = fade
        // Armed: the first audio fades in (40 ms), as a new tap does. A slot that is faded in
        // by a device switch skips the gate, like ProcessTapController's secondary tap.
        gatePhase = fadedIn ? 0 : 2
        gateProgress = 0
        gateWasMuted = settings.isMuted
        peakLevel = 0
        lastAudibleHostTime = 0
        lastRenderHostTime = 0

        OSMemoryBarrier()
        isActive = true
    }

    /// Takes the slot back. The renderer stops mixing it from its next buffer.
    func deactivate() {
        isActive = false
        OSMemoryBarrier()
        peakLevel = 0
    }

    /// Rebuilds the chain for a new sample rate, keeping its settings and fade.
    func rebuild(sampleRate: Double) {
        guard isActive else { return }
        var current = settings
        current.volume = volume
        current.isMuted = isMuted
        let fadedIn = fadeTarget >= 1
        deactivate()
        // A faded-in app restarts through the soft-start gate, after the rebuild's silence
        activate(settings: current, sampleRate: sampleRate, fadedIn: fadedIn)
    }

    func updateEQSettings(_ settings: EQSettings) {
        self.settings.eqSettings = settings
        eq?.updateSettings(settings)
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        settings.loudnessCompensationEnabled = enabled
        settings.loudnessVolume = volume
        guard let loudnessCompensator else { return }
        if enabled {
            loudnessCompensator.updateForVolume(volume)
        } else {
            loudnessCompensator.setEnabled(false)
        }
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings, sampleRate: Double) {
        self.settings.loudnessEqualizerSettings = settings
        let old = loudnessEqualizer
        loudnessEqualizer = LoudnessEqualizer(settings: settings, sampleRate: Float(sampleRate))
        Self.retire(old)
    }

    /// Keeps replaced processors alive while the audio thread may still be using them.
    static func retire<T: AnyObject & Sendable>(_ object: T?) {
        guard let object else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { _ = object }
    }

    // MARK: - Audio thread (RT-safe: no allocation, locks, logging or ObjC)

    /// Runs the app's chain on `input`, its tap's buffer, and adds the result to `mix` (stereo
    /// interleaved, `frames` frames). Returns false when the slot added nothing.
    @inline(__always)
    func render(
        input: AudioBuffer,
        frames: Int,
        into mix: UnsafeMutablePointer<Float>,
        rampCoefficient: Float,
        gateRampSamples: Float,
        fadeStep: Float,
        resumed: Bool,
        hostTime: UInt64
    ) -> Bool {
        lastRenderHostTime = hostTime
        guard frames > 0, frames <= maxFrames, let inputData = input.mData else { return false }
        let channels = max(1, Int(input.mNumberChannels))
        let sampleCount = min(Int(input.mDataByteSize) / MemoryLayout<Float>.size, frames * channels)
        guard sampleCount > 0 else { return false }

        // Meter every channel (hard-panned audio must not look silent, #429)
        let samples = inputData.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(sampleCount))
        peak = min(peak, 1)
        peakLevel += Self.levelSmoothing * (peak - peakLevel)
        if peak > Self.silenceThreshold { lastAudibleHostTime = hostTime }

        // Soft-start gate, re-armed on a resume (IO gap) or an unmute, as in ProcessTapController
        let muted = isMuted
        var phase = gatePhase
        var progress = gateProgress
        if resumed || (gateWasMuted && !muted) {
            phase = 0
            progress = 0
        }
        gateWasMuted = muted
        let gate = ProcessTapController.advanceOutputGate(
            phase: &phase, progress: &progress, maxPeak: muted ? 0 : peak,
            frameCount: frames, rampSamples: gateRampSamples
        )
        gatePhase = phase
        gateProgress = progress

        guard !muted, !forceSilence else { return false }

        inputList[0] = input
        outputList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(scratch)
        )
        var vol = currentVolume
        ProcessTapController.processMappedBuffers(
            inputBuffers: inputList,
            outputBuffers: outputList,
            targetVol: volume,
            crossfadeMultiplier: 1,
            outputGateMultiplier: gate,
            rampCoefficient: rampCoefficient,
            preferredStereoLeft: 0,
            preferredStereoRight: 1,
            currentVol: &vol,
            eqProc: eq,
            autoEQProc: nil,
            loudnessEqualizerProc: loudnessEqualizer,
            loudnessCompensatorProc: loudnessCompensator
        )
        currentVolume = vol

        // Add to the mix, through the device-switch fade
        let target = fadeTarget
        var level = fade
        let count = frames * 2
        if level == target {
            if level <= 0 { return false }
            if level >= 1 {
                vDSP_vadd(scratch, 1, mix, 1, mix, 1, vDSP_Length(count))
            } else {
                vDSP_vsma(scratch, 1, &level, mix, 1, mix, 1, vDSP_Length(count))
            }
            return true
        }
        let step = max(fadeStep, 1e-6)
        for frame in 0..<frames {
            if level < target {
                level = min(target, level + step)
            } else if level > target {
                level = max(target, level - step)
            }
            let base = frame * 2
            mix[base] += scratch[base] * level
            mix[base + 1] += scratch[base + 1] * level
        }
        fade = level
        return true
    }
}

/// The device half of the per-DAC mix: sums the slots, then runs AutoEQ and the limiter once.
enum DeviceMixRenderer {

    /// Renders the device's output from the aggregate's input buffers.
    ///
    /// The slots' taps are the trailing `slots.count` input buffers, in slot order (any earlier
    /// ones are the device's own hardware inputs). The mix is written to the first output
    /// buffer, on the preferred stereo channels; every other output channel is zeroed.
    ///
    /// - Returns: the number of slots that added audio.
    @discardableResult
    static func render(
        inputs: UnsafeMutableAudioBufferListPointer,
        outputs: UnsafeMutableAudioBufferListPointer,
        slots: [DeviceMixSlot],
        mix: UnsafeMutablePointer<Float>,
        maxFrames: Int,
        autoEQ: AutoEQProcessor?,
        forceSilence: Bool,
        preferredLeft: Int,
        preferredRight: Int,
        rampCoefficient: Float,
        gateRampSamples: Float,
        fadeStep: Float,
        resumed: Bool,
        hostTime: UInt64
    ) -> Int {
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard outputs.count > 0 else { return 0 }
        let output = outputs[0]
        guard let outData = output.mData else { return 0 }
        let outChannels = max(1, Int(output.mNumberChannels))
        let frames = Int(output.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
        guard frames > 0, frames <= maxFrames else { return 0 }

        memset(mix, 0, frames * 2 * MemoryLayout<Float>.size)
        let firstTap = inputs.count - slots.count
        var mixed = 0
        if firstTap >= 0 {
            for index in 0..<slots.count {
                let slot = slots[index]
                guard slot.isActive else { continue }
                if slot.render(
                    input: inputs[firstTap + index], frames: frames, into: mix,
                    rampCoefficient: rampCoefficient, gateRampSamples: gateRampSamples,
                    fadeStep: fadeStep, resumed: resumed, hostTime: hostTime
                ) {
                    mixed += 1
                }
            }
        }
        guard mixed > 0, !forceSilence else { return 0 }

        // The device's correction, once for every app
        let corrected = autoEQ?.isEnabled ?? false
        if let autoEQ, corrected {
            autoEQ.process(input: mix, output: mix, frameCount: frames)
        }
        // One app through a neutral chain stays bit-transparent; a sum or a correction can
        // go above unity
        if corrected || mixed > 1 {
            SoftLimiter.processBuffer(mix, sampleCount: frames * 2)
        }

        let out = outData.assumingMemoryBound(to: Float.self)
        if outChannels == 1 {
            for frame in 0..<frames {
                out[frame] = 0.5 * (mix[frame * 2] + mix[frame * 2 + 1])
            }
            return mixed
        }
        let left = min(max(preferredLeft, 0), outChannels - 1)
        let right = min(max(preferredRight, 0), outChannels - 1)
        if outChannels == 2 && left == 0 && right == 1 {
            memcpy(out, mix, frames * 2 * MemoryLayout<Float>.size)
            return mixed
        }
        for frame in 0..<frames {
            let base = frame * outChannels
            out[base + left] += mix[frame * 2]
            out[base + right] += mix[frame * 2 + 1]
        }
        return mixed
    }
}
