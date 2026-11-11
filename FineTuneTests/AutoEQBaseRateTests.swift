// FineTuneTests/AutoEQBaseRateTests.swift
//
// The base sample rate of a filter list (what its filters were designed for), and the
// GraphicEQ / Equalizer APO files the importer reads.

import Testing
import Foundation
@testable import FineTune

private let types: [AutoEQFilter.FilterType] = [.peaking, .lowShelf, .highShelf]

private func db(_ magnitudeSquared: Double) -> Double { 10 * log10(magnitudeSquared) }

private func cookbook(_ type: AutoEQFilter.FilterType, _ frequency: Double, _ gain: Float, _ q: Double, _ rate: Double) -> [Double] {
    switch type {
    case .peaking: return BiquadMath.peakingEQCoefficients(frequency: frequency, gainDB: gain, q: q, sampleRate: rate)
    case .lowShelf: return BiquadMath.lowShelfCoefficients(frequency: frequency, gainDB: gain, q: q, sampleRate: rate)
    case .highShelf: return BiquadMath.highShelfCoefficients(frequency: frequency, gainDB: gain, q: q, sampleRate: rate)
    }
}

@Suite("Base rate — the exact curve of a filter list")
struct AutoEQBaseRateCurveTests {

    @Test("At the base rate, the exact curve is the cookbook biquad's", arguments: [44_100.0, 48_000, 96_000])
    func intendedIsCookbookAtBaseRate(baseRate: Double) {
        for type in types {
            for frequency in [30.0, 105, 1000, 8000, 15_000, 20_000] {
                for gain: Float in [-12, -3, 4, 12] {
                    for q in [0.4, 0.71, 2, 8] {
                        let c = cookbook(type, frequency, gain, q, baseRate)
                        for f in [10.0, 200, 1000, 5000, 10_000, 16_000, 20_000] {
                            let intended = BiquadMath.intendedMagnitudeSquared(
                                type: type, centerFrequency: frequency, gainDB: Double(gain), q: q, at: f, baseRate: baseRate)
                            let actual = BiquadMath.digitalMagnitudeSquared(c, at: f, sampleRate: baseRate)
                            #expect(abs(db(intended) - db(actual)) < 1e-6, "\(type) \(frequency) Hz \(gain) dB Q \(q) at \(f) Hz")
                        }
                    }
                }
            }
        }
    }

    @Test("Above the base rate's Nyquist frequency the curve stays flat")
    func flatAboveBaseNyquist() {
        let at = { (f: Double) in
            BiquadMath.intendedMagnitudeSquared(type: .highShelf, centerFrequency: 8000, gainDB: 6, q: 0.7, at: f, baseRate: 44_100)
        }
        #expect(abs(db(at(22_050)) - db(at(30_000))) < 1e-3)
        #expect(abs(db(at(30_000)) - 6) < 0.01)
        // A band the base rate cannot hold is bypassed there
        #expect(BiquadMath.intendedMagnitudeSquared(
            type: .peaking, centerFrequency: 23_000, gainDB: 6, q: 1, at: 20_000, baseRate: 44_100) == 1)
    }

    @Test("Without a base rate the curve is the analog prototype")
    func analogWithoutBaseRate() {
        for f in [100.0, 1000, 12_000, 30_000] {
            #expect(BiquadMath.intendedMagnitudeSquared(
                type: .peaking, centerFrequency: 12_000, gainDB: 6, q: 2, at: f, baseRate: nil)
                == BiquadMath.analogMagnitudeSquared(type: .peaking, centerFrequency: 12_000, gainDB: 6, q: 2, at: f))
        }
    }

    @Test("The FIR engines aim for the curve at the preset's base rate")
    func exactCurveUsesBaseRate() {
        let filter = AutoEQFilter(type: .peaking, frequency: 12_000, gainDB: 6, q: 2)
        func preset(_ rate: Double) -> AutoEQProfile {
            AutoEQProfile(id: "p", name: "P", source: .imported, preampDB: 0, filters: [filter],
                          optimizedSampleRate: rate, engine: .minimumPhaseFIR)
        }
        let frequencies = [1000.0, 12_000, 18_000]
        let at44 = AutoEQResponse.exactCurve(of: preset(44_100), frequencies: frequencies)
        let c = BiquadMath.peakingEQCoefficients(frequency: 12_000, gainDB: 6, q: 2, sampleRate: 44_100)
        for (i, f) in frequencies.enumerated() {
            #expect(abs(at44[i] - db(BiquadMath.digitalMagnitudeSquared(c, at: f, sampleRate: 44_100))) < 1e-6)
        }
        let analog = AutoEQResponse.exactCurve(of: preset(AutoEQBaseRate.analog), frequencies: frequencies)
        #expect(abs(analog[2] - db(BiquadMath.analogMagnitudeSquared(
            type: .peaking, centerFrequency: 12_000, gainDB: 6, q: 2, at: 18_000))) < 1e-9)
        // Cramping at 44.1 kHz narrows the band: less gain at 18 kHz than the analog band
        #expect(at44[2] < analog[2] - 0.5)
    }
}

@Suite("Base rate — exact biquads")
struct AutoEQBaseRateBiquadTests {

    @Test("At the base rate the exact biquad is the cookbook biquad")
    func cookbookAtBaseRate() {
        for type in types {
            let exact = BiquadMath.exactCoefficients(
                type: type, frequency: 12_000, gainDB: 6, q: 2, sampleRate: 44_100, baseRate: 44_100)
            #expect(exact == cookbook(type, 12_000, 6, 2, 44_100))
        }
    }

    @Test("Played at another rate, it follows the base-rate curve much better than the re-tuned cookbook biquad")
    func followsBaseRateCurve() {
        let exact = BiquadMath.exactCoefficients(
            type: .peaking, frequency: 10_000, gainDB: -8, q: 4, sampleRate: 96_000, baseRate: 44_100)
        let retuned = BiquadMath.coefficientsForAutoEQFilters(
            [AutoEQFilter(type: .peaking, frequency: 10_000, gainDB: -8, q: 4)],
            sampleRate: 96_000, profileOptimizedRate: 44_100)
        let exactError = BiquadMath.maxErrorDB(
            exact, type: .peaking, frequency: 10_000, gainDB: -8, q: 4, sampleRate: 96_000, baseRate: 44_100)
        let retunedError = BiquadMath.maxErrorDB(
            retuned, type: .peaking, frequency: 10_000, gainDB: -8, q: 4, sampleRate: 96_000, baseRate: 44_100)
        #expect(retunedError > 3)
        #expect(exactError < 0.1)
    }

    @Test("Never worse than the re-tuned cookbook biquad, and always stable")
    func neverWorseAndStable() {
        let frequencies: [Double] = [20, 105, 1000, 6000, 10_000, 16_000, 19_000, 23_000, 30_000]
        let gains: [Float] = [-12, -3, 0, 3, 12]
        let qs: [Double] = [0.5, 0.71, 2, 6]
        let pairs: [(base: Double, rate: Double)] = [
            (44_100, 48_000), (44_100, 96_000), (44_100, 192_000), (48_000, 44_100), (96_000, 44_100), (192_000, 48_000),
        ]
        for (base, rate) in pairs {
            for type in types {
                for frequency in frequencies {
                    for gain in gains {
                        for q in qs {
                            let label = "\(type) \(frequency) Hz \(gain) dB Q \(q), base \(base) at \(rate)"
                            let exact = BiquadMath.exactCoefficients(
                                type: type, frequency: frequency, gainDB: gain, q: q, sampleRate: rate, baseRate: base)
                            #expect(exact.count == 5 && exact.allSatisfy(\.isFinite), "\(label)")
                            #expect(abs(exact[4]) < 1 && abs(exact[3]) < 1 + exact[4], "\(label)")
                            let retuned = BiquadMath.coefficientsForAutoEQFilters(
                                [AutoEQFilter(type: type, frequency: frequency, gainDB: gain, q: q)],
                                sampleRate: rate, profileOptimizedRate: base)
                            let exactError = BiquadMath.maxErrorDB(
                                exact, type: type, frequency: frequency, gainDB: Double(gain), q: q, sampleRate: rate, baseRate: base)
                            let retunedError = BiquadMath.maxErrorDB(
                                retuned, type: type, frequency: frequency, gainDB: Double(gain), q: q, sampleRate: rate, baseRate: base)
                            #expect(exactError <= retunedError + 1e-9, "\(label)")
                        }
                    }
                }
            }
        }
    }

    @Test("An analog base rate keeps the cookbook biquads as written")
    func analogBaseRate() {
        let filters = [AutoEQFilter(type: .highShelf, frequency: 9000, gainDB: 4, q: 0.7)]
        let analog = BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: 96_000, profileOptimizedRate: AutoEQBaseRate.analog)
        #expect(analog == BiquadMath.highShelfCoefficients(frequency: 9000, gainDB: 4, q: 0.7, sampleRate: 96_000))
        let exact = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: 96_000, profileOptimizedRate: AutoEQBaseRate.analog, exact: true)
        #expect(exact == BiquadMath.exactCoefficients(type: .highShelf, frequency: 9000, gainDB: 4, q: 0.7, sampleRate: 96_000))
    }

    @Test("The FIR design depends on the base rate")
    func kernelDependsOnBaseRate() throws {
        func preset(_ rate: Double) -> AutoEQProfile {
            AutoEQProfile(id: "k", name: "K", source: .imported, preampDB: 0,
                          filters: [AutoEQFilter(type: .peaking, frequency: 12_000, gainDB: 6, q: 2)],
                          optimizedSampleRate: rate, engine: .minimumPhaseFIR)
        }
        let at44 = try #require(FIRKernelCache.kernel(for: preset(44_100), sampleRate: 96_000))
        let at48 = try #require(FIRKernelCache.kernel(for: preset(48_000), sampleRate: 96_000))
        #expect(at44.taps != at48.taps)
    }
}

@Suite("Base rate — model")
struct AutoEQBaseRateModelTests {

    @Test("Labels")
    func labels() {
        #expect(AutoEQBaseRate.label(44_100) == "44.1 kHz")
        #expect(AutoEQBaseRate.label(48_000) == "48 kHz")
        #expect(AutoEQBaseRate.label(176_400) == "176.4 kHz")
        #expect(AutoEQBaseRate.label(0) == "Analog")
    }

    @Test("Stored rates are sanitized")
    func sanitized() {
        #expect(AutoEQBaseRate.sanitized(44_100) == 44_100)
        #expect(AutoEQBaseRate.sanitized(0) == 0)
        #expect(AutoEQBaseRate.sanitized(.nan) == 48_000)
        #expect(AutoEQBaseRate.sanitized(-1) == 48_000)
        #expect(AutoEQBaseRate.sanitized(5) == 48_000)
        let profile = AutoEQProfile(id: "v", name: "V", source: .imported, preampDB: 0, filters: [], optimizedSampleRate: .infinity)
        #expect(profile.validated().optimizedSampleRate == 48_000)
    }

    @Test("A preset without a stored rate decodes at 48 kHz, as earlier builds assumed")
    func legacyDecoding() throws {
        let json = Data(#"{"id":"a","name":"A","source":"imported","preampDB":0,"filters":[]}"#.utf8)
        #expect(try JSONDecoder().decode(AutoEQProfile.self, from: json).optimizedSampleRate == 48_000)
    }

    @Test("The analog rate has no base rate for the response math")
    func designBaseRate() {
        var profile = AutoEQProfile(id: "d", name: "D", source: .imported, preampDB: 0, filters: [], optimizedSampleRate: 44_100)
        #expect(profile.designBaseRate == 44_100)
        profile.optimizedSampleRate = AutoEQBaseRate.analog
        #expect(profile.designBaseRate == nil)
    }
}

@Suite("GraphicEQ and Equalizer APO files")
struct AutoEQGraphicEQFileTests {

    @Test("A byte order mark before a one-line Wavelet file is ignored")
    func byteOrderMark() throws {
        let profile = try #require(AutoEQParser.parse(
            text: "\u{FEFF}GraphicEQ: 20 -1; 1000 2; 20000 0", name: "Wavelet", source: .imported))
        #expect(profile.kind == .graphic)
        #expect(profile.curve.count == 3)
    }

    @Test("UTF-8, UTF-16 and Windows Latin-1 files are decoded")
    func decoding() throws {
        let text = "Preamp: -2 dB\r\nGraphicEQ: 20 -1; 1000 2; 20000 0\r\n"
        let encodings: [Data] = [
            Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8),
            Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!,
            Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!,
            text.data(using: .utf16LittleEndian)!,
            text.data(using: .utf16BigEndian)!,
            ("# Égaliseur\r\n" + text).data(using: .windowsCP1252)!,
        ]
        for (index, data) in encodings.enumerated() {
            let decoded = try #require(AutoEQParser.decodeText(data), "encoding \(index)")
            let profile = try #require(AutoEQParser.parse(text: decoded, name: "F", source: .imported), "encoding \(index)")
            #expect(profile.kind == .graphic, "encoding \(index)")
            #expect(profile.preampDB == -2, "encoding \(index)")
            #expect(profile.curve.map(\.gainDB) == [-1, 2, 0], "encoding \(index)")
        }
    }

    @Test("GraphicEQ lines and preamps add up, as in Equalizer APO")
    func curvesAddUp() throws {
        let text = """
        Preamp: -2 dB
        GraphicEQ: 100 1; 1000 1
        Preamp: -1.5 dB
        GraphicEQ: 100 0; 10000 4
        """
        let profile = try #require(AutoEQParser.parse(text: text, name: "Sum", source: .imported))
        #expect(profile.preampDB == -3.5)
        #expect(profile.curve.map(\.frequency) == [100, 1000, 10_000])
        let gains = profile.curve.map { Double($0.gainDB) }
        #expect(abs(gains[0] - 1) < 1e-5)
        #expect(abs(gains[1] - 3) < 1e-5)       // 1 + halfway (in log frequency) from 0 to 4
        #expect(abs(gains[2] - 5) < 1e-5)
    }

    @Test("Only the first channel group is read")
    func firstChannelGroup() throws {
        let text = """
        Device: Speakers
        Preamp: -2 dB
        Channel: L
        GraphicEQ: 100 1; 1000 1
        Channel: R
        Preamp: -10 dB
        GraphicEQ: 100 5; 1000 5
        Channel: all
        Preamp: -1 dB
        """
        let profile = try #require(AutoEQParser.parse(text: text, name: "LR", source: .imported))
        #expect(profile.preampDB == -3)
        #expect(profile.curve.map(\.gainDB) == [1, 1])
    }
}
