// FineTune/Audio/AutoEQ/AutoEQProcessor.swift
import Foundation
import Accelerate

/// RT-safe processor for AutoEQ headphone correction: a preamp, then the preset's curve
/// rendered by the engine the preset chose.
///
/// - `.biquad` and `.matchedBiquad`: the biquad cascade inherited from `BiquadProcessor`
///   (delay buffers, atomic setup swaps, NaN safety), with cookbook or exact-fitted coefficients.
/// - `.minimumPhaseFIR` and `.linearPhaseFIR`: a FIR filter designed from the exact curve
///   (`FIRDesign`), run by `FIRProcessor`, which also crossfades between filters.
///
/// Only one of the two paths carries the curve at a time; the other is idle.
final class AutoEQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Currently applied profile (needed for sample rate recalculation)
    private var _currentProfile: AutoEQProfile?

    /// Read-only access to current profile
    var currentProfile: AutoEQProfile? { _currentProfile }

    /// Whether to apply the profile's preamp (false = bypass preamp, rely on limiter)
    private var _preampEnabled: Bool = true

    /// Preamp gain in linear scale (RT-safe atomic read in process)
    private nonisolated(unsafe) var _preampGain: Float = 1.0

    /// Number of active filter sections (diagnostic)
    private nonisolated(unsafe) var _filterCount: UInt = 0

    /// Whether the biquad cascade carries the curve. False when the curve is rendered by the
    /// FIR path, or when there is no curve (correction switched off, empty preset).
    private nonisolated(unsafe) var _cascadeActive: Bool = false

    /// The FIR path. Empty (a no-op) unless the preset uses a FIR engine.
    private let fir = FIRProcessor()

    /// Latency the current correction adds, in samples (linear-phase FIR only). Main thread.
    var latencySamples: Int { fir.latencySamples }

    /// Set while a filter designed for another sample rate is replaced: it is dropped at once
    /// instead of being faded out, as it no longer plays the right curve.
    private var replacingStaleFilter = false

    /// Bumped by every profile update, so a pending switch-off (`removeFIRAndDisable`) is dropped.
    private var updateGeneration = 0

    /// Time for a FIR filter to fade out, including the wait for a crossfade already running.
    private static let fadeOutSeconds = 0.5

    init(sampleRate: Double) {
        super.init(
            sampleRate: sampleRate,
            maxSections: AutoEQProfile.maxFilters,
            category: "AutoEQProcessor"
        )
    }

    // MARK: - Profile Update

    /// Update the correction profile (call from main thread).
    /// Pass `nil` to disable correction.
    func updateProfile(_ profile: AutoEQProfile?) {
        dispatchPrecondition(condition: .onQueue(.main))
        _currentProfile = profile
        updateGeneration += 1
        // `process` is not called while the processor is disabled: the FIR path can then be
        // changed directly, with nothing to crossfade from
        let wasIdle = !isEnabled || replacingStaleFilter

        let validated = profile?.validated()
        guard let validated else {
            // Disable: atomic writes
            _filterCount = 0
            _preampGain = 1.0
            _cascadeActive = false
            swapSetup(nil)
            removeFIRAndDisable(wasIdle: wasIdle)
            logger.info("AutoEQ disabled — nil profile")
            return
        }

        let preampLinear = _preampEnabled ? powf(10.0, validated.preampDB / 20.0) : 1.0
        let preampStatus = self._preampEnabled ? "active" : "bypassed"

        guard validated.hasCorrection else {
            // Preamp only, so turning the correction off keeps the same level.
            _cascadeActive = false
            _preampGain = preampLinear
            _filterCount = 0
            swapSetup(nil)
            if preampLinear != 1.0 {
                fir.install(nil, sampleRate: sampleRate, audioThreadIdle: wasIdle)
                setEnabled(true)
            } else {
                removeFIRAndDisable(wasIdle: wasIdle)
            }
            logger.info("AutoEQ preamp only: \"\(validated.name)\" — preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus))")
            return
        }

        let engine = validated.effectiveEngine
        if engine.isFIR {
            guard let kernel = FIRKernelCache.kernel(for: validated, sampleRate: sampleRate),
                  let convolver = FIRConvolver(taps: kernel.taps, latencySamples: kernel.latencySamples) else {
                // Keep the previous correction active — don't break working audio
                logger.warning("FIR design failed for \"\(validated.name)\" — skipping profile update")
                return
            }
            _preampGain = preampLinear
            _filterCount = 0
            _cascadeActive = false
            swapSetup(nil)
            fir.install(convolver, sampleRate: sampleRate, audioThreadIdle: wasIdle)
            setEnabled(true)
            logger.info("AutoEQ applied: \"\(validated.name)\" — \(engine.displayName), \(kernel.taps.count) taps, latency \(kernel.latencySamples) samples, max error \(kernel.maxErrorDB, format: .fixed(precision: 2)) dB, preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus)), rate \(self.sampleRate, format: .fixed(precision: 0)) Hz")
            return
        }

        let wasCascadeActive = _cascadeActive
        let filters = validated.filters
        let coefficients = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: sampleRate,
            profileOptimizedRate: validated.optimizedSampleRate,
            exact: engine == .matchedBiquad
        )

        guard let newSetup = coefficients.withUnsafeBufferPointer({ ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(filters.count))
        }) else {
            // Keep the previous profile active — don't break working audio
            logger.warning("vDSP_biquad_CreateSetup returned nil for \(filters.count) filters — skipping profile update")
            return
        }

        // Atomic state update + setup swap
        _preampGain = preampLinear
        _filterCount = UInt(filters.count)
        swapSetup(newSetup)
        // Delay buffers hold stale state from before the cascade was dropped.
        if !wasCascadeActive { resetDelayBuffers() }
        _cascadeActive = true
        fir.install(nil, sampleRate: sampleRate, audioThreadIdle: wasIdle)
        setEnabled(true)

        logger.info("AutoEQ applied: \"\(validated.name)\" — \(engine.displayName), \(filters.count) filters, preamp \(validated.preampDB, format: .fixed(precision: 1)) dB (\(preampStatus)), gain \(preampLinear, format: .fixed(precision: 3))x, rate \(self.sampleRate, format: .fixed(precision: 0)) Hz")

        // Note: Do NOT reset delay buffers here - the filter naturally adapts to new
        // coefficients using existing state, producing smooth transitions without clicks.
    }

    /// Switches the processor off. A FIR filter that is playing is faded out first, as cutting
    /// it would click (and, for a linear-phase filter, jump back in time by its latency).
    private func removeFIRAndDisable(wasIdle: Bool) {
        guard !wasIdle, fir.hasFilter else {
            setEnabled(false)
            fir.install(nil, sampleRate: sampleRate, audioThreadIdle: true)
            return
        }
        fir.install(nil, sampleRate: sampleRate)
        let generation = updateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutSeconds) { [weak self] in
            guard let self, self.updateGeneration == generation else { return }
            self.setEnabled(false)
        }
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

    /// Preamp, then the curve: the biquad cascade (base class) or the FIR path (RT-safe).
    override func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        if _cascadeActive {
            super.process(input: input, output: output, frameCount: frameCount)
        } else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            guard isEnabled else { return }
            preProcess(output: output, frameCount: frameCount)
        }
        // A no-op without a FIR filter; also finishes the crossfade when one is removed
        fir.process(output, frameCount: frameCount)
    }

    /// Apply preamp gain before the curve (RT-safe).
    override func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        var preamp = _preampGain
        let sampleCount = frameCount * 2
        vDSP_vsmul(output, 1, &preamp, output, 1, vDSP_Length(sampleCount))
    }
}
