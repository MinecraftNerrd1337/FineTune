// FineTune/Audio/EQ/BiquadMath+Matched.swift
import Foundation

/// Biquads fitted to the exact curve of an EQ band.
///
/// The exact curve of a band depends on what its parameters were chosen for:
///
/// - with a base sample rate (`baseRate`), the curve of the RBJ cookbook biquad at that rate.
///   This is how AutoEQ and most parametric EQ tools optimise a filter list, so the frequency
///   cramping near the base rate's Nyquist frequency is part of the curve they intended;
/// - without one (`baseRate == nil`), the RBJ analog prototype.
///
/// At the base rate itself the cookbook biquad is exact by definition. The cookbook biquads of `BiquadMath` come from the bilinear transform, which squeezes the
/// whole analog frequency axis below the Nyquist frequency: a band near the top of the
/// spectrum comes out narrower and its shelf steeper than drawn (several dB off for a band at
/// 10 kHz and above at 44.1 or 48 kHz). The design here keeps what makes a biquad cheap and
/// free of latency, and removes most of that error:
///
/// - the poles are the analog poles mapped by z = exp(s·T) (impulse invariance), as in
///   M. Vicanek, "Matched Second Order Digital Filters" (2016). With a base rate, the poles of
///   the cookbook biquad at the base rate are mapped the same way (z' = z^(base / rate)), so
///   the resonance keeps its frequency and damping in seconds;
/// - the numerator is the one whose magnitude best fits the exact curve from 10 Hz to
///   Nyquist, in the least-squares sense. The squared magnitude of a biquad numerator is
///   linear in three unknowns, so this is a 3×3 linear system;
/// - a cut is designed as the inverse of the matching boost, as its analog prototype is;
/// - with a base rate, the base-rate biquad with both its poles and zeros moved is tried too,
///   which follows a curve that falls steeply near the base rate's Nyquist frequency better.
///
/// The fit is measured against the cookbook biquad on a frequency grid and only used where it
/// is closer to the exact curve, so the result is never worse than the cookbook one.
extension BiquadMath {

    /// Squared magnitude of the RBJ analog prototype of a band at `frequency` Hz.
    static func analogMagnitudeSquared(
        type: AutoEQFilter.FilterType, centerFrequency: Double, gainDB: Double, q: Double, at frequency: Double
    ) -> Double {
        let a = pow(10, gainDB / 40)
        let w = frequency / max(centerFrequency, 1e-6)
        let w2 = w * w
        let q = max(q, 1e-6)
        switch type {
        case .peaking:
            let re = 1 - w2
            let numIm = w * a / q
            let denIm = w / (a * q)
            return (re * re + numIm * numIm) / max(re * re + denIm * denIm, 1e-30)
        case .lowShelf:
            let im = sqrt(a) / q * w
            let numRe = a - w2, denRe = 1 - a * w2
            return a * a * (numRe * numRe + im * im) / max(denRe * denRe + im * im, 1e-30)
        case .highShelf:
            let im = sqrt(a) / q * w
            let numRe = 1 - a * w2, denRe = a - w2
            return a * a * (numRe * numRe + im * im) / max(denRe * denRe + im * im, 1e-30)
        }
    }

    /// Squared magnitude of the exact curve of a band at `frequency` Hz: the cookbook biquad at
    /// `baseRate`, or the analog prototype when `baseRate` is nil. Above the base rate's Nyquist
    /// frequency the curve stays at its value there. A band at or above that Nyquist frequency
    /// does not exist at the base rate (the cookbook bypasses it): its curve is flat.
    static func intendedMagnitudeSquared(
        type: AutoEQFilter.FilterType, centerFrequency: Double, gainDB: Double, q: Double,
        at frequency: Double, baseRate: Double?
    ) -> Double {
        guard let baseRate, baseRate > 0 else {
            return analogMagnitudeSquared(type: type, centerFrequency: centerFrequency, gainDB: gainDB, q: q, at: frequency)
        }
        guard centerFrequency > 0, centerFrequency < baseRate / 2 else { return 1 }
        // The cookbook biquad is the bilinear transform of the analog prototype, pre-warped at
        // the centre frequency: its response at f is the prototype's at tan(πf/fs) / tan(πf0/fs)
        let clamped = min(max(frequency, 0), 0.499_99 * baseRate)
        return analogMagnitudeSquared(
            type: type, centerFrequency: tan(Double.pi * centerFrequency / baseRate), gainDB: gainDB, q: q,
            at: tan(Double.pi * clamped / baseRate))
    }

    /// Squared magnitude of a biquad [b0, b1, b2, a1, a2] at `frequency` Hz.
    static func digitalMagnitudeSquared(_ c: [Double], at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w), cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = c[0] + c[1] * cos1 + c[2] * cos2
        let numIm = -(c[1] * sin1 + c[2] * sin2)
        let denRe = 1 + c[3] * cos1 + c[4] * cos2
        let denIm = -(c[3] * sin1 + c[4] * sin2)
        return (numRe * numRe + numIm * numIm) / max(denRe * denRe + denIm * denIm, 1e-30)
    }

    /// Biquad closest to the exact curve of the band (see `intendedMagnitudeSquared`): the
    /// matched design where it beats the cookbook one, the cookbook one otherwise (pre-warped
    /// from the base rate; unity for a band at or above Nyquist). At the base rate itself, the
    /// cookbook biquad. Returns [b0, b1, b2, a1, a2] for vDSP_biquad.
    static func exactCoefficients(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Float, q: Double, sampleRate: Double,
        baseRate: Double? = nil
    ) -> [Double] {
        let baseRate = baseRate.flatMap { $0 > 0 ? $0 : nil }
        var cookbookFrequency = frequency
        if let baseRate, abs(baseRate - sampleRate) > 1, frequency > 0 {
            // Above the base rate's Nyquist frequency the band does not exist (nor its warp)
            cookbookFrequency = frequency < baseRate / 2
                ? preWarpFrequency(frequency, from: baseRate, to: sampleRate) : -1
        }
        let cookbook: [Double]
        if cookbookFrequency <= 0 || cookbookFrequency >= sampleRate / 2 {
            cookbook = [1, 0, 0, 0, 0]
        } else {
            switch type {
            case .peaking:
                cookbook = peakingEQCoefficients(frequency: cookbookFrequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
            case .lowShelf:
                cookbook = lowShelfCoefficients(frequency: cookbookFrequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
            case .highShelf:
                cookbook = highShelfCoefficients(frequency: cookbookFrequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
            }
        }
        // At the base rate the cookbook biquad is the curve the filter list was made with
        if let baseRate, abs(baseRate - sampleRate) <= 1 { return cookbook }

        var candidates: [[Double]] = []
        if frequency > 0, q > 0, let matched = matchedCoefficients(
            type: type, frequency: frequency, gainDB: Double(gainDB), q: q, sampleRate: sampleRate, baseRate: baseRate) {
            candidates.append(matched)
        }
        if let baseRate {
            // The base-rate biquad with its poles and zeros moved to this rate: closer than the
            // fit where the curve falls steeply near the base rate's Nyquist frequency
            if let moved = movedCookbook(
                type: type, frequency: frequency, gainDB: Double(gainDB), q: q, sampleRate: sampleRate, baseRate: baseRate) {
                candidates.append(moved)
            }
            // A band that does not fit at this rate (its resonance is above the new Nyquist
            // frequency) can be closer to bypassed than to its pre-warped copy
            candidates.append([1, 0, 0, 0, 0])
        }
        guard !candidates.isEmpty else { return cookbook }
        var best = cookbook
        var bestError = maxErrorDB(
            cookbook, type: type, frequency: frequency, gainDB: Double(gainDB), q: q, sampleRate: sampleRate, baseRate: baseRate)
        for candidate in candidates {
            let error = maxErrorDB(
                candidate, type: type, frequency: frequency, gainDB: Double(gainDB), q: q, sampleRate: sampleRate, baseRate: baseRate)
            if error < bestError {
                best = candidate
                bestError = error
            }
        }
        return best
    }

    /// Largest deviation in dB of a biquad from the band's exact curve, on 64 frequencies
    /// from 20 Hz to 20 kHz (or just under Nyquist).
    static func maxErrorDB(
        _ coefficients: [Double], type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double,
        baseRate: Double? = nil
    ) -> Double {
        let top = min(20_000, 0.499 * sampleRate)
        let steps = 64
        var worst = 0.0
        for i in 0..<steps {
            let f = 20 * pow(top / 20, Double(i) / Double(steps - 1))
            let exact = intendedMagnitudeSquared(
                type: type, centerFrequency: frequency, gainDB: gainDB, q: q, at: f, baseRate: baseRate)
            let actual = digitalMagnitudeSquared(coefficients, at: f, sampleRate: sampleRate)
            let deviation = abs(10 * log10(max(actual, 1e-30)) - 10 * log10(max(exact, 1e-30)))
            guard deviation.isFinite else { return .infinity }
            worst = max(worst, deviation)
        }
        return worst
    }

    /// The matched design alone, or nil when it does not exist for these parameters
    /// (ill-conditioned fit, or a cut whose boost has zeros on the unit circle).
    static func matchedCoefficients(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double,
        baseRate: Double? = nil
    ) -> [Double]? {
        let baseRate = baseRate.flatMap { $0 > 0 ? $0 : nil }
        guard gainDB < 0 else {
            return matchedBoost(type: type, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate, baseRate: baseRate)
        }
        // A cut is the inverse of the boost of the same size: swap numerator and denominator,
        // which needs the boost's zeros strictly inside the unit circle
        guard let boost = matchedBoost(
            type: type, frequency: frequency, gainDB: -gainDB, q: q, sampleRate: sampleRate, baseRate: baseRate) else {
            return nil
        }
        let b0 = boost[0]
        guard abs(b0) > 1e-12 else { return nil }
        let z1 = boost[1] / b0, z2 = boost[2] / b0
        guard abs(z2) < 0.9999, abs(z1) < 0.9999 + z2 else { return nil }
        return [1 / b0, boost[3] / b0, boost[4] / b0, z1, z2]
    }

    private static func matchedBoost(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double,
        baseRate: Double?
    ) -> [Double]? {
        let poles: (Double, Double)?
        if let baseRate {
            poles = mappedPoles(type: type, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate, baseRate: baseRate)
        } else {
            poles = analogPoles(type: type, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
        }
        guard let poles else { return nil }
        let (a1, a2) = poles
        guard abs(a2) < 1, abs(a1) < 1 + a2 else { return nil }

        // |D(e^jw)|² = A0·(1 − s) + A1·s + A2·4s(1 − s), with s = sin²(w/2); same form for the numerator
        let bigA0 = (1 + a1 + a2) * (1 + a1 + a2)
        let bigA1 = (1 - a1 + a2) * (1 - a1 + a2)
        let bigA2 = -4 * a2

        // Least squares for the numerator's (B0, B1, B2), each frequency weighted by the
        // inverse of its target so that the error is relative (i.e. in dB)
        let nyquist = sampleRate / 2
        let points = 48
        var n00 = 0.0, n01 = 0.0, n02 = 0.0, n11 = 0.0, n12 = 0.0, n22 = 0.0
        var r0 = 0.0, r1 = 0.0, r2 = 0.0
        for i in 0..<points {
            let f = 10 * pow(nyquist / 10, Double(i) / Double(points - 1))
            let sine = sin(Double.pi * f / sampleRate)
            let s = sine * sine
            let p0 = 1 - s, p1 = s, p2 = 4 * s * (1 - s)
            let denominator = bigA0 * p0 + bigA1 * p1 + bigA2 * p2
            let target = intendedMagnitudeSquared(
                type: type, centerFrequency: frequency, gainDB: gainDB, q: q, at: f, baseRate: baseRate) * denominator
            guard target > 1e-300, target.isFinite else { return nil }
            let m0 = p0 / target, m1 = p1 / target, m2 = p2 / target
            n00 += m0 * m0; n01 += m0 * m1; n02 += m0 * m2
            n11 += m1 * m1; n12 += m1 * m2; n22 += m2 * m2
            r0 += m0; r1 += m1; r2 += m2
        }

        // Solve the symmetric 3×3 system N·B = r (Cramer's rule)
        let determinant = n00 * (n11 * n22 - n12 * n12) - n01 * (n01 * n22 - n12 * n02) + n02 * (n01 * n12 - n11 * n02)
        let scale = max(abs(n00 * n11 * n22), 1e-300)
        guard determinant.isFinite, abs(determinant) > 1e-12 * scale else { return nil }
        let bigB0 = (r0 * (n11 * n22 - n12 * n12) - n01 * (r1 * n22 - n12 * r2) + n02 * (r1 * n12 - n11 * r2)) / determinant
        let bigB1 = (n00 * (r1 * n22 - n12 * r2) - r0 * (n01 * n22 - n12 * n02) + n02 * (n01 * r2 - r1 * n02)) / determinant
        let bigB2 = (n00 * (n11 * r2 - r1 * n12) - n01 * (n01 * r2 - r1 * n02) + r0 * (n01 * n12 - n11 * n02)) / determinant
        guard bigB0 > 0, bigB1 > 0, bigB2.isFinite else { return nil }

        // Back from (B0, B1, B2) to the minimum-phase numerator b0 + b1·z⁻¹ + b2·z⁻²
        let sum = 0.5 * (sqrt(bigB0) + sqrt(bigB1))
        let inner = sum * sum + bigB2
        guard inner >= 0 else { return nil }
        let b0 = 0.5 * (sum + sqrt(inner))
        guard b0 > 1e-12 else { return nil }
        let b1 = 0.5 * (sqrt(bigB0) - sqrt(bigB1))
        let b2 = -bigB2 / (4 * b0)
        return [b0, b1, b2, a1, a2]
    }

    /// Denominator (a1, a2) of a boost: the analog prototype's poles mapped by z = exp(s·T).
    private static func analogPoles(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double
    ) -> (Double, Double)? {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency
        let period = 1 / sampleRate

        // Analog denominator s² + c1·s + c0
        let c1: Double, c0: Double
        switch type {
        case .peaking:
            c1 = w0 / (a * q); c0 = w0 * w0
        case .lowShelf:
            c1 = w0 / (sqrt(a) * q); c0 = w0 * w0 / a
        case .highShelf:
            c1 = w0 * sqrt(a) / q; c0 = w0 * w0 * a
        }

        // Its roots mapped by z = exp(s·T): denominator 1 + a1·z⁻¹ + a2·z⁻²
        let a1: Double, a2: Double
        let discriminant = c1 * c1 / 4 - c0
        if discriminant < 0 {
            a1 = -2 * exp(-c1 * period / 2) * cos(sqrt(-discriminant) * period)
            a2 = exp(-c1 * period)
        } else {
            let root = sqrt(discriminant)
            a1 = -(exp((-c1 / 2 + root) * period) + exp((-c1 / 2 - root) * period))
            a2 = exp(-c1 * period)
        }
        return (a1, a2)
    }

    /// Denominator (a1, a2) of a boost made for `baseRate`: the poles of its cookbook biquad at
    /// the base rate, moved to `sampleRate` by z' = z^(base / rate) so that they keep their
    /// frequency and damping in seconds. Nil when a pole would land at or above the new
    /// Nyquist frequency, or on the negative real axis.
    private static func mappedPoles(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double, baseRate: Double
    ) -> (Double, Double)? {
        guard frequency > 0, frequency < baseRate / 2, q > 0 else { return nil }
        let base: [Double]
        switch type {
        case .peaking:
            base = peakingEQCoefficients(frequency: frequency, gainDB: Float(gainDB), q: q, sampleRate: baseRate)
        case .lowShelf:
            base = lowShelfCoefficients(frequency: frequency, gainDB: Float(gainDB), q: q, sampleRate: baseRate)
        case .highShelf:
            base = highShelfCoefficients(frequency: frequency, gainDB: Float(gainDB), q: q, sampleRate: baseRate)
        }
        return moveRoots(base[3], base[4], ratio: baseRate / sampleRate)
    }

    /// The cookbook biquad at `baseRate` with its poles and its zeros moved to `sampleRate` by
    /// z' = z^(base / rate), and the gain that best fits the exact curve (in dB, on average).
    /// Nil when a root cannot be moved (see `moveRoots`).
    private static func movedCookbook(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double, baseRate: Double
    ) -> [Double]? {
        guard frequency > 0, frequency < baseRate / 2, q > 0 else { return nil }
        let base: [Double]
        switch type {
        case .peaking:
            base = peakingEQCoefficients(frequency: frequency, gainDB: Float(gainDB), q: q, sampleRate: baseRate)
        case .lowShelf:
            base = lowShelfCoefficients(frequency: frequency, gainDB: Float(gainDB), q: q, sampleRate: baseRate)
        case .highShelf:
            base = highShelfCoefficients(frequency: frequency, gainDB: Float(gainDB), q: q, sampleRate: baseRate)
        }
        let ratio = baseRate / sampleRate
        guard abs(base[0]) > 1e-12,
              let poles = moveRoots(base[3], base[4], ratio: ratio),
              let zeros = moveRoots(base[1] / base[0], base[2] / base[0], ratio: ratio) else { return nil }
        let shape = [1, zeros.0, zeros.1, poles.0, poles.1]
        guard abs(poles.1) < 1, abs(poles.0) < 1 + poles.1 else { return nil }

        // Gain: the mean of the dB differences on the error grid
        let top = min(20_000, 0.499 * sampleRate)
        let steps = 64
        var sum = 0.0
        for i in 0..<steps {
            let f = 20 * pow(top / 20, Double(i) / Double(steps - 1))
            let exact = intendedMagnitudeSquared(
                type: type, centerFrequency: frequency, gainDB: gainDB, q: q, at: f, baseRate: baseRate)
            sum += 10 * log10(max(exact, 1e-30)) - 10 * log10(max(digitalMagnitudeSquared(shape, at: f, sampleRate: sampleRate), 1e-30))
        }
        let gain = pow(10, sum / Double(steps) / 20)
        guard gain.isFinite, gain > 0 else { return nil }
        return [gain, gain * zeros.0, gain * zeros.1, poles.0, poles.1]
    }

    /// The roots of 1 + c1·z⁻¹ + c2·z⁻² moved by z' = z^ratio, as (c1', c2'). Nil when a
    /// complex root would land at or above the Nyquist frequency, or a real root is not
    /// positive (it has no such power).
    private static func moveRoots(_ c1: Double, _ c2: Double, ratio: Double) -> (Double, Double)? {
        let discriminant = c1 * c1 / 4 - c2
        if discriminant < 0 {
            // Complex pair r·e^(±jθ)
            let radius = sqrt(c2)
            let angle = acos(max(-1, min(1, -c1 / (2 * radius)))) * ratio
            guard angle < 0.999 * Double.pi else { return nil }
            let moved = pow(radius, ratio)
            return (-2 * moved * cos(angle), moved * moved)
        }
        let root = sqrt(discriminant)
        let z1 = -c1 / 2 + root, z2 = -c1 / 2 - root
        guard z1 > 0, z2 > 0 else { return nil }
        let p1 = pow(z1, ratio), p2 = pow(z2, ratio)
        return (-(p1 + p2), p1 * p2)
    }
}
