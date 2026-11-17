// FineTune/Audio/AutoEQ/AutoEQProcessor.swift
import Foundation
import Accelerate
import Darwin.C  // OSMemoryBarrier

/// RT-safe processor for AutoEQ headphone correction: a preamp, then the preset's curve
/// rendered by the engine the preset chose.
///
/// - `.biquad` and `.matchedBiquad`: the biquad cascade inherited from `BiquadProcessor`
///   (delay buffers, atomic setup swaps, NaN safety), with cookbook or exact-fitted coefficients.
/// - `.minimumPhaseFIR` and `.linearPhaseFIR`: a FIR filter designed from the exact curve
///   (`FIRDesign`), run by `FIRProcessor`, which also crossfades between filters.
///
/// Only one of the two paths carries the curve at a time; the other is idle.
///
/// ## Switching
/// Switching the correction on or off, changing the preamp and the curve together, or moving
/// between the cascade and the FIR path happens on one sample: the main thread writes the
/// settings between two bumps of `_seq`, and the audio thread takes a consistent copy of them
/// at the start of each buffer (the previous buffer's while a write is in progress). A FIR
/// filter is then swapped without a crossfade. This clicks, but no sample is played with the
/// new preamp and the old curve, or the other way round, which could be louder than both
/// settings. A curve edited in place (same preamp, same path) is still crossfaded by the FIR
/// path; a preamp change alone is a single value.
final class AutoEQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Currently applied profile (needed for sample rate recalculation)
    private var _currentProfile: AutoEQProfile?

    /// Read-only access to current profile
    var currentProfile: AutoEQProfile? { _currentProfile }

    /// Whether to apply the profile's preamp (false = bypass preamp, rely on limiter)
    private var _preampEnabled: Bool = true

    // MARK: - Shared State (written by the main thread)

    /// Preamp gain in linear scale.
    private nonisolated(unsafe) var _preampGain: Float = 1.0

    /// Number of active filter sections (diagnostic)
    private nonisolated(unsafe) var _filterCount: UInt = 0

    /// Whether the biquad cascade carries the curve. False when the curve is rendered by the
    /// FIR path, or when there is no curve (correction switched off, empty preset).
    private nonisolated(unsafe) var _cascadeActive: Bool = false

    /// Bumped each time the cascade starts again, so the audio thread clears its delay buffers.
    private nonisolated(unsafe) var _cascadeStarts: UInt32 = 0

    /// Odd while the main thread writes settings that must change together.
    private nonisolated(unsafe) var _seq: UInt32 = 0

    // MARK: - Audio-Thread State

    /// The settings the audio thread plays, read together.
    private struct Snapshot {
        var gain: Float = 1
        var cascadeActive = false
        var setup: vDSP_biquad_Setup?
        var cascadeStarts: UInt32 = 0
        var fir = FIRProcessor.State()
    }

    /// The settings of the previous buffer, played again while the main thread writes.
    private nonisolated(unsafe) var lastSnapshot = Snapshot()
    /// The last `_cascadeStarts` the delay buffers were cleared for.
    private nonisolated(unsafe) var handledCascadeStarts: UInt32 = 0

    // MARK: - Main-Thread State

    /// The FIR path. Empty (a no-op) unless the preset uses a FIR engine.
    private let fir = FIRProcessor()

    /// Latency the current correction adds, in samples (linear-phase FIR only). Main thread.
    var latencySamples: Int { fir.latencySamples }

    /// Set while a filter designed for another sample rate is replaced: it is dropped at once
    /// instead of being faded out, as it no longer plays the right curve.
    private var replacingStaleFilter = false

    /// Bumped by every profile update, so a pending retry of an older one is dropped.
    private var updateGeneration = 0

    /// The validated profile whose curve plays (nil once switched off), to tell a change of
    /// preamp alone from a change of curve.
    private var playedProfile: AutoEQProfile?

    /// Wait before trying again a switch that found a crossfade in progress.
    private static let retryInterval: DispatchTimeInterval = .milliseconds(15)
    /// Tries before concluding that the audio thread is not running (about 300 ms).
    private static let maxRetries = 20

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: AutoEQProfile.maxFilters,
            category: "AutoEQProcessor"
        )
    }

    // MARK: - Profile Update

    /// What carries the curve.
    private enum Curve {
        case none
        case fir(FIRConvolver)
        case cascade(vDSP_biquad_Setup, sections: Int)
    }

    /// Update the correction profile (call from main thread).
    /// Pass `nil` to disable correction.
    func updateProfile(_ profile: AutoEQProfile?) {
        dispatchPrecondition(condition: .onQueue(.main))
        update(profile, attempt: 0)
    }

    private func update(_ profile: AutoEQProfile?, attempt: Int) {
        _currentProfile = profile
        updateGeneration += 1
        // `process` is not called while the processor is disabled: everything can then be
        // changed directly, with nothing to crossfade from
        let wasIdle = !isEnabled || replacingStaleFilter || attempt >= Self.maxRetries

        let validated = profile?.validated()
        let preampLinear = validated.map { _preampEnabled ? powf(10.0, $0.preampDB / 20.0) : 1.0 } ?? 1.0
        let preampStatus = self._preampEnabled ? "active" : "bypassed"

        // Nothing left to play: back to the input, then off
        guard let validated, validated.hasCorrection || preampLinear != 1.0 else {
            guard wasIdle || !fir.hasFilter || fir.canSwapAtOnce else {
                retry(profile, attempt: attempt)
                return
            }
            if wasIdle {
                write(gain: 1.0, curve: Curve.none, idle: true)
            } else {
                writeTogether(gain: 1.0, curve: Curve.none)
            }
            setEnabled(false)
            playedProfile = nil
            logger.info("AutoEQ disabled — \(validated == nil ? "nil profile" : "unity preamp, no curve")")
            return
        }

        // The same curve with another preamp (Preamp switch, preamp edited): one value
        if !wasIdle, let played = playedProfile, Self.sameCurve(played, validated) {
            _preampGain = preampLinear
            playedProfile = validated
            logger.info("AutoEQ preamp: \"\(validated.name)\" — \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus))")
            return
        }

        guard let curve = makeCurve(for: validated) else { return }

        // Only a curve edited in place (same preamp, same path) is crossfaded. Switching the
        // correction on or off, or changing both the preamp and the curve, happens at once.
        var isCascade = false
        if case .cascade = curve { isCascade = true }
        let editsCurve = preampLinear == _preampGain && validated.hasCorrection
            && (playedProfile?.hasCorrection ?? false) && isCascade == _cascadeActive
        if wasIdle {
            write(gain: preampLinear, curve: curve, idle: true)
        } else if editsCurve {
            write(gain: preampLinear, curve: curve, idle: false)
        } else {
            guard fir.canSwapAtOnce else {
                if case .cascade(let setup, _) = curve { vDSP_biquad_DestroySetup(setup) }
                retry(profile, attempt: attempt)
                return
            }
            writeTogether(gain: preampLinear, curve: curve)
        }
        setEnabled(true)
        playedProfile = validated

        switch curve {
        case .none:
            logger.info("AutoEQ preamp only: \"\(validated.name)\" — preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus))")
        case .fir(let convolver):
            logger.info("AutoEQ applied: \"\(validated.name)\" — \(validated.effectiveEngine.displayName), latency \(convolver.latencySamples) samples, preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus)), rate \(self.sampleRate, format: .fixed(precision: 0)) Hz")
        case .cascade(_, let sections):
            logger.info("AutoEQ applied: \"\(validated.name)\" — \(validated.effectiveEngine.displayName), \(sections) filters, preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus)), gain \(preampLinear, format: .fixed(precision: 3))x, rate \(self.sampleRate, format: .fixed(precision: 0)) Hz")
        }
    }

    /// Tries the update again once the crossfade in progress has ended.
    private func retry(_ profile: AutoEQProfile?, attempt: Int) {
        let generation = updateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            guard let self, self.updateGeneration == generation else { return }
            self.update(profile, attempt: attempt + 1)
        }
    }

    /// Whether two validated profiles play the same curve (preamp aside).
    private static func sameCurve(_ a: AutoEQProfile, _ b: AutoEQProfile) -> Bool {
        guard a.hasCorrection, b.hasCorrection else { return a.hasCorrection == b.hasCorrection }
        return a.kind == b.kind
            && a.effectiveEngine == b.effectiveEngine
            && a.filters == b.filters
            && a.curve == b.curve
            && a.optimizedSampleRate == b.optimizedSampleRate
            && a.effectiveLinearPhaseToleranceDB == b.effectiveLinearPhaseToleranceDB
    }

    /// The curve of a validated profile, or nil when it cannot be made (the previous
    /// correction then stays, so working audio is not broken).
    private func makeCurve(for validated: AutoEQProfile) -> Curve? {
        guard validated.hasCorrection else { return Curve.none }
        let engine = validated.effectiveEngine
        if engine.isFIR {
            guard let kernel = FIRKernelCache.kernel(for: validated, sampleRate: sampleRate),
                  let convolver = FIRConvolver(taps: kernel.taps, latencySamples: kernel.latencySamples) else {
                logger.warning("FIR design failed for \"\(validated.name)\" — skipping profile update")
                return nil
            }
            return .fir(convolver)
        }
        let filters = validated.filters
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: sampleRate,
            profileOptimizedRate: validated.optimizedSampleRate,
            exact: engine == .matchedBiquad
        )
        guard let setup = coefficients.withUnsafeBufferPointer({ ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(filters.count))
        }) else {
            logger.warning("vDSP_biquad_CreateSetup returned nil for \(filters.count) filters — skipping profile update")
            return nil
        }
        return .cascade(setup, sections: filters.count)
    }

    /// Writes the preamp and the curve. The FIR path crossfades unless `idle`.
    private func write(gain: Float, curve: Curve, idle: Bool) {
        beginWrite()
        _preampGain = gain
        switch curve {
        case .none:
            _filterCount = 0
            _cascadeActive = false
            fir.install(nil, sampleRate: sampleRate, audioThreadIdle: idle)
        case .fir(let convolver):
            _filterCount = 0
            _cascadeActive = false
            fir.install(convolver, sampleRate: sampleRate, audioThreadIdle: idle)
        case .cascade(let setup, let sections):
            setCascade(setup, sections: sections)
            fir.install(nil, sampleRate: sampleRate, audioThreadIdle: idle)
        }
        endWrite()
    }

    /// Writes the preamp and the curve so that the audio thread plays both from the same
    /// sample, swapping a FIR filter without a crossfade. Requires `fir.canSwapAtOnce`.
    private func writeTogether(gain: Float, curve: Curve) {
        beginWrite()
        _preampGain = gain
        switch curve {
        case .none:
            _filterCount = 0
            _cascadeActive = false
            if fir.hasFilter { fir.swapAtOnce(nil, sampleRate: sampleRate) }
        case .fir(let convolver):
            _filterCount = 0
            _cascadeActive = false
            fir.swapAtOnce(convolver, sampleRate: sampleRate)
        case .cascade(let setup, let sections):
            setCascade(setup, sections: sections)
            if fir.hasFilter { fir.swapAtOnce(nil, sampleRate: sampleRate) }
        }
        endWrite()
    }

    private func setCascade(_ setup: vDSP_biquad_Setup, sections: Int) {
        _filterCount = UInt(sections)
        swapSetup(setup)
        if !_cascadeActive {
            // Its delay buffers hold audio from when it last played
            _cascadeStarts &+= 1
            _cascadeActive = true
        }
    }

    private func beginWrite() {
        _seq &+= 1
        OSMemoryBarrier()
    }

    private func endWrite() {
        OSMemoryBarrier()
        _seq &+= 1
    }

    // MARK: - Preamp Mode

    /// Toggle profile preamp on/off. When off, relies on downstream limiter for peak control.
    func setPreampEnabled(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled != _preampEnabled else { return }
        _preampEnabled = enabled
        logger.info("AutoEQ preamp \(enabled ? "enabled" : "bypassed (limiter-only)")")
        // Re-apply current profile to update the preamp gain atomically
        if let profile = _currentProfile {
            updateProfile(profile)
        }
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        guard let profile = _currentProfile?.validated(), profile.hasCorrection,
              !profile.effectiveEngine.isFIR, !profile.filters.isEmpty else { return nil }
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            profile.filters, sampleRate: sampleRate,
            profileOptimizedRate: profile.optimizedSampleRate,
            exact: profile.effectiveEngine == .matchedBiquad
        )
        return (coefficients, profile.filters.count)
    }

    /// A FIR filter is designed for one sample rate: redesign it at the new one.
    override func updateSampleRate(_ newRate: Double) {
        let changed = newRate != sampleRate
        super.updateSampleRate(newRate)
        if changed, let profile = _currentProfile, profile.effectiveEngine.isFIR, profile.hasCorrection {
            replacingStaleFilter = true
            updateProfile(profile)
            replacingStaleFilter = false
        }
    }

    // MARK: - Audio Processing (RT-safe)

    /// The settings to play this buffer: a consistent copy, or the previous buffer's while
    /// the main thread is writing. RT-safe.
    @inline(__always)
    private func readSnapshot() -> Snapshot {
        for _ in 0..<3 {
            let before = _seq
            OSMemoryBarrier()
            let snapshot = Snapshot(
                gain: _preampGain,
                cascadeActive: _cascadeActive,
                setup: cascadeSetup,
                cascadeStarts: _cascadeStarts,
                fir: fir.state
            )
            OSMemoryBarrier()
            if before & 1 == 0 && _seq == before {
                lastSnapshot = snapshot
                return snapshot
            }
        }
        return lastSnapshot
    }

    /// Preamp, then the curve: the biquad cascade or the FIR path. RT-safe.
    override func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }
        guard isEnabled else { return }

        let snapshot = readSnapshot()
        if snapshot.gain != 1 {
            var preamp = snapshot.gain
            vDSP_vsmul(output, 1, &preamp, output, 1, vDSP_Length(frameCount * 2))
        }
        if snapshot.cascadeActive, let setup = snapshot.setup {
            if snapshot.cascadeStarts != handledCascadeStarts {
                handledCascadeStarts = snapshot.cascadeStarts
                clearCascadeState()
            }
            runCascade(output, frameCount: frameCount, setup: setup)
        }
        // A no-op without a FIR filter; also finishes the crossfade when one is removed
        fir.process(output, frameCount: frameCount, state: snapshot.fir)
    }
}
