// FineTune/Audio/AutoEQ/AutoEQResponse.swift
import Foundation

/// Frequency response of an AutoEQ preset, for the EQ Manager graph and preamp advice.
///
/// `.biquad` evaluates the digital biquad cascade the engine runs (RBJ cookbook) at `sampleRate`.
/// `.exactFIR` evaluates the analog prototype curve, which is what an exact FIR reproduces.
/// The preamp recommendation (rendered peak plus a safety margin) follows the approach of
/// GlassEQ's `EQProfileAnalysis.recommendedPreampDB` (GPL v3, Juho Koskela).
enum AutoEQResponse {
    static let minFrequency = 20.0
    static let maxFrequency = 20_000.0
    static let defaultSampleRate = 48_000.0
    /// Margin the recommended preamp keeps below the input level at the curve's peak.
    static let recommendedHeadroomDB = 0.2

    /// `count` frequencies spaced evenly on a log scale.
    static func logFrequencies(count: Int, from low: Double = minFrequency, to high: Double = maxFrequency) -> [Double] {
        guard count > 1 else { return [low] }
        let lo = log10(low), hi = log10(high)
        return (0..<count).map { pow(10, lo + (hi - lo) * Double($0) / Double(count - 1)) }
    }

    /// Summed gain in dB of `filters` at each frequency (preamp excluded).
    static func curve(
        _ filters: [AutoEQFilter],
        engine: AutoEQCorrectionEngine,
        frequencies: [Double],
        sampleRate: Double = defaultSampleRate
    ) -> [Double] {
        var total = [Double](repeating: 0, count: frequencies.count)
        for filter in filters {
            let response = curve(of: filter, engine: engine, frequencies: frequencies, sampleRate: sampleRate)
            for i in total.indices { total[i] += response[i] }
        }
        return total
    }

    /// Gain in dB of a single filter at each frequency.
    static func curve(
        of filter: AutoEQFilter,
        engine: AutoEQCorrectionEngine,
        frequencies: [Double],
        sampleRate: Double = defaultSampleRate
    ) -> [Double] {
        switch engine {
        case .biquad:
            let c = coefficients(filter, sampleRate: sampleRate)
            return frequencies.map { digitalDB(c, at: $0, sampleRate: sampleRate) }
        case .exactFIR:
            return frequencies.map { analogDB(filter, at: $0) }
        }
    }

    /// Highest gain of the curve between 10 Hz and 20 kHz, or nil when there is nothing to measure.
    static func peakDB(_ profile: AutoEQProfile, sampleRate: Double = defaultSampleRate) -> Double? {
        guard profile.kind == .parametric, !profile.filters.isEmpty else { return nil }
        // A dense grid plus every band's centre, so narrow peaks are not missed.
        var frequencies = logFrequencies(count: 1024, from: 10, to: maxFrequency)
        frequencies += profile.filters.map(\.frequency).filter { $0 >= 10 && $0 <= maxFrequency }
        return curve(profile.filters, engine: profile.engine, frequencies: frequencies, sampleRate: sampleRate).max()
    }

    /// Preamp that keeps the curve's peak `recommendedHeadroomDB` below the input level.
    /// Never positive: a curve that only cuts gets 0 dB.
    static func recommendedPreampDB(_ profile: AutoEQProfile) -> Double? {
        guard let peak = peakDB(profile) else { return nil }
        let attenuation = max(peak + recommendedHeadroomDB, 0)
        guard attenuation > 0 else { return 0 }
        return -((attenuation * 10).rounded(.up) / 10)
    }

    // MARK: - Biquad (digital)

    private static func coefficients(_ filter: AutoEQFilter, sampleRate: Double) -> [Double] {
        switch filter.type {
        case .peaking:
            return BiquadMath.peakingEQCoefficients(frequency: filter.frequency, gainDB: filter.gainDB, q: filter.q, sampleRate: sampleRate)
        case .lowShelf:
            return BiquadMath.lowShelfCoefficients(frequency: filter.frequency, gainDB: filter.gainDB, q: filter.q, sampleRate: sampleRate)
        case .highShelf:
            return BiquadMath.highShelfCoefficients(frequency: filter.frequency, gainDB: filter.gainDB, q: filter.q, sampleRate: sampleRate)
        }
    }

    /// |H(e^jw)| in dB for vDSP-style coefficients [b0, b1, b2, a1, a2].
    private static func digitalDB(_ c: [Double], at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w), cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = c[0] + c[1] * cos1 + c[2] * cos2
        let numIm = -(c[1] * sin1 + c[2] * sin2)
        let denRe = 1 + c[3] * cos1 + c[4] * cos2
        let denIm = -(c[3] * sin1 + c[4] * sin2)
        let magnitude2 = (numRe * numRe + numIm * numIm) / max(denRe * denRe + denIm * denIm, 1e-30)
        return 10 * log10(max(magnitude2, 1e-20))
    }

    // MARK: - Analog prototype (exact curve)

    /// |H(jW)| in dB of the RBJ analog prototypes, with W = f / f0.
    private static func analogDB(_ filter: AutoEQFilter, at frequency: Double) -> Double {
        let a = pow(10, Double(filter.gainDB) / 40)
        let w = frequency / max(filter.frequency, 1e-6)
        let w2 = w * w
        let q = max(filter.q, 1e-6)
        let magnitude2: Double
        switch filter.type {
        case .peaking:
            let re = 1 - w2
            let numIm = w * a / q
            let denIm = w / (a * q)
            magnitude2 = (re * re + numIm * numIm) / (re * re + denIm * denIm)
        case .lowShelf:
            let im = sqrt(a) / q * w
            let numRe = a - w2, denRe = 1 - a * w2
            magnitude2 = a * a * (numRe * numRe + im * im) / max(denRe * denRe + im * im, 1e-30)
        case .highShelf:
            let im = sqrt(a) / q * w
            let numRe = 1 - a * w2, denRe = a - w2
            magnitude2 = a * a * (numRe * numRe + im * im) / max(denRe * denRe + im * im, 1e-30)
        }
        return 10 * log10(max(magnitude2, 1e-20))
    }
}
