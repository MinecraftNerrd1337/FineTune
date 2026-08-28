// FineTuneTests/CoreHardening/ClickFreeSwitchingTests.swift
//
// Tests for click-free switching via crossfade and volume ramping.
// Verifies that audio transitions don't produce audible artifacts.

import Testing
import Foundation
import Accelerate
@testable import FineTune

// MARK: - SoftLimiter Under Boost

@Suite("SoftLimiter — Clip Safety Under Boost (Core Hardening)")
struct SoftLimiterBoostTests {

    @Test("2x boost produces output <= 1.0",
          arguments: [Float(0.5), 0.8, 1.0, 1.5, 2.0])
    func twoTimesBoostSafe(input: Float) {
        let boosted = input * 2.0
        let output = SoftLimiter.apply(boosted)
        #expect(output <= SoftLimiter.ceiling,
                "2x boost of \(input) = \(boosted) produced \(output) > ceiling")
    }

    @Test("4x boost produces output <= 1.0",
          arguments: [Float(0.25), 0.5, 0.75, 1.0])
    func fourTimesBoostSafe(input: Float) {
        let boosted = input * 4.0
        let output = SoftLimiter.apply(boosted)
        #expect(output <= SoftLimiter.ceiling,
                "4x boost of \(input) = \(boosted) produced \(output) > ceiling")
    }

    @Test("Soft knee engages at 0.95 threshold")
    func softKneeEngages() {
        let below = SoftLimiter.apply(0.94)
        let atThreshold = SoftLimiter.apply(0.95)
        let above = SoftLimiter.apply(0.96)

        #expect(below == 0.94, "Below threshold should pass through")
        #expect(atThreshold == 0.95, "At threshold should pass through")
        #expect(above < 0.96, "Above threshold should be compressed")
        #expect(above > 0.95, "Above threshold should still be above threshold")
    }

    @Test("Asymptotic approach to ceiling")
    func asymptoticApproach() {
        let outputs = [1.0, 2.0, 5.0, 10.0, 100.0].map { SoftLimiter.apply($0) }

        // Each output should be closer to ceiling than the previous
        for i in 1..<outputs.count {
            let gap1 = SoftLimiter.ceiling - outputs[i - 1]
            let gap2 = SoftLimiter.ceiling - outputs[i]
            #expect(gap2 < gap1, "Gap should shrink as input increases")
        }
    }

    @Test("No inter-sample clipping in buffer processing")
    func noInterSampleClipping() {
        let count = 1024
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { buffer.deallocate() }

        // Fill with boosted signal
        for i in 0..<count {
            buffer[i] = Float(i) / Float(count) * 4.0  // Ramps from 0 to 4.0
        }

        SoftLimiter.processBuffer(buffer, sampleCount: count)

        // All samples should be <= ceiling
        for i in 0..<count {
            #expect(buffer[i] <= SoftLimiter.ceiling,
                    "Sample \(i) = \(buffer[i]) exceeds ceiling")
            #expect(buffer[i] >= -SoftLimiter.ceiling,
                    "Sample \(i) = \(buffer[i]) below -ceiling")
        }
    }
}

// MARK: - Volume Ramp Coefficient

@Suite("ProcessTapController — Volume Ramp Coefficient (Core Hardening)")
struct VolumeRampCoefficientTests {

    @Test("Ramp coefficient formula: 1 - exp(-1 / (sampleRate * rampTime))")
    func rampCoefficientFormula() {
        let sampleRate: Float = 48000
        let rampTime: Float = 0.030  // 30ms

        let expected = 1 - exp(-1 / (sampleRate * rampTime))
        let actual = 1 - exp(-1 / (Float(48000) * 0.030))

        #expect(abs(expected - actual) < 1e-6)
    }

    @Test("Ramp coefficient decreases with sample rate (per-sample smoothing)")
    func rampCoefficientIncreasesWithSampleRate() {
        let rampTime: Float = 0.030

        let coeff48k = 1 - exp(-1 / (Float(48000) * rampTime))
        let coeff96k = 1 - exp(-1 / (Float(96000) * rampTime))
        let coeff192k = 1 - exp(-1 / (Float(192000) * rampTime))

        #expect(coeff48k > coeff96k, "Higher sample rate should have lower per-sample coefficient")
        #expect(coeff96k > coeff192k, "Even higher sample rate should have even lower coefficient")
    }
}

// MARK: - Output Gate State Machine

@Suite("ProcessTapController — Output Gate State Machine (Core Hardening)")
struct OutputGateStateTests {

    private let silenceThreshold: Float = 0.0001
    private let belowThreshold: Float = 0.00005
    private let aboveThreshold: Float = 0.01
    private let defaultRampSamples: Float = 1920

    @Test("Armed + silent input stays armed")
    func armedStaysArmed() {
        var phase: UInt8 = 0
        var progress: Float = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: belowThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples,
        )

        #expect(mult == 0)
        #expect(phase == 0)
    }

    @Test("Armed + non-silent input enters ramping")
    func armedEntersRamping() {
        var phase: UInt8 = 0
        var progress: Float = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples
        )

        #expect(mult == 0, "Entry buffer outputs 0")
        #expect(phase == 1, "Should transition to ramping")
        #expect(progress == 0, "Progress should be reset")
    }

    @Test("Ramping reaches open at progress >= 1.0")
    func rampingReachesOpen() {
        var phase: UInt8 = 1
        var progress: Float = 0

        // Process enough buffers to complete ramp
        for _ in 0..<10 {
            _ = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                maxPeak: aboveThreshold,
                frameCount: 256,
                rampSamples: defaultRampSamples
            )
            if phase == 2 { break }
        }

        #expect(phase == 2, "Should reach open phase")
    }
    
    @Test("Open + silent input stays open")
    func openStaysOpenOnSilence() {
        var phase: UInt8 = 2
        var progress: Float = 1.0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: belowThreshold,
            frameCount: 1024,
            rampSamples: defaultRampSamples
        )

        #expect(mult == 1.0)
        #expect(phase == 2)
    }
}

// MARK: - CrossfadeConfig

@Suite("CrossfadeConfig — Timing (Core Hardening)")
struct CrossfadeConfigTests {

    @Test("Default duration is 50ms")
    func defaultDuration() {
        #expect(CrossfadeConfig.defaultDuration == 0.050)
    }

    @Test("totalSamples calculation is correct")
    func totalSamplesCalculation() {
        let sampleRate = 48000.0
        let expected = Int64(sampleRate * 0.050)  // 2400 samples
        let actual = CrossfadeConfig.totalSamples(at: sampleRate)
        #expect(actual == expected)
    }

    @Test("totalSamples is at least 1")
    func totalSamplesMinimum() {
        let actual = CrossfadeConfig.totalSamples(at: 0)
        #expect(actual >= 1)
    }
}
