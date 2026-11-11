// FineTune/Audio/AutoEQ/AutoEQResponse.swift
import Foundation

/// Frequency response of an AutoEQ preset, for the EQ Manager graph and preamp advice.
///
/// `.biquad` and `.matchedBiquad` evaluate the digital biquad cascade the engine runs at
/// `sampleRate`. The FIR engines evaluate the exact curve, which is what they reproduce: for
/// a filter list, the curve of its cookbook biquads at the preset's base rate (or of their
/// analog prototypes, see `AutoEQBaseRate`); for a graphic preset, its interpolated curve.
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
        sampleRate: Double = defaultSampleRate,
        baseRate: Double? = nil
    ) -> [Double] {
        var total = [Double](repeating: 0, count: frequencies.count)
        for filter in filters {
            let response = curve(
                of: filter, engine: engine, frequencies: frequencies, sampleRate: sampleRate, baseRate: baseRate)
            for i in total.indices { total[i] += response[i] }
        }
        return total
    }

    /// Gain in dB of a single filter at each frequency, for a filter list made for `baseRate`
    /// (nil: analog filters).
    static func curve(
        of filter: AutoEQFilter,
        engine: AutoEQCorrectionEngine,
        frequencies: [Double],
        sampleRate: Double = defaultSampleRate,
        baseRate: Double? = nil
    ) -> [Double] {
        switch engine {
        case .biquad, .matchedBiquad:
            // The coefficients the processor computes
            let c = BiquadMath.coefficientsForAutoEQFilters(
                [filter], sampleRate: sampleRate, profileOptimizedRate: baseRate ?? AutoEQBaseRate.analog,
                exact: engine == .matchedBiquad)
            return frequencies.map { digitalDB(c, at: $0, sampleRate: sampleRate) }
        case .minimumPhaseFIR, .linearPhaseFIR:
            return frequencies.map { intendedDB(filter, at: $0, baseRate: baseRate) }
        }
    }

    /// Gain in dB of the whole preset at each frequency as its engine renders it (preamp excluded).
    static func curve(of profile: AutoEQProfile, frequencies: [Double], sampleRate: Double = defaultSampleRate) -> [Double] {
        switch profile.kind {
        case .parametric:
            return curve(
                profile.filters, engine: profile.effectiveEngine, frequencies: frequencies,
                sampleRate: sampleRate, baseRate: profile.designBaseRate)
        case .graphic:
            return graphicCurve(profile.curve, frequencies: frequencies)
        }
    }

    /// The exact curve of the preset, whatever its engine: what the FIR engines aim for.
    static func exactCurve(of profile: AutoEQProfile, frequencies: [Double]) -> [Double] {
        switch profile.kind {
        case .parametric:
            return curve(profile.filters, engine: .minimumPhaseFIR, frequencies: frequencies, baseRate: profile.designBaseRate)
        case .graphic:
            return graphicCurve(profile.curve, frequencies: frequencies)
        }
    }

    /// A graphic preset's curve at each frequency: straight lines between its points on a
    /// log-frequency axis, flat beyond the first and last point. `points` sorted by frequency.
    static func graphicCurve(_ points: [AutoEQCurvePoint], frequencies: [Double]) -> [Double] {
        guard let first = points.first, let last = points.last else {
            return [Double](repeating: 0, count: frequencies.count)
        }
        return frequencies.map { frequency in
            if frequency <= first.frequency { return Double(first.gainDB) }
            if frequency >= last.frequency { return Double(last.gainDB) }
            // First point above the frequency (binary search)
            var low = 0, high = points.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if points[middle].frequency <= frequency { low = middle } else { high = middle }
            }
            let a = points[low], b = points[high]
            let span = log(b.frequency / a.frequency)
            guard span > 0 else { return Double(a.gainDB) }
            let t = log(frequency / a.frequency) / span
            return Double(a.gainDB) + (Double(b.gainDB) - Double(a.gainDB)) * t
        }
    }

    /// The exact curve sampled for FIR design: gain in dB at `k * sampleRate / gridSize` for
    /// k = 0...gridSize/2. Evaluated on 4096 log-spaced frequencies and interpolated, which is
    /// exact enough for any band (Q ≤ 30) and much cheaper than one evaluation per bin.
    static func designGrid(of profile: AutoEQProfile, sampleRate: Double, gridSize: Int) -> [Double] {
        let nyquist = sampleRate / 2
        let coarseCount = 4096
        let low = 1.0
        let coarse = logFrequencies(count: coarseCount, from: low, to: nyquist)
        let values = exactCurve(of: profile, frequencies: coarse)
        let step = log(nyquist / low) / Double(coarseCount - 1)

        let bins = gridSize / 2 + 1
        var grid = [Double](repeating: values[0], count: bins)
        let binWidth = sampleRate / Double(gridSize)
        for k in 0..<bins {
            let frequency = Double(k) * binWidth
            guard frequency > low else { continue }
            let position = log(frequency / low) / step
            let index = min(Int(position), coarseCount - 2)
            let t = min(position - Double(index), 1)
            grid[k] = values[index] + (values[index + 1] - values[index]) * t
        }
        return grid
    }

    /// Highest gain of the curve between 10 Hz and 20 kHz, or nil when there is nothing to measure.
    static func peakDB(_ profile: AutoEQProfile, sampleRate: Double = defaultSampleRate) -> Double? {
        guard profile.hasCorrection else { return nil }
        // A dense grid plus every band's centre (or curve point), so narrow peaks are not missed.
        var frequencies = logFrequencies(count: 1024, from: 10, to: maxFrequency)
        switch profile.kind {
        case .parametric:
            frequencies += profile.filters.map(\.frequency).filter { $0 >= 10 && $0 <= maxFrequency }
        case .graphic:
            frequencies += profile.curve.map(\.frequency).filter { $0 >= 10 && $0 <= maxFrequency }
        }
        return curve(of: profile, frequencies: frequencies, sampleRate: sampleRate).max()
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

    /// |H(e^jw)| in dB for vDSP-style coefficients [b0, b1, b2, a1, a2].
    private static func digitalDB(_ c: [Double], at frequency: Double, sampleRate: Double) -> Double {
        10 * log10(max(BiquadMath.digitalMagnitudeSquared(c, at: frequency, sampleRate: sampleRate), 1e-20))
    }

    // MARK: - Exact curve

    /// Gain in dB of a band's exact curve: its cookbook biquad at `baseRate`, or its RBJ analog
    /// prototype when `baseRate` is nil.
    private static func intendedDB(_ filter: AutoEQFilter, at frequency: Double, baseRate: Double?) -> Double {
        let magnitude2 = BiquadMath.intendedMagnitudeSquared(
            type: filter.type, centerFrequency: filter.frequency, gainDB: Double(filter.gainDB), q: filter.q,
            at: frequency, baseRate: baseRate)
        return 10 * log10(max(magnitude2, 1e-20))
    }
}
