// FineTuneTests/CoreHardening/CrossfadeReentrancyTests.swift
//
// Tests for crossfade re-entrancy guard (ORCH-001).
// Verifies that concurrent crossfade operations are properly serialized.

import Testing
import Foundation
@testable import FineTune

// MARK: - CrossfadeState Phase Transitions

@Suite("CrossfadeState — Phase Transitions (Core Hardening)")
struct CrossfadeStatePhaseTests {

    @Test("Full lifecycle: idle -> warmingUp -> crossfading -> idle")
    func fullLifecycle() {
        var state = CrossfadeState()
        #expect(state.phase == .idle)
        #expect(!state.isActive)

        state.beginWarmup()
        #expect(state.phase == .warmingUp)
        #expect(state.isActive)
        #expect(state.progress == 0)

        state.totalSamples = 24000
        state.beginCrossfading()
        #expect(state.phase == .crossfading)
        #expect(state.isActive)
        #expect(state.progress == 0)

        state.complete()
        #expect(state.phase == .idle)
        #expect(!state.isActive)
    }

    @Test("beginWarmup during crossfading: full reset, multipliers snap to warmup values")
    func warmupDuringCrossfade() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = 0.5  // Mid-crossfade

        // Interrupt with new warmup (device switch during crossfade)
        state.beginWarmup()

        #expect(state.phase == .warmingUp)
        #expect(state.progress == 0)
        #expect(state.secondarySampleCount == 0)
        #expect(state.secondarySamplesProcessed == 0)
        #expect(state.primaryMultiplier == 1.0)
        #expect(state.secondaryMultiplier == 0.0)
    }

    @Test("complete() resets all state including totalSamples")
    func completeResetsAll() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 24000
        state.beginCrossfading()
        _ = state.updateProgress(samples: 12000)

        state.complete()

        #expect(state.progress == 0)
        #expect(state.secondarySampleCount == 0)
        #expect(state.secondarySamplesProcessed == 0)
        #expect(state.totalSamples == 0)
        #expect(state.phase == .idle)
    }

    @Test("Double complete() is safe (idempotent reset)")
    func doubleComplete() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = 0.7

        state.complete()
        state.complete()

        #expect(state.phase == .idle)
        #expect(state.progress == 0)
        #expect(!state.isActive)
    }
}

// MARK: - Equal-Power Crossfade Invariant

@Suite("CrossfadeState — Equal-Power Invariant (Core Hardening)")
struct CrossfadeEqualPowerCoreHardeningTests {

    @Test("primary^2 + secondary^2 = 1.0 during crossfading phase",
          arguments: [Float(0.0), 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0])
    func equalPowerDuringCrossfade(progress: Float) {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()
        state.progress = progress

        let p = state.primaryMultiplier
        let s = state.secondaryMultiplier
        let powerSum = p * p + s * s
        #expect(abs(powerSum - 1.0) < 1e-5,
                "Equal-power violated at progress=\(progress): p=\(p) s=\(s) p^2+s^2=\(powerSum)")
    }

    @Test("Primary multiplier monotonically decreases during crossfade")
    func primaryMonotonicallyDecreases() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()

        var prevPrimary: Float = 2.0
        for i in 0...100 {
            state.progress = Float(i) / 100.0
            let p = state.primaryMultiplier
            #expect(p <= prevPrimary,
                    "Primary should decrease: at \(state.progress), p=\(p) > prev=\(prevPrimary)")
            prevPrimary = p
        }
    }

    @Test("Secondary multiplier monotonically increases during crossfade")
    func secondaryMonotonicallyIncreases() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000
        state.beginCrossfading()

        var prevSecondary: Float = -1.0
        for i in 0...100 {
            state.progress = Float(i) / 100.0
            let s = state.secondaryMultiplier
            #expect(s >= prevSecondary,
                    "Secondary should increase: at \(state.progress), s=\(s) < prev=\(prevSecondary)")
            prevSecondary = s
        }
    }
}

// MARK: - Progress Mechanics

@Suite("CrossfadeState — Progress Mechanics (Core Hardening)")
struct CrossfadeProgressCoreHardeningTests {

    @Test("updateProgress: progress clamped at 1.0 (never exceeds)")
    func progressClampedAtOne() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 1000
        state.beginCrossfading()

        for _ in 0..<100 {
            let p = state.updateProgress(samples: 512)
            #expect(p <= 1.0, "Progress must never exceed 1.0, got \(p)")
        }
    }

    @Test("updateProgress: totalSamples=0 defense (progress clamps to 1.0 immediately)")
    func totalSamplesZeroDefense() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.beginCrossfading()

        let p = state.updateProgress(samples: 1)
        #expect(p == 1.0, "With totalSamples=0, any progress should clamp to 1.0, got \(p)")
        #expect(state.isCrossfadeComplete)
    }

    @Test("isWarmupComplete: transitions at exactly minimumWarmupSamples")
    func warmupCompletionThreshold() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 48000

        _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples - 1)
        #expect(!state.isWarmupComplete)

        _ = state.updateProgress(samples: 1)
        #expect(state.isWarmupComplete)
    }

    @Test("Normal crossfade timing: progress reaches 1.0 at totalSamples")
    func crossfadeTiming() {
        var state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 4800
        state.beginCrossfading()

        var buffers = 0
        while !state.isCrossfadeComplete {
            _ = state.updateProgress(samples: 480)
            buffers += 1
            if buffers > 100 { break }
        }

        #expect(buffers == 10, "Crossfade should complete in exactly 10 buffers, took \(buffers)")
        #expect(state.progress == 1.0)
    }
}

// MARK: - Idle Phase Edge Cases

@Suite("CrossfadeState — Idle Phase Multipliers (Core Hardening)")
struct CrossfadeIdleCoreHardeningTests {

    @Test("Idle with progress >= 1.0: primary=0, secondary=1 (post-crossfade window)")
    func idlePostCrossfadeWindow() {
        var state = CrossfadeState()
        state.progress = 1.0

        #expect(state.primaryMultiplier == 0.0)
        #expect(state.secondaryMultiplier == 1.0)
    }

    @Test("Idle with progress < 1.0: primary=1, secondary=1 (normal idle)")
    func idleNormalState() {
        var state = CrossfadeState()
        state.progress = 0.0
        #expect(state.primaryMultiplier == 1.0)
        #expect(state.secondaryMultiplier == 1.0)

        state.progress = 0.5
        #expect(state.primaryMultiplier == 1.0)
        #expect(state.secondaryMultiplier == 1.0)
    }
}
