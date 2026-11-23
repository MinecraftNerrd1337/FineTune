// FineTuneTests/AutoEQSwitchTests.swift
//
// Switching the correction on or off changes the preamp and the curve. AutoEQProcessor makes
// both changes on the same sample (a FIR filter is swapped without a crossfade), so the switch
// may click but no sample is louder than both the old and the new setting.

import Testing
import Foundation
@testable import FineTune

/// A 1 kHz sine at half scale on both channels, continuous across buffers.
private final class SineSource {
    private var frame = 0

    func fill(_ buffer: inout [Float], frames: Int) {
        for i in 0..<frames {
            let value = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(frame) / 48_000))
            buffer[2 * i] = value
            buffer[2 * i + 1] = value
            frame += 1
        }
    }
}

@Suite("AutoEQProcessor — switching the correction never plays louder")
struct AutoEQSwitchTests {

    /// About −10 dB above 100 Hz, no preamp.
    private static func corrected(_ engine: AutoEQCorrectionEngine) -> AutoEQProfile {
        AutoEQProfile(
            id: "switch", name: "Switch", source: .created, preampDB: 0,
            filters: [AutoEQFilter(type: .highShelf, frequency: 20, gainDB: -10, q: 0.7)],
            engine: engine)
    }

    /// The correction off, at the same level: the curve's −10 dB moved to the preamp.
    private static func off(_ engine: AutoEQCorrectionEngine) -> AutoEQProfile {
        var profile = corrected(engine)
        profile.filters = []
        profile.preampDB = -10
        return profile
    }

    /// Peak of each 256-frame block, letting the main queue run between blocks.
    private func peaks(_ processor: AutoEQProcessor, _ sine: SineSource, blocks: Int) async throws -> [Float] {
        let frames = 256
        var buffer = [Float](repeating: 0, count: frames * 2)
        var result: [Float] = []
        for _ in 0..<blocks {
            sine.fill(&buffer, frames: frames)
            buffer.withUnsafeMutableBufferPointer { samples in
                processor.process(input: UnsafePointer(samples.baseAddress!), output: samples.baseAddress!, frameCount: frames)
            }
            result.append(buffer.map { abs($0) }.max() ?? 0)
            try await Task.sleep(for: .milliseconds(2))
        }
        return result
    }

    @Test("Off and on again: at once, never louder than the steady level",
          arguments: [AutoEQCorrectionEngine.biquad, .minimumPhaseFIR])
    func neverLouder(engine: AutoEQCorrectionEngine) async throws {
        let processor = AutoEQProcessor(sampleRate: 48_000)
        let sine = SineSource()
        processor.updateProfile(Self.corrected(engine))
        let warmUp = try await peaks(processor, sine, blocks: 20)
        let steady = try #require(warmUp.suffix(5).max())
        #expect(abs(steady - 0.5 * powf(10, -10 / 20)) < 0.01)

        for profile in [Self.off(engine), Self.corrected(engine), Self.off(engine), Self.corrected(engine)] {
            processor.updateProfile(profile)
            let switching = try await peaks(processor, sine, blocks: 20)
            #expect(try #require(switching.max()) <= steady * 1.1)
            // Already at the new setting on the next buffers: no fade
            #expect(abs(switching[1] - steady) < steady * 0.1)
        }
    }

    @Test("A curve edited in place is still crossfaded")
    func editCrossfades() async throws {
        let processor = AutoEQProcessor(sampleRate: 48_000)
        let sine = SineSource()
        processor.updateProfile(Self.corrected(.minimumPhaseFIR))
        _ = try await peaks(processor, sine, blocks: 10)

        var edited = Self.corrected(.minimumPhaseFIR)
        edited.filters[0].gainDB = -4
        processor.updateProfile(edited)
        let fading = try await peaks(processor, sine, blocks: 20)
        let newLevel = 0.5 * powf(10, -4 / 20)
        #expect(fading[0] < newLevel - 0.03)
        #expect(abs(try #require(fading.last) - newLevel) < 0.01)
    }
}
