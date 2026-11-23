// FineTune/Audio/AutoEQ/AutoEQConverter.swift
import Foundation

/// Makes a preset in another form from a preset, for the EQ Manager's Convert menu:
///
/// - **parametric to graphic**: the exact curve sampled on a log grid;
/// - **graphic or parametric to parametric**: bands fitted to the exact curve
///   (`AutoEQCurveFitter`), with a chosen number of bands, or the fewest within a tolerance;
/// - **to another base rate**: the same bands, moved so that their cookbook biquads at the new
///   rate (or their analog prototypes) give the curve they had at the old one. For a filter
///   list played or exported where the original rate is not known.
///
/// A conversion returns a new profile and never changes its source. The caller stores it as a
/// new preset. Each conversion reports how far its result is from the source (`Accuracy`).
/// The fitting conversions take a second or more: run them off the main thread; they stop with
/// `CancellationError` when their task is cancelled.
nonisolated enum AutoEQConverter {
    /// Largest difference between the exact curves of the source and of the result, preamp
    /// included, from 20 Hz to 20 kHz, and its frequency.
    struct Accuracy: Equatable, Sendable {
        let maxErrorDB: Double
        let frequency: Double
    }

    struct Conversion: Sendable {
        let profile: AutoEQProfile
        let accuracy: Accuracy
    }

    struct ParametricOptions: Equatable, Sendable {
        /// Number of bands, or the most bands when `toleranceDB` is set.
        var bandCount = 10
        /// When set: the fewest bands (up to `bandCount`) whose curve stays within this error.
        var toleranceDB: Double?
        var maxQ = 10.0
        var allowsShelves = true
        /// Base rate of the new filter list, 0 for analog filters (see `AutoEQBaseRate`).
        var baseRate = AutoEQBaseRate.autoEQDefault
        var effort = AutoEQCurveFitter.Effort.standard
    }

    static let graphicPointCounts = [127, 256, 512, 1024]
    static let maxBandCount = 32
    static let maxQChoices: [Double] = [3, 5, 7, 10, 15, 20, 30]
    static let toleranceChoices: [Double] = [0.05, 0.1, 0.2, 0.5, 1]
    /// Lowest Q of fitted bands (about 5.7 octaves).
    static let minFittedQ = 0.18

    private static let accuracyGridCount = 2048
    private static let fitGridCount = 384
    private static let rebaseGridCount = 1024

    // MARK: - Conversions

    /// The exact curve of `source` (as the FIR engines render it) as a graphic preset of
    /// `pointCount` points from 20 Hz to 20 kHz. Fast enough for the main thread.
    static func graphic(from source: AutoEQProfile, pointCount: Int) -> Conversion {
        let count = min(max(pointCount, 2), AutoEQProfile.maxCurvePoints)
        let frequencies = AutoEQResponse.logFrequencies(count: count)
        let gains = AutoEQResponse.exactCurve(of: source, frequencies: frequencies)
        var profile = source
        profile.kind = .graphic
        profile.filters = []
        profile.curve = zip(frequencies, gains).map { frequency, gain in
            AutoEQCurvePoint(frequency: (frequency * 100).rounded() / 100, gainDB: Float(gain))
        }
        profile.engine = compatibleEngine(source.engine, for: .graphic)
        return Conversion(profile: profile, accuracy: accuracy(of: profile, from: source))
    }

    /// Bands fitted to the exact curve of `source`, a graphic or parametric preset. The overall
    /// level of the fit goes into the preamp.
    static func parametric(
        from source: AutoEQProfile, options: ParametricOptions,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Conversion {
        let frequencies = AutoEQResponse.logFrequencies(count: fitGridCount)
        let target = AutoEQResponse.exactCurve(of: source, frequencies: frequencies)
        let maxQ = min(max(options.maxQ, 0.5), AutoEQFilter.qRange.upperBound)
        let problem = AutoEQFitProblem(
            frequencies: frequencies, target: target, baseRate: options.baseRate > 0 ? options.baseRate : nil,
            frequencyRange: AutoEQResponse.minFrequency...AutoEQResponse.maxFrequency,
            qRange: minFittedQ...maxQ, allowsShelves: options.allowsShelves)
        let bandCount = min(max(options.bandCount, 1), maxBandCount)
        let fitter = AutoEQCurveFitter(problem: problem, maxBands: 3 * bandCount + 1)
        fitter.progress = progress
        let state: AutoEQFitState
        if let tolerance = options.toleranceDB {
            state = try fitter.fitFewestBands(toleranceDB: tolerance, maxBands: bandCount, effort: options.effort)
        } else {
            state = try fitter.fit(bandCount: bandCount, effort: options.effort)
        }
        var profile = source
        profile.kind = .parametric
        profile.curve = []
        profile.filters = state.bands.map(\.filter).sorted { $0.frequency < $1.frequency }
        profile.preampDB = Float(Double(source.preampDB) + state.levelDB)
        profile.optimizedSampleRate = options.baseRate
        profile.engine = compatibleEngine(source.engine, for: .parametric)
        return Conversion(profile: profile, accuracy: accuracy(of: profile, from: source))
    }

    /// The bands of a parametric preset moved to `baseRate` (0: analog filters), starting from
    /// the bands themselves. Same number of bands, in the same order; the level goes into the
    /// preamp.
    static func rebased(
        _ source: AutoEQProfile, to baseRate: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Conversion {
        var profile = source
        profile.optimizedSampleRate = baseRate
        let filters = source.filters
        guard source.kind == .parametric, !filters.isEmpty else {
            return Conversion(profile: profile, accuracy: accuracy(of: profile, from: source))
        }
        let frequencies = AutoEQResponse.logFrequencies(count: rebaseGridCount)
        let target = AutoEQResponse.exactCurve(of: source, frequencies: frequencies)
        // Limits that hold every band of the source, so that the fit starts from the source
        let frequencyValues = filters.map(\.frequency)
        let qValues = filters.map(\.q)
        let lowest = min(AutoEQFilter.frequencyRange.lowerBound, frequencyValues.min() ?? 20)
        let highest = max(AutoEQFilter.frequencyRange.upperBound, frequencyValues.max() ?? 20_000)
        let qRange = min(AutoEQFilter.qRange.lowerBound, qValues.min() ?? 1)...max(AutoEQFilter.qRange.upperBound, qValues.max() ?? 1)
        let largestGain = filters.map { abs(Double($0.gainDB)) }.max() ?? 0
        let problem = AutoEQFitProblem(
            frequencies: frequencies, target: target, baseRate: baseRate > 0 ? baseRate : nil,
            frequencyRange: lowest...highest, qRange: qRange,
            maxGainDB: max(Double(AutoEQFilter.gainRange.upperBound), largestGain))
        let fitter = AutoEQCurveFitter(problem: problem, maxBands: filters.count)
        fitter.progress = progress
        let start = AutoEQFitState(bands: filters.map { AutoEQFitBand($0) }, levelDB: 0)
        let state = try fitter.refine(start)
        profile.filters = state.bands.map(\.filter)
        profile.preampDB = Float(Double(source.preampDB) + state.levelDB)
        return Conversion(profile: profile, accuracy: accuracy(of: profile, from: source))
    }

    // MARK: - Accuracy

    /// How far the exact curve of `converted` is from that of `source`, preamps included.
    static func accuracy(of converted: AutoEQProfile, from source: AutoEQProfile) -> Accuracy {
        let frequencies = AutoEQResponse.logFrequencies(count: accuracyGridCount)
        let reference = AutoEQResponse.exactCurve(of: source, frequencies: frequencies)
        let result = AutoEQResponse.exactCurve(of: converted, frequencies: frequencies)
        let offset = Double(converted.preampDB) - Double(source.preampDB)
        var worst = 0.0
        var worstFrequency = frequencies[0]
        for index in frequencies.indices {
            let error = abs(result[index] + offset - reference[index])
            if error > worst {
                worst = error
                worstFrequency = frequencies[index]
            }
        }
        return Accuracy(maxErrorDB: worst, frequency: worstFrequency)
    }

    /// The source's engine when it can render the new kind, else the minimum-phase FIR.
    private static func compatibleEngine(
        _ engine: AutoEQCorrectionEngine, for kind: AutoEQPresetKind
    ) -> AutoEQCorrectionEngine {
        AutoEQCorrectionEngine.available(for: kind).contains(engine) ? engine : .minimumPhaseFIR
    }
}
