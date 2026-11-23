// FineTune/Audio/AutoEQ/Fitting/AutoEQFitProblem.swift
import Foundation

/// A band as the fitter sees it.
///
/// The fitter moves ln(frequency), the gain in dB and the bandwidth in octaves rather than the
/// frequency and Q: the error of the curve changes much more evenly with these, which keeps the
/// problem well conditioned. This parameterisation, and the fit of all bands together against
/// the error of the whole cascade, follow the AutoEQ optimiser of PEQdB (autoeq.c,
/// LGPL-3.0-or-later, © PEQdB Inc.).
nonisolated struct AutoEQFitBand: Equatable, Sendable {
    var type: AutoEQFilter.FilterType
    /// ln of the centre frequency in Hz.
    var logFrequency: Double
    var gainDB: Double
    /// Bandwidth in octaves (see `q(bandwidth:)`).
    var bandwidth: Double

    init(type: AutoEQFilter.FilterType, logFrequency: Double, gainDB: Double, bandwidth: Double) {
        self.type = type
        self.logFrequency = logFrequency
        self.gainDB = gainDB
        self.bandwidth = bandwidth
    }

    init(_ filter: AutoEQFilter) {
        self.init(
            type: filter.type, logFrequency: log(filter.frequency), gainDB: Double(filter.gainDB),
            bandwidth: Self.bandwidth(q: filter.q))
    }

    var filter: AutoEQFilter {
        AutoEQFilter(type: type, frequency: exp(logFrequency), gainDB: Float(gainDB), q: Self.q(bandwidth: bandwidth))
    }

    /// Q of a band `bandwidth` octaves wide (RBJ cookbook definition, as for AutoEQ).
    static func q(bandwidth: Double) -> Double {
        0.5 / sinh(0.5 * M_LN2 * bandwidth)
    }

    static func bandwidth(q: Double) -> Double {
        2 / M_LN2 * asinh(0.5 / q)
    }
}

/// Bands and overall level being fitted: the curve is `levelDB` plus the sum of the bands in dB.
nonisolated struct AutoEQFitState: Equatable, Sendable {
    var types: [AutoEQFilter.FilterType]
    /// Three per band: ln(frequency), gain in dB, bandwidth in octaves.
    var parameters: [Double]
    var levelDB: Double

    init(bands: [AutoEQFitBand] = [], levelDB: Double = 0) {
        types = bands.map(\.type)
        parameters = []
        parameters.reserveCapacity(bands.count * 3)
        for band in bands {
            parameters.append(band.logFrequency)
            parameters.append(band.gainDB)
            parameters.append(band.bandwidth)
        }
        self.levelDB = levelDB
    }

    var count: Int { types.count }

    var bands: [AutoEQFitBand] {
        types.indices.map { index in
            AutoEQFitBand(
                type: types[index], logFrequency: parameters[3 * index], gainDB: parameters[3 * index + 1],
                bandwidth: parameters[3 * index + 2])
        }
    }

    mutating func append(_ band: AutoEQFitBand) {
        types.append(band.type)
        parameters.append(band.logFrequency)
        parameters.append(band.gainDB)
        parameters.append(band.bandwidth)
    }

    mutating func remove(at index: Int) {
        types.remove(at: index)
        parameters.removeSubrange((3 * index)..<(3 * index + 3))
    }
}

/// What a fit aims for: a curve in dB on a frequency grid, and the limits of the bands.
nonisolated struct AutoEQFitProblem: Sendable {
    /// Grid frequencies in Hz, rising (a log-spaced grid works best).
    let frequencies: [Double]
    /// Curve to follow at each grid frequency, in dB.
    let target: [Double]
    /// Rate the bands are designed for (their cookbook biquads at that rate, see
    /// `BiquadMath.intendedMagnitudeSquared`), or nil for the analog prototypes.
    let baseRate: Double?
    let frequencyRange: ClosedRange<Double>
    let qRange: ClosedRange<Double>
    let maxGainDB: Double
    /// Whether the fit may use low and high shelves, or only peaking bands.
    let allowsShelves: Bool

    init(
        frequencies: [Double], target: [Double], baseRate: Double?,
        frequencyRange: ClosedRange<Double> = 20...20_000, qRange: ClosedRange<Double> = 0.18...10,
        maxGainDB: Double = Double(AutoEQFilter.gainRange.upperBound), allowsShelves: Bool = true
    ) {
        precondition(frequencies.count == target.count && frequencies.count >= 8, "A fit needs a curve on a grid")
        self.frequencies = frequencies
        self.target = target
        self.baseRate = baseRate.flatMap { $0 > 0 ? $0 : nil }
        self.frequencyRange = frequencyRange
        self.qRange = qRange
        self.maxGainDB = maxGainDB
        self.allowsShelves = allowsShelves
    }

    /// Lowest and highest ln(frequency) of a band. A band must stay below the base rate's
    /// Nyquist frequency, where its cookbook biquad stops existing.
    var logFrequencyBounds: (low: Double, high: Double) {
        var high = frequencyRange.upperBound
        if let baseRate { high = min(high, 0.49 * baseRate) }
        let low = min(frequencyRange.lowerBound, high)
        return (log(low), log(high))
    }

    /// Narrowest and widest bandwidth in octaves (from the highest and lowest Q).
    var bandwidthBounds: (low: Double, high: Double) {
        (AutoEQFitBand.bandwidth(q: qRange.upperBound), AutoEQFitBand.bandwidth(q: qRange.lowerBound))
    }

    /// The band types the fit may use.
    var allowedTypes: [AutoEQFilter.FilterType] {
        allowsShelves ? [.peaking, .lowShelf, .highShelf] : [.peaking]
    }
}
