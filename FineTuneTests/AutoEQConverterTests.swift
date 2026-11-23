// FineTuneTests/AutoEQConverterTests.swift
//
// The fitting engine of the EQ Manager's conversions (AutoEQCurveFitter) and the conversions
// themselves (AutoEQConverter): parametric to graphic, graphic to parametric, another number
// of bands, another base rate. Pure maths: no audio device needed.

import Testing
import Foundation
@testable import FineTune

private let fitGrid = AutoEQResponse.logFrequencies(count: 384)

private func db(_ magnitudeSquared: Double) -> Double { 10 * log10(magnitudeSquared) }

/// A filter list like AutoEQ's, with shelves and narrow bands near the top.
private let tenBands: [AutoEQFilter] = [
    AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: 5.5, q: 0.7),
    AutoEQFilter(type: .peaking, frequency: 200, gainDB: -2.5, q: 0.5),
    AutoEQFilter(type: .peaking, frequency: 3200, gainDB: 3, q: 2),
    AutoEQFilter(type: .peaking, frequency: 6000, gainDB: -4, q: 4),
    AutoEQFilter(type: .highShelf, frequency: 10_000, gainDB: 2, q: 0.7),
    AutoEQFilter(type: .peaking, frequency: 1200, gainDB: 1.5, q: 1.4),
    AutoEQFilter(type: .peaking, frequency: 60, gainDB: -3, q: 1.2),
    AutoEQFilter(type: .peaking, frequency: 9000, gainDB: 3, q: 3),
    AutoEQFilter(type: .peaking, frequency: 450, gainDB: 1, q: 2),
    AutoEQFilter(type: .peaking, frequency: 14_000, gainDB: -3, q: 2),
]

private let fiveBands: [AutoEQFilter] = [
    AutoEQFilter(type: .lowShelf, frequency: 120, gainDB: 4, q: 0.7),
    AutoEQFilter(type: .peaking, frequency: 900, gainDB: -3, q: 1.5),
    AutoEQFilter(type: .peaking, frequency: 3000, gainDB: 4, q: 3),
    AutoEQFilter(type: .peaking, frequency: 7000, gainDB: -5, q: 4),
    AutoEQFilter(type: .highShelf, frequency: 11_000, gainDB: 3, q: 0.7),
]

private func preset(_ filters: [AutoEQFilter], baseRate: Double, preamp: Float = -6) -> AutoEQProfile {
    AutoEQProfile(
        id: "source", name: "Source", source: .imported, preampDB: preamp, filters: filters,
        optimizedSampleRate: baseRate, kind: .parametric, engine: .matchedBiquad)
}

/// A fitter for the exact curve of `filters` at `baseRate` (0: analog), fitted at the same rate.
private func makeFitter(for filters: [AutoEQFilter], baseRate: Double, maxBands: Int) -> AutoEQCurveFitter {
    let rate: Double? = baseRate > 0 ? baseRate : nil
    let target = AutoEQResponse.curve(filters, engine: .minimumPhaseFIR, frequencies: fitGrid, baseRate: rate)
    let problem = AutoEQFitProblem(frequencies: fitGrid, target: target, baseRate: rate)
    return AutoEQCurveFitter(problem: problem, maxBands: maxBands)
}

@Suite("Curve fitter — band curves")
struct AutoEQCurveFitterBandTests {

    @Test("A band's curve is its exact curve (cookbook at the base rate, or analog)", arguments: [44_100.0, 96_000, 0])
    func bandCurveIsExact(baseRate: Double) {
        let fitter = makeFitter(for: [], baseRate: baseRate, maxBands: 1)
        for type in [AutoEQFilter.FilterType.peaking, .lowShelf, .highShelf] {
            for frequency in [25.0, 300, 4000, 15_000] {
                for gain in [-12.0, -1, 3, 12] {
                    for q in [0.3, 0.71, 3, 12] {
                        let filter = AutoEQFilter(type: type, frequency: frequency, gainDB: Float(gain), q: q)
                        let values = fitter.bandResponse(AutoEQFitBand(filter)).dB
                        for (index, f) in fitGrid.enumerated() where index % 16 == 0 {
                            let exact = db(BiquadMath.intendedMagnitudeSquared(
                                type: type, centerFrequency: frequency, gainDB: Double(filter.gainDB), q: q, at: f,
                                baseRate: baseRate > 0 ? baseRate : nil))
                            #expect(abs(values[index] - exact) < 1e-8, "\(type) \(frequency) Hz \(gain) dB Q \(q) at \(f) Hz")
                        }
                    }
                }
            }
        }
    }

    @Test("Analytic derivatives match finite differences", arguments: [48_000.0, 0])
    func derivatives(baseRate: Double) {
        let fitter = makeFitter(for: [], baseRate: baseRate, maxBands: 1)
        for type in [AutoEQFilter.FilterType.peaking, .lowShelf, .highShelf] {
            let band = AutoEQFitBand(type: type, logFrequency: log(2500), gainDB: 5.5, bandwidth: AutoEQFitBand.bandwidth(q: 1.7))
            let analytic = fitter.bandResponse(band).derivatives
            for parameter in 0..<3 {
                let h = 1e-6
                var plus = band, minus = band
                switch parameter {
                case 0: plus.logFrequency += h; minus.logFrequency -= h
                case 1: plus.gainDB += h; minus.gainDB -= h
                default: plus.bandwidth += h; minus.bandwidth -= h
                }
                let up = fitter.bandResponse(plus).dB, down = fitter.bandResponse(minus).dB
                for index in fitGrid.indices {
                    let numeric = (up[index] - down[index]) / (2 * h)
                    #expect(abs(numeric - analytic[parameter][index]) < 1e-5 * (1 + abs(numeric)),
                            "\(type) parameter \(parameter) at \(fitGrid[index]) Hz")
                }
            }
        }
    }

    @Test("Bandwidth and Q convert both ways")
    func bandwidthAndQ() {
        for q in [0.18, 0.5, 0.71, 1.41, 4, 30] {
            #expect(abs(AutoEQFitBand.q(bandwidth: AutoEQFitBand.bandwidth(q: q)) - q) < 1e-12 * max(q, 1))
        }
        // Q = √2 is one octave wide
        #expect(abs(AutoEQFitBand.bandwidth(q: 2.0.squareRoot()) - 1) < 1e-12)
    }
}

@Suite("Curve fitter — fits")
struct AutoEQCurveFitterFitTests {

    @Test("Finds a filter list again from its curve")
    func recoversKnownBands() throws {
        let fitter = makeFitter(for: fiveBands, baseRate: 48_000, maxBands: 16)
        let state = try fitter.fit(bandCount: 5, effort: .quick)
        #expect(state.count == 5)
        #expect(fitter.maxError(of: state).errorDB < 0.01)
        #expect(abs(state.levelDB) < 0.01)
    }

    @Test("An offset of the curve goes into the level")
    func offsetGoesIntoLevel() throws {
        let target = AutoEQResponse.curve(fiveBands, engine: .minimumPhaseFIR, frequencies: fitGrid, baseRate: 48_000)
            .map { $0 + 3 }
        let fitter = AutoEQCurveFitter(
            problem: AutoEQFitProblem(frequencies: fitGrid, target: target, baseRate: 48_000), maxBands: 16)
        let state = try fitter.fit(bandCount: 5, effort: .quick)
        #expect(abs(state.levelDB - 3) < 0.02)
        #expect(fitter.maxError(of: state).errorDB < 0.01)
    }

    @Test("Stays within its limits: max Q, no shelves")
    func limits() throws {
        let target = AutoEQResponse.curve(tenBands, engine: .minimumPhaseFIR, frequencies: fitGrid, baseRate: 44_100)
        let problem = AutoEQFitProblem(
            frequencies: fitGrid, target: target, baseRate: 44_100, qRange: 0.18...3, allowsShelves: false)
        let fitter = AutoEQCurveFitter(problem: problem, maxBands: 19)
        let state = try fitter.fit(bandCount: 6, effort: .quick)
        #expect(state.count == 6)
        for band in state.bands {
            #expect(band.type == .peaking)
            let filter = band.filter
            #expect(filter.q <= 3 + 1e-9 && filter.q >= 0.18 - 1e-9)
            #expect(filter.frequency >= 20 - 1e-6 && filter.frequency <= 20_000 + 1e-6)
            #expect(abs(filter.gainDB) <= 24)
        }
    }

    @Test("Stops when its task is cancelled")
    func cancellation() async {
        let source = preset(tenBands, baseRate: 44_100)
        let options = AutoEQConverter.ParametricOptions(bandCount: 20)
        let task = Task.detached {
            try AutoEQConverter.parametric(from: source, options: options)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("Preset conversions")
struct AutoEQConverterTests {

    @Test("Another base rate: same bands moved, same curve")
    func rebase() throws {
        let source = preset(tenBands, baseRate: 44_100)
        var playedAsIs = source
        playedAsIs.optimizedSampleRate = 48_000
        #expect(AutoEQConverter.accuracy(of: playedAsIs, from: source).maxErrorDB > 0.2)

        let conversion = try AutoEQConverter.rebased(source, to: 48_000)
        #expect(conversion.profile.optimizedSampleRate == 48_000)
        #expect(conversion.profile.filters.map(\.type) == tenBands.map(\.type))
        #expect(conversion.accuracy.maxErrorDB < 0.02)
        #expect(conversion.profile.id == source.id && conversion.profile.name == source.name)
        // The bands moved little: same list, adjusted
        for (old, new) in zip(tenBands, conversion.profile.filters) {
            #expect(abs(log2(new.frequency / old.frequency)) < 0.5)
        }
    }

    @Test("Analog filters from a filter list made at 44.1 kHz")
    func rebaseToAnalog() throws {
        let conversion = try AutoEQConverter.rebased(preset(tenBands, baseRate: 44_100), to: AutoEQBaseRate.analog)
        #expect(conversion.profile.optimizedSampleRate == AutoEQBaseRate.analog)
        #expect(conversion.accuracy.maxErrorDB < 0.06)
    }

    @Test("Parametric to graphic: the curve sampled, closer with more points")
    func toGraphic() {
        let source = preset(tenBands, baseRate: 44_100)
        let coarse = AutoEQConverter.graphic(from: source, pointCount: 127)
        let fine = AutoEQConverter.graphic(from: source, pointCount: 1024)
        #expect(fine.profile.kind == .graphic)
        #expect(fine.profile.filters.isEmpty)
        #expect(fine.profile.curve.count == 1024)
        #expect(fine.profile.preampDB == source.preampDB)
        // A graphic preset has no biquad engine
        #expect(fine.profile.engine == .minimumPhaseFIR)
        #expect(fine.accuracy.maxErrorDB < 0.02)
        #expect(coarse.accuracy.maxErrorDB > fine.accuracy.maxErrorDB)
        #expect(coarse.accuracy.maxErrorDB < 0.5)
    }

    @Test("Graphic to parametric: bands fitted to the curve, level in the preamp")
    func toParametric() throws {
        let graphic = AutoEQConverter.graphic(from: preset(fiveBands, baseRate: 48_000, preamp: -4), pointCount: 1024).profile
        var options = AutoEQConverter.ParametricOptions(bandCount: 5, baseRate: 48_000)
        options.effort = .quick
        let conversion = try AutoEQConverter.parametric(from: graphic, options: options)
        let profile = conversion.profile
        #expect(profile.kind == .parametric)
        #expect(profile.curve.isEmpty)
        #expect(profile.filters.count == 5)
        #expect(profile.optimizedSampleRate == 48_000)
        #expect(profile.filters.map(\.frequency) == profile.filters.map(\.frequency).sorted())
        #expect(conversion.accuracy.maxErrorDB < 0.05)
        #expect(abs(profile.preampDB - -4) < 0.05)
    }

    @Test("The fewest bands within a tolerance")
    func fewestBands() throws {
        let threeBands = [
            AutoEQFilter(type: .peaking, frequency: 200, gainDB: -4, q: 1),
            AutoEQFilter(type: .peaking, frequency: 2500, gainDB: 3, q: 2),
            AutoEQFilter(type: .highShelf, frequency: 9000, gainDB: -4, q: 0.8),
        ]
        var options = AutoEQConverter.ParametricOptions(bandCount: 8, toleranceDB: 0.1, baseRate: 48_000)
        options.effort = .quick
        let conversion = try AutoEQConverter.parametric(from: preset(threeBands, baseRate: 48_000), options: options)
        #expect(conversion.profile.filters.count <= 4)
        #expect(conversion.accuracy.maxErrorDB < 0.15)
    }
}
