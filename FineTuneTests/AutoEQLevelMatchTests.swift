// FineTuneTests/AutoEQLevelMatchTests.swift
//
// With a device's correction off, FineTune adds the level its curve takes away or adds to the
// preamp (AutoEQResponse.perceivedLevelChangeDB, the RMS of music through the curve), so turning
// the correction off keeps the same loudness. The preset and its preamp are left as they are,
// and the Preamp switch bypasses the level match with the preamp.

import Testing
import Foundation
@testable import FineTune

private func graphicPreset(_ points: [(Double, Float)], preampDB: Float = 0) -> AutoEQProfile {
    AutoEQProfile(
        id: "graphic", name: "Graphic", source: .created, preampDB: preampDB, filters: [],
        kind: .graphic, engine: .minimumPhaseFIR,
        curve: points.map { AutoEQCurvePoint(frequency: $0.0, gainDB: $0.1) }
    )
}

private func level(_ points: [(Double, Float)]) throws -> Double {
    try #require(AutoEQResponse.perceivedLevelChangeDB(graphicPreset(points)))
}

/// Gain in dB of a preamp-only processor, once it has settled (it ramps to a new gain).
private func flatGainDB(of processor: AutoEQProcessor) async throws -> Double {
    let frames = 512
    var output = [Float](repeating: 0, count: frames * 2)
    for _ in 0..<10 {
        let input = [Float](repeating: 0.25, count: frames * 2)
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                processor.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: frames)
            }
        }
        try await Task.sleep(for: .milliseconds(3))
    }
    return 20 * log10(Double(output[2 * frames - 2]) / 0.25)
}

@Suite("AutoEQ level match — the same loudness with the correction off")
struct AutoEQLevelMatchTests {

    @Test("A curve 10 dB down everywhere is 10 dB quieter, a flat one unchanged")
    func flatCurves() throws {
        #expect(abs(try level([(20, -10), (20_000, -10)]) + 10) < 0.01)
        #expect(abs(try level([(20, 0), (20_000, 0)])) < 0.01)
        #expect(AutoEQResponse.perceivedLevelChangeDB(graphicPreset([])) == nil)
    }

    @Test("The RMS of a music spectrum: the bass and low mids weigh more than the treble")
    func musicSpectrum() throws {
        // Mostly −10 dB, +2 dB from 1 to 3 kHz
        let mixed: [(Double, Float)] = [(20, -10), (1000, -10), (1001, 2), (3000, 2), (3001, -10), (20_000, -10)]
        #expect(abs(try level(mixed) + 6.62) < 0.05)
        let subCut: [(Double, Float)] = [(20, -10), (49, -10), (51, 0), (20_000, 0)]
        #expect(abs(try level(subCut) + 0.96) < 0.05)
        // The same cut weighs less an octave higher, above 500 Hz
        let low = try level([(20, 0), (999, 0), (1000, -10), (2000, -10), (2001, 0), (20_000, 0)])
        let high = try level([(20, 0), (3999, 0), (4000, -10), (8000, -10), (8001, 0), (20_000, 0)])
        #expect(high > low)
    }

    @Test("Never more than the peak boost")
    func belowPeak() throws {
        let boost = AutoEQProfile(
            id: "peq", name: "PEQ", source: .created, preampDB: -6,
            filters: [AutoEQFilter(type: .peaking, frequency: 3000, gainDB: 6, q: 1)])
        let change = try #require(AutoEQResponse.perceivedLevelChangeDB(boost))
        let peak = try #require(AutoEQResponse.peakDB(boost))
        #expect(change > 0)
        #expect(change < peak)
    }

    @Test("Correction off: filters dropped, preamp kept, level added only when level-matched")
    func activeProfile() {
        let preset = graphicPreset([(20, -10), (20_000, -10)], preampDB: -2)
        let matched = AudioEngine.activeAutoEQProfile(preset, correctionEnabled: false, levelMatched: true)
        #expect(!matched.hasCorrection)
        #expect(matched.preampDB == -2)
        #expect(abs(matched.levelMatchDB + 10) < 0.01)

        let plain = AudioEngine.activeAutoEQProfile(preset, correctionEnabled: false, levelMatched: false)
        #expect(plain.levelMatchDB == 0)
        #expect(AudioEngine.activeAutoEQProfile(preset, correctionEnabled: true, levelMatched: true) == preset)
    }

    @Test("The processor plays preamp plus level match, and the Preamp switch bypasses both")
    func processorGain() async throws {
        let preset = graphicPreset([(20, -10), (20_000, -10)], preampDB: -2)
        let profile = AudioEngine.activeAutoEQProfile(preset, correctionEnabled: false, levelMatched: true)
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(profile)
        #expect(abs(try await flatGainDB(of: processor) + 12) < 0.05)
        processor.setPreampEnabled(false)
        #expect(abs(try await flatGainDB(of: processor)) < 0.05)
    }

    @Test("The gain of a compared preset plays with the Preamp switch on or off")
    func comparisonGain() async throws {
        var profile = graphicPreset([(20, -10), (20_000, -10)], preampDB: -2)
        profile.comparisonGainDB = 4
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(profile)
        #expect(abs(try await flatGainDB(of: processor) - (-10 - 2 + 4)) < 0.05)
        processor.setPreampEnabled(false)
        #expect(abs(try await flatGainDB(of: processor) - (-10 + 4)) < 0.05)
    }

    @Test("Never stored: the gain of a compared preset is not encoded")
    func comparisonGainNotStored() throws {
        var profile = graphicPreset([(20, -10), (20_000, -10)])
        profile.comparisonGainDB = 4
        let decoded = try JSONDecoder().decode(AutoEQProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.comparisonGainDB == 0)
        #expect(profile.validated().comparisonGainDB == 4)
    }

    @Test("Never stored: the level match is not encoded, and the setting is on by default")
    func notStored() throws {
        var profile = graphicPreset([(20, -10), (20_000, -10)])
        profile.levelMatchDB = -10
        let decoded = try JSONDecoder().decode(AutoEQProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.levelMatchDB == 0)
        #expect(profile.validated().levelMatchDB == -10)

        let defaults = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(defaults.autoEQLevelMatchEnabled)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoEQLevelMatchEnabled":false}"#.utf8))
        #expect(!off.autoEQLevelMatchEnabled)
    }
}
