// FineTune/Audio/EQ/BiquadMath+Matched.swift
import Foundation

/// Biquads fitted to the exact (analog prototype) curve of an EQ band.
///
/// The cookbook biquads of `BiquadMath` come from the bilinear transform, which squeezes the
/// whole analog frequency axis below the Nyquist frequency: a band near the top of the
/// spectrum comes out narrower and its shelf steeper than drawn (several dB off for a band at
/// 10 kHz and above at 44.1 or 48 kHz). The design here keeps what makes a biquad cheap and
/// free of latency, and removes most of that error:
///
/// - the poles are the analog poles mapped by z = exp(s·T) (impulse invariance), as in
///   M. Vicanek, "Matched Second Order Digital Filters" (2016);
/// - the numerator is the one whose magnitude best fits the analog curve from 10 Hz to
///   Nyquist, in the least-squares sense. The squared magnitude of a biquad numerator is
///   linear in three unknowns, so this is a 3×3 linear system;
/// - a cut is designed as the inverse of the matching boost, as its analog prototype is.
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

    /// Biquad closest to the exact curve of the band: the matched design where it beats the
    /// cookbook one, the cookbook one otherwise (unity for a cookbook band at or above Nyquist).
    /// Returns [b0, b1, b2, a1, a2] for vDSP_biquad.
    static func exactCoefficients(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Float, q: Double, sampleRate: Double
    ) -> [Double] {
        let cookbook: [Double]
        if frequency <= 0 || frequency >= sampleRate / 2 {
            cookbook = [1, 0, 0, 0, 0]
        } else {
            switch type {
            case .peaking:
                cookbook = peakingEQCoefficients(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
            case .lowShelf:
                cookbook = lowShelfCoefficients(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
            case .highShelf:
                cookbook = highShelfCoefficients(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
            }
        }
        guard frequency > 0, q > 0,
              let matched = matchedCoefficients(type: type, frequency: frequency, gainDB: Double(gainDB), q: q, sampleRate: sampleRate) else {
            return cookbook
        }
        let cookbookError = maxErrorDB(cookbook, type: type, frequency: frequency, gainDB: Double(gainDB), q: q, sampleRate: sampleRate)
        let matchedError = maxErrorDB(matched, type: type, frequency: frequency, gainDB: Double(gainDB), q: q, sampleRate: sampleRate)
        return matchedError < cookbookError ? matched : cookbook
    }

    /// Largest deviation in dB of a biquad from the band's exact curve, on 64 frequencies
    /// from 20 Hz to 20 kHz (or just under Nyquist).
    static func maxErrorDB(
        _ coefficients: [Double], type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double
    ) -> Double {
        let top = min(20_000, 0.499 * sampleRate)
        let steps = 64
        var worst = 0.0
        for i in 0..<steps {
            let f = 20 * pow(top / 20, Double(i) / Double(steps - 1))
            let exact = analogMagnitudeSquared(type: type, centerFrequency: frequency, gainDB: gainDB, q: q, at: f)
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
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double
    ) -> [Double]? {
        guard gainDB < 0 else {
            return matchedBoost(type: type, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
        }
        // A cut is the inverse of the boost of the same size: swap numerator and denominator,
        // which needs the boost's zeros strictly inside the unit circle
        guard let boost = matchedBoost(type: type, frequency: frequency, gainDB: -gainDB, q: q, sampleRate: sampleRate) else {
            return nil
        }
        let b0 = boost[0]
        guard abs(b0) > 1e-12 else { return nil }
        let z1 = boost[1] / b0, z2 = boost[2] / b0
        guard abs(z2) < 0.9999, abs(z1) < 0.9999 + z2 else { return nil }
        return [1 / b0, boost[3] / b0, boost[4] / b0, z1, z2]
    }

    private static func matchedBoost(
        type: AutoEQFilter.FilterType, frequency: Double, gainDB: Double, q: Double, sampleRate: Double
    ) -> [Double]? {
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
            let target = analogMagnitudeSquared(type: type, centerFrequency: frequency, gainDB: gainDB, q: q, at: f) * denominator
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
}
