// FineTune/Audio/EQ/FIR/FIRDesign.swift
import Accelerate
import Foundation

/// Designs the FIR filters of the FIR correction engines from a target magnitude curve.
///
/// Two designs, both from the same curve sampled on a dense frequency grid:
/// - **Minimum phase** (`minimumPhase`): the causal filter with that magnitude and the least
///   possible delay at every frequency, like an analog or biquad EQ. No latency. Built with the
///   homomorphic (real cepstrum) method.
/// - **Linear phase** (`linearPhase`): a symmetric filter that changes no phase relationship
///   at all, at the price of a latency of half its length. Built by windowing the zero-phase
///   impulse response.
///
/// Each design is truncated to the shortest length that keeps the curve within a tolerance,
/// so a gentle correction gets a short filter (little CPU, and little latency in linear
/// phase) and only curves with narrow low-frequency features get a long one.
///
/// Not real-time: runs on the main thread when a preset or the sample rate changes
/// (a few milliseconds at 48 kHz).
nonisolated enum FIRDesign {
    struct Kernel: Equatable {
        /// Impulse response, first tap first.
        var taps: [Float]
        /// Delay the filter adds, in samples: 0 for minimum phase, half the length for linear phase.
        var latencySamples: Int
        /// Largest deviation from the target between 20 Hz and 20 kHz, in dB.
        var maxErrorDB: Double
    }

    /// Tolerance above 100 Hz, in dB. Below, it widens up to twice this at 20 Hz: the ear is
    /// less sensitive to small level errors there, and they are what long filters are spent on.
    static let minimumPhaseToleranceDB = 0.1
    /// Default of the linear-phase design. Each preset can choose another
    /// (`AutoEQProfile.linearPhaseToleranceDB`).
    static let linearPhaseToleranceDB = AutoEQLinearPhasePrecision.standard

    /// 1 at 48 kHz and below, then 2, 4, 8…: design sizes grow with the sample rate so that
    /// resolution in Hz, and latency in milliseconds, stay the same.
    static func rateScale(sampleRate: Double) -> Int {
        var scale = 1
        while 48_000.0 * Double(scale) < sampleRate * 0.99, scale < 16 { scale *= 2 }
        return scale
    }

    /// Size of the design grid (number of DFT points): bins are about 0.7 Hz apart.
    static func gridSize(sampleRate: Double) -> Int {
        65_536 * rateScale(sampleRate: sampleRate)
    }

    /// Lengths tried for a minimum-phase filter, shortest first.
    static func minimumPhaseLengths(sampleRate: Double) -> [Int] {
        let scale = rateScale(sampleRate: sampleRate)
        return [512, 1024, 2048, 4096, 8192].map { $0 * scale }
    }

    /// Half-lengths (= latencies in samples) tried for a linear-phase filter, shortest first:
    /// from 2.7 ms to 85 ms, in steps of √2.
    static func linearPhaseHalfLengths(sampleRate: Double) -> [Int] {
        let scale = Double(rateScale(sampleRate: sampleRate))
        return (0...10).map { Int((128.0 * scale * pow(2.0, Double($0) / 2.0)).rounded()) }
    }

    // MARK: - Minimum phase

    /// - Parameter targetDB: gain in dB at the frequencies `k * sampleRate / gridSize`,
    ///   k = 0...gridSize/2 (`gridSize(sampleRate:)` points apart).
    static func minimumPhase(targetDB: [Double], sampleRate: Double) -> Kernel? {
        let size = gridSize(sampleRate: sampleRate)
        guard targetDB.count == size / 2 + 1, let fft = DesignFFT(count: size) else { return nil }

        // Real cepstrum of the log magnitude (even symmetric spectrum → real sequence)
        var real = [Double](repeating: 0, count: size)
        var imag = [Double](repeating: 0, count: size)
        let dBToNepers = log(10.0) / 20.0
        for k in 0...(size / 2) {
            let value = targetDB[k] * dBToNepers
            real[k] = value
            if k > 0 && k < size / 2 { real[size - k] = value }
        }
        fft.inverse(&real, &imag)

        // Fold the anti-causal half onto the causal half: the cepstrum of the minimum-phase filter
        for i in 1..<(size / 2) { real[i] *= 2 }
        for i in (size / 2 + 1)..<size { real[i] = 0 }
        for i in 0..<size { imag[i] = 0 }
        fft.forward(&real, &imag)

        // exp of the complex log spectrum, then back to time
        for k in 0..<size {
            let magnitude = exp(real[k])
            let phase = imag[k]
            real[k] = magnitude * cos(phase)
            imag[k] = magnitude * sin(phase)
        }
        fft.inverse(&real, &imag)
        let response = real   // causal, energy at the start

        let lengths = minimumPhaseLengths(sampleRate: sampleRate)
        var best: Kernel?
        for length in lengths {
            let taps = truncated(response, length: length)
            let (ratio, maxError) = error(of: taps, targetDB: targetDB, sampleRate: sampleRate,
                                          toleranceDB: minimumPhaseToleranceDB, fft: fft)
            best = Kernel(taps: taps.map { Float($0) }, latencySamples: 0, maxErrorDB: maxError)
            if ratio <= 1 { break }
        }
        return best
    }

    /// First `length` samples, the last quarter faded out so the cut leaves no step.
    private static func truncated(_ response: [Double], length: Int) -> [Double] {
        var taps = Array(response.prefix(length))
        let fade = length / 4
        if fade > 1 {
            for i in 0..<fade {
                let x = Double(i + 1) / Double(fade + 1)
                taps[length - fade + i] *= 0.5 * (1 + cos(Double.pi * x))
            }
        }
        return taps
    }

    // MARK: - Linear phase

    /// Same `targetDB` grid as `minimumPhase`.
    /// - Parameter toleranceDB: the largest deviation allowed above 100 Hz. A tighter one gives a
    ///   longer filter, up to the longest of `linearPhaseHalfLengths`, which is used even when it
    ///   does not reach the tolerance (`maxErrorDB` then says how close it gets).
    static func linearPhase(
        targetDB: [Double], sampleRate: Double, toleranceDB: Double = FIRDesign.linearPhaseToleranceDB
    ) -> Kernel? {
        guard toleranceDB > 0 else { return nil }
        let size = gridSize(sampleRate: sampleRate)
        guard targetDB.count == size / 2 + 1, let fft = DesignFFT(count: size) else { return nil }

        // Zero-phase impulse response: real, symmetric around index 0 (cyclic)
        var real = [Double](repeating: 0, count: size)
        var imag = [Double](repeating: 0, count: size)
        for k in 0...(size / 2) {
            let value = pow(10.0, targetDB[k] / 20.0)
            real[k] = value
            if k > 0 && k < size / 2 { real[size - k] = value }
        }
        fft.inverse(&real, &imag)
        let zeroPhase = real

        var best: Kernel?
        for half in linearPhaseHalfLengths(sampleRate: sampleRate) {
            guard 2 * half + 1 < size else { break }
            let taps = windowed(zeroPhase, half: half)
            let (ratio, maxError) = error(of: taps, targetDB: targetDB, sampleRate: sampleRate,
                                          toleranceDB: toleranceDB, fft: fft)
            best = Kernel(taps: taps.map { Float($0) }, latencySamples: half, maxErrorDB: maxError)
            if ratio <= 1 { break }
        }
        return best
    }

    /// Samples −half...half of the cyclic zero-phase response, delayed by `half`, with both
    /// ends (an eighth of the length each) faded out.
    private static func windowed(_ zeroPhase: [Double], half: Int) -> [Double] {
        let size = zeroPhase.count
        let length = 2 * half + 1
        var taps = [Double](repeating: 0, count: length)
        for i in 0..<length {
            let source = i - half
            taps[i] = zeroPhase[source >= 0 ? source : source + size]
        }
        let fade = half / 4
        if fade > 1 {
            for i in 0..<fade {
                let gain = 0.5 - 0.5 * cos(Double.pi * Double(i + 1) / Double(fade + 1))
                taps[i] *= gain
                taps[length - 1 - i] *= gain
            }
        }
        return taps
    }

    // MARK: - Accuracy

    /// Deviation of a filter from the target between 20 Hz and 20 kHz (or 0.48 × sample rate).
    /// - Returns: `ratio`, the largest deviation relative to the tolerance at its frequency
    ///   (≤ 1 = within tolerance), and `maxError`, the largest deviation in dB.
    private static func error(
        of taps: [Double], targetDB: [Double], sampleRate: Double, toleranceDB: Double, fft: DesignFFT
    ) -> (ratio: Double, maxError: Double) {
        let size = fft.count
        var real = [Double](repeating: 0, count: size)
        var imag = [Double](repeating: 0, count: size)
        for i in 0..<min(taps.count, size) { real[i] = taps[i] }
        fft.forward(&real, &imag)

        let binWidth = sampleRate / Double(size)
        let first = max(1, Int((20.0 / binWidth).rounded(.up)))
        let last = min(size / 2, Int(min(20_000.0, 0.48 * sampleRate) / binWidth))
        guard first <= last else { return (0, 0) }

        var worstRatio = 0.0
        var worstError = 0.0
        let widening = 1.0 / log(5.0)
        for k in first...last {
            let power = real[k] * real[k] + imag[k] * imag[k]
            let deviation = abs(10.0 * log10(max(power, 1e-30)) - targetDB[k])
            let frequency = Double(k) * binWidth
            let weight = frequency >= 100 ? 1.0 : 1.0 + log(100.0 / frequency) * widening
            worstError = max(worstError, deviation)
            worstRatio = max(worstRatio, deviation / (weight * toleranceDB))
        }
        return (worstRatio, worstError)
    }

    /// Gain in dB of a filter at one frequency (direct evaluation, for tests and diagnostics).
    static func responseDB(of taps: [Float], at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        var re = 0.0, im = 0.0
        for (n, tap) in taps.enumerated() {
            re += Double(tap) * cos(omega * Double(n))
            im -= Double(tap) * sin(omega * Double(n))
        }
        return 10.0 * log10(max(re * re + im * im, 1e-30))
    }
}

/// In-place complex DFT of a fixed power-of-two length, double precision, unnormalized
/// forward and normalized inverse (so `inverse(forward(x)) == x`). For filter design only.
final class DesignFFT {
    let count: Int
    private let forwardSetup: vDSP_DFT_SetupD
    private let inverseSetup: vDSP_DFT_SetupD
    private var scratchReal: [Double]
    private var scratchImag: [Double]

    init?(count: Int) {
        guard count >= 16, count & (count - 1) == 0,
              let forward = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(count), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(count), .INVERSE) else {
            return nil
        }
        self.count = count
        forwardSetup = forward
        inverseSetup = inverse
        scratchReal = [Double](repeating: 0, count: count)
        scratchImag = [Double](repeating: 0, count: count)
    }

    deinit {
        vDSP_DFT_DestroySetupD(forwardSetup)
        vDSP_DFT_DestroySetupD(inverseSetup)
    }

    func forward(_ real: inout [Double], _ imag: inout [Double]) {
        execute(forwardSetup, &real, &imag, scale: 1)
    }

    func inverse(_ real: inout [Double], _ imag: inout [Double]) {
        execute(inverseSetup, &real, &imag, scale: 1.0 / Double(count))
    }

    private func execute(_ setup: vDSP_DFT_SetupD, _ real: inout [Double], _ imag: inout [Double], scale: Double) {
        precondition(real.count == count && imag.count == count)
        real.withUnsafeBufferPointer { inReal in
            imag.withUnsafeBufferPointer { inImag in
                scratchReal.withUnsafeMutableBufferPointer { outReal in
                    scratchImag.withUnsafeMutableBufferPointer { outImag in
                        vDSP_DFT_ExecuteD(setup, inReal.baseAddress!, inImag.baseAddress!,
                                          outReal.baseAddress!, outImag.baseAddress!)
                    }
                }
            }
        }
        if scale == 1 {
            real = scratchReal
            imag = scratchImag
        } else {
            for i in 0..<count {
                real[i] = scratchReal[i] * scale
                imag[i] = scratchImag[i] * scale
            }
        }
    }
}
