// FineTuneTests/AutoEQEngineModelTests.swift
//
// What a preset stores about its correction engine and curve: engine choice and fallbacks,
// GraphicEQ parsing, the curve's interpolation, and the exact-fitted ("matched") biquads.

import Testing
import Foundation
@testable import FineTune

@Suite("AutoEQCorrectionEngine")
struct AutoEQCorrectionEngineTests {

    @Test("The FIR engine of earlier builds decodes as minimum-phase FIR")
    func decoding() throws {
        let json = Data(#"["exactFIR","biquad","matchedBiquad","minimumPhaseFIR","linearPhaseFIR","nonsense"]"#.utf8)
        let engines = try JSONDecoder().decode([AutoEQCorrectionEngine].self, from: json)
        #expect(engines == [.minimumPhaseFIR, .biquad, .matchedBiquad, .minimumPhaseFIR, .linearPhaseFIR, .biquad])
    }

    @Test("Graphic presets can only use the FIR engines")
    func availability() {
        #expect(AutoEQCorrectionEngine.available(for: .parametric) == AutoEQCorrectionEngine.allCases)
        #expect(AutoEQCorrectionEngine.available(for: .graphic) == [.minimumPhaseFIR, .linearPhaseFIR])

        let curve = [AutoEQCurvePoint(frequency: 100, gainDB: 1), AutoEQCurvePoint(frequency: 1000, gainDB: -1)]
        var profile = AutoEQProfile(
            id: "g", name: "G", source: .imported, preampDB: 0, filters: [],
            kind: .graphic, engine: .biquad, curve: curve)
        #expect(profile.effectiveEngine == .minimumPhaseFIR)
        profile.engine = .linearPhaseFIR
        #expect(profile.effectiveEngine == .linearPhaseFIR)
        profile.kind = .parametric
        profile.engine = .matchedBiquad
        #expect(profile.effectiveEngine == .matchedBiquad)
    }

    @Test("A preset has a correction when it has bands, or a curve of two points")
    func hasCorrection() {
        var profile = AutoEQProfile(id: "p", name: "P", source: .imported, preampDB: -3, filters: [])
        #expect(!profile.hasCorrection)
        profile.filters = [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 1, q: 1)]
        #expect(profile.hasCorrection)

        profile.kind = .graphic
        #expect(!profile.hasCorrection)
        profile.curve = [AutoEQCurvePoint(frequency: 100, gainDB: 1)]
        #expect(!profile.hasCorrection)
        profile.curve.append(AutoEQCurvePoint(frequency: 1000, gainDB: -1))
        #expect(profile.hasCorrection)
    }

    @Test("The curve survives saving and loading; presets saved without one still load")
    func codable() throws {
        let profile = AutoEQProfile(
            id: "g", name: "G", source: .imported, preampDB: -2, filters: [],
            kind: .graphic, engine: .linearPhaseFIR,
            curve: [AutoEQCurvePoint(frequency: 100, gainDB: 1), AutoEQCurvePoint(frequency: 1000, gainDB: -1)])
        let decoded = try JSONDecoder().decode(AutoEQProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)

        let legacy = Data(#"{"id":"x","name":"X","source":"imported","preampDB":-1,"filters":[],"engine":"exactFIR"}"#.utf8)
        let old = try JSONDecoder().decode(AutoEQProfile.self, from: legacy)
        #expect(old.curve.isEmpty)
        #expect(old.engine == .minimumPhaseFIR)
        #expect(old.kind == .parametric)
    }
}

@Suite("AutoEQParser — GraphicEQ")
struct AutoEQParserGraphicEQTests {

    @Test("A GraphicEQ file becomes a graphic preset rendered by minimum-phase FIR")
    func parsesFile() throws {
        let text = """
        Preamp: -5.5 dB
        GraphicEQ: 20 -1.5; 100 2.0; 1000 0; 10000 -3.2; 50 1.0
        """
        let profile = try #require(AutoEQParser.parse(text: text, name: "Wavelet", source: .imported))
        #expect(profile.kind == .graphic)
        #expect(profile.engine == .minimumPhaseFIR)
        #expect(profile.preampDB == -5.5)
        #expect(profile.filters.isEmpty)
        #expect(profile.curve.map(\.frequency) == [20, 50, 100, 1000, 10_000])
        #expect(profile.curve.map(\.gainDB) == [-1.5, 1.0, 2.0, 0, -3.2])
        #expect(profile.hasCorrection)
    }

    @Test("Malformed, out-of-range and duplicate points are skipped, gains limited to ±30 dB")
    func skipsBadPoints() {
        let points = AutoEQParser.parseGraphicEQ("GraphicEQ: 100 1; abc; 200; 300 x; 0.5 1; 400 99; 100 5; 500 -2 ;")
        #expect(points == [
            AutoEQCurvePoint(frequency: 100, gainDB: 1),
            AutoEQCurvePoint(frequency: 400, gainDB: 30),
            AutoEQCurvePoint(frequency: 500, gainDB: -2),
        ])
        #expect(AutoEQParser.parseGraphicEQ("no colon here").isEmpty)
    }

    @Test("A file with filters stays a parametric preset")
    func parametricWins() throws {
        let text = """
        Preamp: -3 dB
        Filter 1: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.41
        GraphicEQ: 20 0; 20000 0
        """
        let profile = try #require(AutoEQParser.parse(text: text, name: "Both", source: .imported))
        #expect(profile.kind == .parametric)
        #expect(profile.filters.count == 1)
        #expect(profile.curve.isEmpty)
    }

    @Test("A single point is not a curve")
    func singlePoint() {
        #expect(AutoEQParser.parse(text: "GraphicEQ: 1000 3", name: "One", source: .imported) == nil)
    }
}

@Suite("AutoEQResponse — graphic curve")
struct AutoEQResponseGraphicCurveTests {
    private let points = [AutoEQCurvePoint(frequency: 100, gainDB: 0), AutoEQCurvePoint(frequency: 1000, gainDB: 10)]

    @Test("Straight lines on a log-frequency axis, flat beyond the ends")
    func interpolation() {
        let gains = AutoEQResponse.graphicCurve(points, frequencies: [20, 100, 316.227766, 1000, 15_000])
        #expect(abs(gains[0] - 0) < 1e-9)
        #expect(abs(gains[1] - 0) < 1e-9)
        #expect(abs(gains[2] - 5) < 1e-6)
        #expect(abs(gains[3] - 10) < 1e-9)
        #expect(abs(gains[4] - 10) < 1e-9)
        #expect(AutoEQResponse.graphicCurve([], frequencies: [100, 1000]) == [0, 0])
    }

    @Test("The design grid samples the curve at every DFT bin")
    func designGrid() {
        let profile = AutoEQProfile(
            id: "g", name: "G", source: .imported, preampDB: 0, filters: [],
            kind: .graphic, engine: .minimumPhaseFIR, curve: points)
        let size = 65_536
        let grid = AutoEQResponse.designGrid(of: profile, sampleRate: 48_000, gridSize: size)
        #expect(grid.count == size / 2 + 1)
        #expect(abs(grid[0]) < 1e-6)                       // 0 Hz: flat below the first point
        let bin = Int((316.227766 / 48_000 * Double(size)).rounded())
        #expect(abs(grid[bin] - 5) < 0.02)
        #expect(abs(grid[size / 2] - 10) < 1e-6)           // Nyquist: flat above the last point
    }

    @Test("Peak and recommended preamp work for graphic presets")
    func peak() throws {
        let profile = AutoEQProfile(
            id: "g", name: "G", source: .imported, preampDB: 0, filters: [],
            kind: .graphic, engine: .minimumPhaseFIR, curve: points)
        let peak = try #require(AutoEQResponse.peakDB(profile))
        #expect(abs(peak - 10) < 1e-6)
        let preamp = try #require(AutoEQResponse.recommendedPreampDB(profile))
        // The peak boost as a cut, with no margin (as PEQdB recommends it)
        #expect(abs(preamp + 10) < 1e-9)
    }

    @Test("A preamp equal to the peak boost cannot clip")
    func clipRisk() {
        #expect(AutoEQResponse.clipRiskDB(preampDB: -5.4, peakDB: 5.43) == 0)
        #expect(AutoEQResponse.clipRiskDB(preampDB: -5.5, peakDB: 5.46) == 0)
        #expect(AutoEQResponse.clipRiskDB(preampDB: -8, peakDB: 5) == 0)
        #expect(abs(AutoEQResponse.clipRiskDB(preampDB: -5, peakDB: 5.46) - 0.5) < 1e-9)
    }
}

@Suite("BiquadMath — exact-fitted biquads")
struct BiquadMathMatchedTests {

    @Test("Much closer to the exact curve than the cookbook biquad near the top of the spectrum")
    func closerNearNyquist() throws {
        let cookbook = BiquadMath.peakingEQCoefficients(frequency: 12_000, gainDB: 6, q: 2, sampleRate: 44_100)
        let matched = try #require(BiquadMath.matchedCoefficients(
            type: .peaking, frequency: 12_000, gainDB: 6, q: 2, sampleRate: 44_100))
        let cookbookError = BiquadMath.maxErrorDB(cookbook, type: .peaking, frequency: 12_000, gainDB: 6, q: 2, sampleRate: 44_100)
        let matchedError = BiquadMath.maxErrorDB(matched, type: .peaking, frequency: 12_000, gainDB: 6, q: 2, sampleRate: 44_100)
        #expect(cookbookError > 1.0)
        #expect(matchedError < 0.4)
    }

    @Test("A cut is the exact inverse of the same boost")
    func cutMirrorsBoost() throws {
        let boost = try #require(BiquadMath.matchedCoefficients(
            type: .peaking, frequency: 8000, gainDB: 5, q: 1.5, sampleRate: 48_000))
        let cut = try #require(BiquadMath.matchedCoefficients(
            type: .peaking, frequency: 8000, gainDB: -5, q: 1.5, sampleRate: 48_000))
        for frequency in [100.0, 1000, 5000, 8000, 12_000, 20_000] {
            let product = BiquadMath.digitalMagnitudeSquared(boost, at: frequency, sampleRate: 48_000)
                * BiquadMath.digitalMagnitudeSquared(cut, at: frequency, sampleRate: 48_000)
            #expect(abs(product - 1) < 1e-9)
        }
    }

    @Test("Never worse than the cookbook biquad, and always stable")
    func neverWorseAndStable() {
        let types: [AutoEQFilter.FilterType] = [.peaking, .lowShelf, .highShelf]
        let frequencies: [Double] = [20, 60, 105, 1000, 6000, 10_000, 16_000, 19_000, 23_000]
        let gains: [Float] = [-24, -12, -3, -0.5, 0, 0.5, 3, 12, 24]
        let qs: [Double] = [0.1, 0.5, 0.71, 1.41, 4, 10, 30]
        for sampleRate in [44_100.0, 48_000, 96_000] {
            for type in types {
                for frequency in frequencies {
                    for gain in gains {
                        for q in qs {
                            let exact = BiquadMath.exactCoefficients(
                                type: type, frequency: frequency, gainDB: gain, q: q, sampleRate: sampleRate)
                            let label = "\(type) \(frequency) Hz \(gain) dB Q \(q) at \(sampleRate)"
                            #expect(exact.count == 5 && exact.allSatisfy(\.isFinite), "\(label)")
                            // Poles inside the unit circle
                            #expect(abs(exact[4]) < 1 && abs(exact[3]) < 1 + exact[4], "\(label)")

                            guard frequency < sampleRate / 2 else { continue }
                            let cookbook = BiquadMath.coefficientsForAutoEQFilters(
                                [AutoEQFilter(type: type, frequency: frequency, gainDB: gain, q: q)],
                                sampleRate: sampleRate, profileOptimizedRate: sampleRate)
                            let exactError = BiquadMath.maxErrorDB(
                                exact, type: type, frequency: frequency, gainDB: Double(gain), q: q, sampleRate: sampleRate)
                            let cookbookError = BiquadMath.maxErrorDB(
                                cookbook, type: type, frequency: frequency, gainDB: Double(gain), q: q, sampleRate: sampleRate)
                            #expect(exactError <= cookbookError + 1e-9, "\(label)")
                        }
                    }
                }
            }
        }
    }

    @Test("The exact option of the AutoEQ coefficients uses the fitted design, band by band")
    func autoEQCoefficients() {
        let filters = [
            AutoEQFilter(type: .peaking, frequency: 12_000, gainDB: 6, q: 2),
            AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: 5, q: 0.7),
        ]
        let exact = BiquadMath.coefficientsForAutoEQFilters(
            filters, sampleRate: 44_100, profileOptimizedRate: 48_000, exact: true)
        #expect(exact.count == 10)
        #expect(Array(exact[0..<5]) == BiquadMath.exactCoefficients(
            type: .peaking, frequency: 12_000, gainDB: 6, q: 2, sampleRate: 44_100, baseRate: 48_000))
        #expect(Array(exact[5..<10]) == BiquadMath.exactCoefficients(
            type: .lowShelf, frequency: 105, gainDB: 5, q: 0.7, sampleRate: 44_100, baseRate: 48_000))
        // Not the cookbook design for the band near Nyquist
        let cookbook = BiquadMath.coefficientsForAutoEQFilters(filters, sampleRate: 44_100, profileOptimizedRate: 44_100)
        #expect(Array(exact[0..<5]) != Array(cookbook[0..<5]))
    }
}
