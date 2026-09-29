// FineTuneTests/OutputGateTests.swift
//
// Pure-value tests for ProcessTapController.advanceOutputGate. Phase encoding:
// 0 = armed (muted), 1 = ramping (half-cosine fade-in), 2 = open.
//
// Re-arming is intentionally NOT driven by ordinary input silence. The audio
// callback re-arms the gate only on a real IOProc resume gap or an unmute edge.

import Testing
import Foundation
@testable import FineTune

private let silenceThreshold: Float = 0.0001
private let belowThreshold: Float = 0.00005
private let aboveThreshold: Float = 0.01
private let defaultRampSamples: Float = 1920  // 40 ms @ 48 kHz
private let cosineTolerance: Float = 1e-5

@Suite("OutputGate — armed phase (0)")
struct OutputGateArmedTests {
    @Test("Armed + silent input stays armed and muted")
    func armedAndSilentStaysArmed() {
        var phase: UInt8 = 0
        var progress: Float = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: belowThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples
        )

        #expect(mult == 0)
        #expect(phase == 0)
        #expect(progress == 0)
    }

    @Test("Armed + non-silent input enters ramping; entry buffer outputs 0")
    func armedAndNonSilentEntersRamping() {
        var phase: UInt8 = 0
        var progress: Float = 0.5

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples
        )

        #expect(mult == 0)
        #expect(phase == 1)
        #expect(progress == 0)
    }

    @Test("Peak exactly at threshold is still treated as silence")
    func peakEqualToThresholdIsSilent() {
        var phase: UInt8 = 0
        var progress: Float = 0

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: silenceThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples
        )

        #expect(mult == 0)
        #expect(phase == 0)
    }
}

@Suite("OutputGate — ramping phase (1)")
struct OutputGateRampingTests {
    @Test("Progress advances by frameCount/rampSamples per call",
          arguments: [256, 512, 1024])
    func progressAdvancesLinearlyPerCall(frameCount: Int) {
        var phase: UInt8 = 1
        var progress: Float = 0

        let delta = Float(frameCount) / defaultRampSamples
        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples
        )

        #expect(abs(progress - min(1.0, delta)) < 1e-6)
        #expect(phase == (delta >= 1.0 ? 2 : 1))

        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples
        )

        let expectedProgress = min(Float(1.0), 2 * delta)
        #expect(abs(progress - expectedProgress) < 1e-6)
        #expect(phase == (2 * delta >= 1.0 ? 2 : 1))
    }

    @Test("Ramping promotes to open and returns exactly 1 at completion")
    func rampingReachesOpenAtProgressOne() {
        var phase: UInt8 = 1
        var progress: Float = 0
        let frameCount = 256
        let stepsToOpen = Int((defaultRampSamples / Float(frameCount)).rounded(.up))

        var lastRampingOutput: Float = -1
        var openOutput: Float = -1

        for _ in 1...(stepsToOpen + 1) {
            let mult = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                maxPeak: aboveThreshold,
                frameCount: frameCount,
                rampSamples: defaultRampSamples
            )
            if phase == 2 {
                openOutput = mult
                break
            }
            lastRampingOutput = mult
        }

        #expect(lastRampingOutput >= 0 && lastRampingOutput < 1)
        #expect(openOutput == 1)
        #expect(phase == 2)
    }

    @Test("Half-cosine ramp values",
          arguments: [
            (Float(0.0), Float(0.0)),
            (Float(0.25), Float(0.5) * (1 - cos(Float.pi * 0.25))),
            (Float(0.5), Float(0.5)),
            (Float(0.75), Float(0.5) * (1 - cos(Float.pi * 0.75))),
            (Float(1.0), Float(1.0)),
          ])
    func halfCosineRampValues(target: Float, expected: Float) {
        var phase: UInt8 = 1
        var progress = target

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveThreshold,
            frameCount: 0,
            rampSamples: defaultRampSamples
        )

        #expect(abs(mult - expected) < cosineTolerance)
        #expect(phase == (target >= 1 ? 2 : 1))
    }
}

@Suite("OutputGate — open phase (2)")
struct OutputGateOpenTests {
    @Test("Open + non-silent input stays open")
    func openAndNonSilentStaysOpen() {
        var phase: UInt8 = 2
        var progress: Float = 1

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples
        )

        #expect(mult == 1)
        #expect(phase == 2)
        #expect(progress == 1)
    }

    @Test("Open + silent input stays open")
    func openAndSilentStaysOpen() {
        var phase: UInt8 = 2
        var progress: Float = 1

        let mult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: belowThreshold,
            frameCount: 512,
            rampSamples: defaultRampSamples
        )

        #expect(mult == 1)
        #expect(phase == 2)
        #expect(progress == 1)
    }

    @Test("Sustained ordinary silence never re-arms the gate")
    func sustainedSilenceDoesNotRearm() {
        var phase: UInt8 = 2
        var progress: Float = 1

        // More than a second of silence at 48 kHz. The old implementation
        // re-armed after 200 ms; #388 intentionally removes that behavior.
        for _ in 0..<100 {
            let mult = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                maxPeak: belowThreshold,
                frameCount: 512,
                rampSamples: defaultRampSamples
            )
            #expect(mult == 1)
            #expect(phase == 2)
        }
    }
}

@Suite("OutputGate — externally re-armed cycle")
struct OutputGateCycleTests {
    @Test("Resume/unmute re-arm can run a fresh armed → ramping → open cycle")
    func externallyRearmedCycle() {
        var phase: UInt8 = 2
        var progress: Float = 1
        let frameCount = 1024

        // Ordinary silence while IO continues must not re-arm.
        for _ in 0..<20 {
            _ = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                maxPeak: belowThreshold,
                frameCount: frameCount,
                rampSamples: defaultRampSamples
            )
        }
        #expect(phase == 2)

        // processAudioCallback performs this state reset when it detects a real
        // callback gap or an unmute edge.
        phase = 0
        progress = 0

        _ = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: belowThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples
        )
        #expect(phase == 0)

        let entryMult = ProcessTapController.advanceOutputGate(
            phase: &phase,
            progress: &progress,
            maxPeak: aboveThreshold,
            frameCount: frameCount,
            rampSamples: defaultRampSamples
        )
        #expect(entryMult == 0)
        #expect(phase == 1)
        #expect(progress == 0)

        var promoted = false
        for _ in 0..<5 {
            let mult = ProcessTapController.advanceOutputGate(
                phase: &phase,
                progress: &progress,
                maxPeak: aboveThreshold,
                frameCount: frameCount,
                rampSamples: defaultRampSamples
            )
            if phase == 2 {
                #expect(mult == 1)
                promoted = true
                break
            } else {
                #expect(mult >= 0 && mult < 1)
            }
        }

        #expect(promoted)
    }
}
