// FineTune/Audio/EQ/FIR/FIRKernelCache.swift
import Foundation

/// Designs the FIR kernel of a preset, remembering the last few.
///
/// One preset is usually applied several times in a row with the same result: once per tap
/// playing on the device, again for the second tap of a device switch, and by the EQ Manager
/// to show the latency. The design takes a few milliseconds, so the last results are kept.
/// Main thread only.
enum FIRKernelCache {
    private struct Entry {
        let kind: AutoEQPresetKind
        let filters: [AutoEQFilter]
        let curve: [AutoEQCurvePoint]
        let engine: AutoEQCorrectionEngine
        let baseRate: Double
        let sampleRate: Double
        /// Linear-phase tolerance, 0 for minimum phase.
        let toleranceDB: Double
        let kernel: FIRDesign.Kernel
    }

    private static let capacity = 6
    private nonisolated(unsafe) static var entries: [Entry] = []

    /// The kernel of `profile`'s curve for its FIR engine at `sampleRate`, or nil when the
    /// preset has no curve, does not use a FIR engine, or the design fails.
    static func kernel(for profile: AutoEQProfile, sampleRate: Double) -> FIRDesign.Kernel? {
        dispatchPrecondition(condition: .onQueue(.main))
        let engine = profile.effectiveEngine
        guard engine.isFIR, profile.hasCorrection, sampleRate > 0 else { return nil }
        let toleranceDB = engine == .linearPhaseFIR ? profile.effectiveLinearPhaseToleranceDB : 0

        if let index = entries.firstIndex(where: {
            $0.sampleRate == sampleRate && $0.engine == engine && $0.kind == profile.kind
                && $0.filters == profile.filters && $0.curve == profile.curve
                && $0.baseRate == profile.optimizedSampleRate && $0.toleranceDB == toleranceDB
        }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.kernel
        }

        let size = FIRDesign.gridSize(sampleRate: sampleRate)
        let target = AutoEQResponse.designGrid(of: profile, sampleRate: sampleRate, gridSize: size)
        let designed = engine == .linearPhaseFIR
            ? FIRDesign.linearPhase(targetDB: target, sampleRate: sampleRate, toleranceDB: toleranceDB)
            : FIRDesign.minimumPhase(targetDB: target, sampleRate: sampleRate)
        guard let kernel = designed else { return nil }

        entries.append(Entry(kind: profile.kind, filters: profile.filters, curve: profile.curve,
                             engine: engine, baseRate: profile.optimizedSampleRate,
                             sampleRate: sampleRate, toleranceDB: toleranceDB, kernel: kernel))
        if entries.count > capacity { entries.removeFirst() }
        return kernel
    }

    /// Latency the preset's engine adds, in milliseconds (0 for every engine but linear-phase FIR).
    static func latencyMilliseconds(of profile: AutoEQProfile, sampleRate: Double) -> Double {
        linearPhaseSummary(of: profile, sampleRate: sampleRate)?.latencyMS ?? 0
    }

    /// Latency and accuracy of the preset's linear-phase filter, for the EQ Manager. Nil when the
    /// preset does not use that engine or has no curve.
    static func linearPhaseSummary(
        of profile: AutoEQProfile, sampleRate: Double
    ) -> (latencyMS: Double, maxErrorDB: Double)? {
        guard profile.effectiveEngine == .linearPhaseFIR,
              let kernel = kernel(for: profile, sampleRate: sampleRate) else { return nil }
        return (Double(kernel.latencySamples) / sampleRate * 1000, kernel.maxErrorDB)
    }
}
