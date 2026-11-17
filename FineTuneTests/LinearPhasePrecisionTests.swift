// FineTuneTests/LinearPhasePrecisionTests.swift
//
// The precision of a linear-phase FIR preset: how closely its filter follows the curve, which
// sets the latency. Stored per preset, used by the design and its cache.

import Testing
import Foundation
@testable import FineTune

/// Bass shelf, broad dip, narrow peak and dip, treble shelf: a curve that needs some length.
private func linearProfile(tolerance: Double? = nil) -> AutoEQProfile {
    AutoEQProfile(
        id: "precision", name: "Precision", source: .created, preampDB: -6,
        filters: [
            AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: 5.5, q: 0.7),
            AutoEQFilter(type: .peaking, frequency: 200, gainDB: -2.5, q: 0.5),
            AutoEQFilter(type: .peaking, frequency: 3200, gainDB: 3, q: 2),
            AutoEQFilter(type: .peaking, frequency: 6000, gainDB: -4, q: 4),
            AutoEQFilter(type: .highShelf, frequency: 10_000, gainDB: 2, q: 0.7),
        ],
        engine: .linearPhaseFIR,
        linearPhaseToleranceDB: tolerance)
}

private func target(_ profile: AutoEQProfile, sampleRate: Double = 48_000) -> [Double] {
    AutoEQResponse.designGrid(
        of: profile, sampleRate: sampleRate, gridSize: FIRDesign.gridSize(sampleRate: sampleRate))
}

@Suite("Linear-phase precision")
struct LinearPhasePrecisionTests {

    @Test("The default tolerance is the one earlier builds used")
    func defaultTolerance() throws {
        #expect(FIRDesign.linearPhaseToleranceDB == 0.5)
        #expect(linearProfile().effectiveLinearPhaseToleranceDB == 0.5)
        let grid = target(linearProfile())
        let implicit = try #require(FIRDesign.linearPhase(targetDB: grid, sampleRate: 48_000))
        let explicit = try #require(FIRDesign.linearPhase(targetDB: grid, sampleRate: 48_000, toleranceDB: 0.5))
        #expect(implicit == explicit)
    }

    @Test("A tighter precision never gives a shorter filter")
    func tighterIsLonger() throws {
        let grid = target(linearProfile())
        var previousLatency = Int.max
        for tolerance in AutoEQLinearPhasePrecision.choices {
            let kernel = try #require(FIRDesign.linearPhase(targetDB: grid, sampleRate: 48_000, toleranceDB: tolerance))
            #expect(kernel.latencySamples <= previousLatency, "at ±\(tolerance) dB")
            previousLatency = kernel.latencySamples
        }
        let tight = try #require(FIRDesign.linearPhase(targetDB: grid, sampleRate: 48_000, toleranceDB: 0.05))
        let loose = try #require(FIRDesign.linearPhase(targetDB: grid, sampleRate: 48_000, toleranceDB: 1.0))
        #expect(tight.latencySamples > loose.latencySamples)
        #expect(tight.maxErrorDB < loose.maxErrorDB)
    }

    @Test("A reached tolerance holds above 100 Hz")
    func toleranceHolds() throws {
        let profile = linearProfile(tolerance: 0.1)
        let kernel = try #require(FIRDesign.linearPhase(targetDB: target(profile), sampleRate: 48_000, toleranceDB: 0.1))
        let longest = FIRDesign.linearPhaseHalfLengths(sampleRate: 48_000).last!
        guard kernel.latencySamples < longest else { return }
        for frequency in [150.0, 400, 1000, 3200, 6000, 10_000, 15_000] {
            let gain = FIRDesign.responseDB(of: kernel.taps, at: frequency, sampleRate: 48_000)
            let exact = AutoEQResponse.exactCurve(of: profile, frequencies: [frequency])[0]
            // The design grid and the exact curve differ by a few hundredths of a dB at most
            #expect(abs(gain - exact) <= 0.12, "at \(frequency) Hz")
        }
    }

    @Test("A tolerance of zero is refused")
    func zeroTolerance() {
        #expect(FIRDesign.linearPhase(targetDB: target(linearProfile()), sampleRate: 48_000, toleranceDB: 0) == nil)
    }

    @Test("The cache designs one kernel per precision")
    func cacheKeysOnPrecision() throws {
        let standard = try #require(FIRKernelCache.kernel(for: linearProfile(), sampleRate: 48_000))
        let tight = try #require(FIRKernelCache.kernel(for: linearProfile(tolerance: 0.05), sampleRate: 48_000))
        #expect(tight.latencySamples > standard.latencySamples)
        #expect(FIRKernelCache.kernel(for: linearProfile(), sampleRate: 48_000) == standard)

        let summary = try #require(FIRKernelCache.linearPhaseSummary(of: linearProfile(tolerance: 0.05), sampleRate: 48_000))
        #expect(abs(summary.latencyMS - Double(tight.latencySamples) / 48) < 1e-9)
        #expect(summary.maxErrorDB == tight.maxErrorDB)
    }

    @Test("Minimum phase ignores the precision")
    func minimumPhaseIgnoresIt() throws {
        var profile = linearProfile(tolerance: 0.05)
        profile.engine = .minimumPhaseFIR
        var standard = linearProfile()
        standard.engine = .minimumPhaseFIR
        #expect(FIRKernelCache.kernel(for: profile, sampleRate: 48_000) == FIRKernelCache.kernel(for: standard, sampleRate: 48_000))
        #expect(FIRKernelCache.linearPhaseSummary(of: profile, sampleRate: 48_000) == nil)
    }

    @Test("Only the offered values are stored, the standard one as nil")
    func stored() {
        #expect(AutoEQLinearPhasePrecision.stored(0.1) == 0.1)
        #expect(AutoEQLinearPhasePrecision.stored(0.5) == nil)
        #expect(AutoEQLinearPhasePrecision.stored(0.3) == nil)
        #expect(AutoEQLinearPhasePrecision.stored(nil) == nil)
        #expect(linearProfile(tolerance: 0.25).validated().linearPhaseToleranceDB == 0.25)
        #expect(linearProfile(tolerance: -1).validated().linearPhaseToleranceDB == nil)
        #expect(AutoEQLinearPhasePrecision.label(0.5) == "±0.5 dB (Standard)")
        #expect(AutoEQLinearPhasePrecision.label(0.05) == "±0.05 dB")
    }

    @Test("Stored with the preset; presets of earlier builds keep the standard precision")
    func coding() throws {
        let data = try JSONEncoder().encode(linearProfile(tolerance: 0.1))
        #expect(try JSONDecoder().decode(AutoEQProfile.self, from: data).linearPhaseToleranceDB == 0.1)

        let standardData = try JSONEncoder().encode(linearProfile())
        #expect(!String(decoding: standardData, as: UTF8.self).contains("linearPhaseToleranceDB"))

        let legacy = Data(#"{"id":"a","name":"A","source":"imported","preampDB":0,"filters":[],"engine":"linearPhaseFIR"}"#.utf8)
        let decoded = try JSONDecoder().decode(AutoEQProfile.self, from: legacy)
        #expect(decoded.linearPhaseToleranceDB == nil)
        #expect(decoded.effectiveLinearPhaseToleranceDB == 0.5)
    }

    @Test("A setting, not part of the correction: a template saves it in place")
    func templateSavesInPlace() {
        let template = AutoEQProfile(
            id: "t", name: "T", source: .imported, preampDB: -6, filters: linearProfile().filters,
            engine: .linearPhaseFIR)
        var draft = template
        draft.linearPhaseToleranceDB = 0.1
        #expect(draft.hasSameCorrection(as: template))
        #expect(draft != template)
        #expect(AutoEQProfileManager.saveKind(original: template, draft: draft) == .updateInPlace)
    }
}
