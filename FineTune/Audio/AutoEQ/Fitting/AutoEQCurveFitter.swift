// FineTune/Audio/AutoEQ/Fitting/AutoEQCurveFitter.swift
import Accelerate
import Foundation

/// Fits editable EQ bands (peaking, low and high shelf) to a curve, in double precision.
///
/// The idea comes from the AutoEQ optimiser of PEQdB (autoeq.c, init.c; LGPL-3.0-or-later,
/// © PEQdB Inc.): every band is fitted together with the others against the error of the whole
/// cascade, on ln(frequency), gain and bandwidth in octaves, with analytic derivatives. What
/// changes here, to reach a few hundredths of a dB where a first-order optimiser stops near
/// 0.3 dB:
///
/// - Levenberg-Marquardt on the error in dB, which converges quadratically, with the band
///   limits applied by clipping each step;
/// - a search for the structure of the fit, which escapes the local minima a fixed set of bands
///   gets stuck in: start from two or three times the number of bands asked for, then remove
///   the band whose removal costs least, one at a time; then try another type for each band,
///   and "swaps" (add a band where the error is worst, remove the least useful one); then a few
///   random restarts around the result ("basin hopping");
/// - a final reweighting (Lawson's method) that turns the least-squares fit into one with the
///   smallest maximum error, which is what the conversion reports.
///
/// A band's curve is its exact curve (`BiquadMath.intendedMagnitudeSquared`): the cookbook
/// biquad at the problem's base rate, or the analog prototype. The hot loops run on raw buffers
/// and Accelerate, so that a debug build stays usable. Not thread-safe: one fitter per task.
/// Checks for task cancellation between iterations (`CancellationError`).
nonisolated final class AutoEQCurveFitter {
    /// How hard the structure search tries.
    enum Effort: Sendable {
        /// One start from twice the bands, no swaps or restarts. For scans and tests.
        case quick
        /// Starts from two and three times the bands, swaps and eight restarts.
        case standard
    }

    let problem: AutoEQFitProblem
    /// Called with the fraction done (0...1), from the fitting thread.
    var progress: (@Sendable (Double) -> Void)?
    /// Levenberg-Marquardt iterations run so far (all fits of this fitter).
    private(set) var iterationCount = 0

    private let count: Int
    private let maxParameters: Int
    private let logLow: Double, logHigh: Double, bandwidthLow: Double, bandwidthHigh: Double
    private let warpedFrequencies: UnsafeMutablePointer<Double>
    private let target: UnsafeMutablePointer<Double>
    private let logFrequencies: [Double]
    // Work buffers. Rows of `jacobianT` are parameters, columns grid points.
    private let jacobianT: UnsafeMutablePointer<Double>
    private let weightedJacobianT: UnsafeMutablePointer<Double>
    private let jacobian: UnsafeMutablePointer<Double>
    private let normal: UnsafeMutablePointer<Double>
    private let system: UnsafeMutablePointer<Double>
    private let gradient: UnsafeMutablePointer<Double>
    private let step: UnsafeMutablePointer<Double>
    private let diagonal: UnsafeMutablePointer<Double>
    private let residual: UnsafeMutablePointer<Double>
    private let ratio: UnsafeMutablePointer<Double>
    private let product: UnsafeMutablePointer<Double>
    private let logs: UnsafeMutablePointer<Double>
    private let total: UnsafeMutablePointer<Double>
    private let weights: UnsafeMutablePointer<Double>
    private let errors: UnsafeMutablePointer<Double>
    private var buffers: [UnsafeMutablePointer<Double>] = []
    private var random: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var progressStart = 0.0
    private var progressSpan = 1.0
    private var lastReported = -1.0

    /// 10 / ln 10: dB per natural log unit of a squared magnitude.
    private static let dBPerLog = 10 / M_LN10

    /// `maxBands`: the largest number of bands any fit of this fitter holds (a structure search
    /// for N bands holds up to 3N + 1).
    init(problem: AutoEQFitProblem, maxBands: Int) {
        self.problem = problem
        let count = problem.frequencies.count
        let maxParameters = 3 * max(maxBands, 1) + 1
        self.count = count
        self.maxParameters = maxParameters
        let frequencyBounds = problem.logFrequencyBounds
        logLow = frequencyBounds.low
        logHigh = frequencyBounds.high
        let bandwidthBounds = problem.bandwidthBounds
        bandwidthLow = bandwidthBounds.low
        bandwidthHigh = bandwidthBounds.high
        logFrequencies = problem.frequencies.map { log($0) }

        var allocated: [UnsafeMutablePointer<Double>] = []
        func buffer(_ size: Int) -> UnsafeMutablePointer<Double> {
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: max(size, 1))
            pointer.initialize(repeating: 0, count: max(size, 1))
            allocated.append(pointer)
            return pointer
        }
        let parameterRows = maxParameters * count
        warpedFrequencies = buffer(count)
        target = buffer(count)
        jacobianT = buffer(parameterRows)
        weightedJacobianT = buffer(parameterRows)
        jacobian = buffer(parameterRows)
        normal = buffer(maxParameters * maxParameters)
        system = buffer(maxParameters * maxParameters)
        gradient = buffer(maxParameters)
        step = buffer(maxParameters)
        diagonal = buffer(maxParameters)
        residual = buffer(count)
        ratio = buffer(count)
        product = buffer(count)
        logs = buffer(count)
        total = buffer(count)
        weights = buffer(count)
        errors = buffer(count)
        buffers = allocated

        for index in 0..<count {
            let frequency = problem.frequencies[index]
            target[index] = problem.target[index]
            if let baseRate = problem.baseRate {
                // The cookbook biquad at the base rate is the analog prototype at tan(πf/fs):
                // see BiquadMath.intendedMagnitudeSquared, clamped the same way
                warpedFrequencies[index] = tan(Double.pi * min(max(frequency, 0), 0.499_99 * baseRate) / baseRate)
            } else {
                warpedFrequencies[index] = frequency
            }
        }
    }

    deinit {
        for pointer in buffers { pointer.deallocate() }
    }

    // MARK: - Fits

    /// The best `bandCount` bands for the problem's curve, with the overall level.
    func fit(bandCount: Int, effort: Effort = .standard) throws -> AutoEQFitState {
        let bandCount = max(1, min(bandCount, (maxParameters - 1) / 3 / 3))
        let multiples = effort == .standard ? [2, 3] : [2]
        let searchShare = effort == .standard ? 0.8 : 0.85
        var best: AutoEQFitState?
        var bestCost = Double.infinity
        for (index, multiple) in multiples.enumerated() {
            let start = searchShare * Double(index) / Double(multiples.count)
            let span = searchShare / Double(multiples.count)
            var state = overcompleteStart(bandCount: multiple * bandCount)
            setProgressStage(start, span * 0.75)
            try prune(&state, to: bandCount)
            setProgressStage(start + span * 0.75, span * 0.25)
            try tryOtherTypes(&state)
            if effort == .standard { try swapBands(&state, rounds: 12) }
            try levenbergMarquardt(&state, iterations: 200)
            let cost = self.cost(of: state)
            if cost < bestCost {
                bestCost = cost
                best = state
            }
        }
        guard var state = best else { return AutoEQFitState() }
        if effort == .standard {
            setProgressStage(searchShare, 0.12)
            try hop(&state, cost: &bestCost, restarts: 8)
        }
        setProgressStage(0.92, 0.08)
        try minimax(&state, rounds: effort == .standard ? 20 : 10, iterations: effort == .standard ? 25 : 20)
        reportProgress(1)
        return state
    }

    /// The fewest bands (up to `maxBands`) whose curve stays within `toleranceDB` of the target,
    /// or the best fit with `maxBands` bands when none does. Scans with quick fits, then refits
    /// the number found with `effort`.
    func fitFewestBands(toleranceDB: Double, maxBands: Int, effort: Effort = .standard) throws -> AutoEQFitState {
        let limit = max(1, min(maxBands, (maxParameters - 1) / 3 / 3))
        var counts = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32].filter { $0 < limit }
        counts.append(limit)
        let onProgress = progress
        progress = nil
        defer { progress = onProgress }
        var found: (count: Int, state: AutoEQFitState)?
        for (index, bandCount) in counts.enumerated() {
            onProgress?(0.5 * Double(index) / Double(counts.count))
            let state = try fit(bandCount: bandCount, effort: .quick)
            if maxError(of: state).errorDB <= toleranceDB || bandCount == limit {
                found = (bandCount, state)
                break
            }
        }
        guard let found else { return AutoEQFitState() }
        guard effort == .standard else { return found.state }
        // The full search can do better than the scan with the same number of bands
        progress = { value in onProgress?(0.5 + 0.5 * value) }
        let refined = try fit(bandCount: found.count, effort: .standard)
        return maxError(of: refined).errorDB < maxError(of: found.state).errorDB ? refined : found.state
    }

    /// The same bands moved to fit the curve: Levenberg-Marquardt from `start`, then the
    /// minimax reweighting. For a filter list played at another base rate.
    func refine(_ start: AutoEQFitState) throws -> AutoEQFitState {
        var state = start
        setProgressStage(0, 0.4)
        try levenbergMarquardt(&state, iterations: 200)
        setProgressStage(0.4, 0.6)
        try minimax(&state, rounds: 20, iterations: 25)
        reportProgress(1)
        return state
    }

    // MARK: - Errors

    /// Largest difference from the target over the grid, in dB, and where it is.
    func maxError(of state: AutoEQFitState) -> (errorDB: Double, frequency: Double) {
        computeResidual(of: state)
        var largest = 0.0
        var index: vDSP_Length = 0
        vDSP_maxmgviD(residual, 1, &largest, &index, vDSP_Length(count))
        return (largest, problem.frequencies[min(Int(index), count - 1)])
    }

    /// The fitted curve (level plus bands) at every grid frequency, in dB.
    func response(of state: AutoEQFitState) -> [Double] {
        computeResponse(of: state, into: total)
        return Array(UnsafeBufferPointer(start: total, count: count))
    }

    /// One band in dB at every grid frequency, and its derivatives with respect to
    /// ln(frequency), gain and bandwidth. For tests.
    func bandResponse(_ band: AutoEQFitBand) -> (dB: [Double], derivatives: [[Double]]) {
        let rows = (0..<3).map { _ in UnsafeMutablePointer<Double>.allocate(capacity: count) }
        defer { rows.forEach { $0.deallocate() } }
        evaluate(
            band.type, band.logFrequency, band.gainDB, band.bandwidth,
            ratio: ratio, derivatives: (rows[0], rows[1], rows[2]))
        let values = (0..<count).map { Self.dBPerLog * log(ratio[$0]) }
        let derivatives = rows.map { Array(UnsafeBufferPointer(start: $0, count: count)) }
        return (values, derivatives)
    }

    // MARK: - Band Curve

    /// Squared magnitude of one band at every grid point (`ratio`), and, with `derivatives`,
    /// the derivatives of its value in dB with respect to ln(frequency), gain and bandwidth.
    ///
    /// The band is the RBJ analog prototype at w = x / x0, where x is the frequency (analog) or
    /// tan(πf/fs) (cookbook biquad at fs), as in `BiquadMath.analogMagnitudeSquared`. With
    /// a = 10^(gain/40), the squared magnitude is N/D with
    /// - peaking: N = (1 - w²)² + (w·a/q)², D = (1 - w²)² + (w/(a·q))²;
    /// - low shelf: a²·[(a - w²)² + a·w²/q²] / [(1 - a·w²)² + a·w²/q²];
    /// - high shelf: a²·[(1 - a·w²)² + a·w²/q²] / [(a - w²)² + a·w²/q²].
    private func evaluate(
        _ type: AutoEQFilter.FilterType, _ logFrequency: Double, _ gainDB: Double, _ bandwidth: Double,
        ratio out: UnsafeMutablePointer<Double>,
        derivatives: (UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>)?
    ) {
        let centre = exp(logFrequency)
        let q = AutoEQFitBand.q(bandwidth: bandwidth)
        let a = pow(10, gainDB / 40)
        var x0 = centre
        // d(ln x0)/d(ln f0)
        var warpSlope = 1.0
        if let baseRate = problem.baseRate {
            let angle = Double.pi * centre / baseRate
            x0 = tan(angle)
            warpSlope = angle * (1 + x0 * x0) / x0
        }
        let inverseX0 = 1 / x0
        let inverseQ = 1 / q
        let inverseQ2 = inverseQ * inverseQ
        // Chain rule factors: dw/d(ln f0) = -w·warpSlope, da/dgain = a·ln10/40, dq/dbandwidth
        let halfLn2 = 0.5 * M_LN2
        let byLogFrequency = -Self.dBPerLog * warpSlope
        let byGain = Self.dBPerLog * a * M_LN10 / 40
        let byBandwidth = Self.dBPerLog * (-q * halfLn2 * cosh(halfLn2 * bandwidth) / sinh(halfLn2 * bandwidth))
        let x = UnsafePointer(warpedFrequencies)
        let n = count

        switch type {
        case .peaking:
            let a2 = a * a
            let numeratorQ = a2 * inverseQ2
            let denominatorQ = inverseQ2 / a2
            let numeratorA = 2 * a * inverseQ2
            let denominatorA = -2 * inverseQ2 / (a2 * a)
            let numeratorDQ = -2 * numeratorQ * inverseQ
            let denominatorDQ = -2 * denominatorQ * inverseQ
            var k = 0
            if let derivatives {
                let (du, dg, db) = derivatives
                while k < n {
                    let w = x[k] * inverseX0
                    let w2 = w * w
                    let re = 1 - w2
                    let re2 = re * re
                    let numerator = re2 + w2 * numeratorQ
                    let denominator = re2 + w2 * denominatorQ
                    let inverseN = 1 / numerator
                    let inverseD = 1 / denominator
                    out[k] = numerator * inverseD
                    // (dN/dw)/w and (dD/dw)/w
                    let dNw = 2 * numeratorQ - 4 * re
                    let dDw = 2 * denominatorQ - 4 * re
                    du[k] = byLogFrequency * w2 * (dNw * inverseN - dDw * inverseD)
                    dg[k] = byGain * w2 * (numeratorA * inverseN - denominatorA * inverseD)
                    db[k] = byBandwidth * w2 * (numeratorDQ * inverseN - denominatorDQ * inverseD)
                    k += 1
                }
            } else {
                while k < n {
                    let w = x[k] * inverseX0
                    let w2 = w * w
                    let re = 1 - w2
                    let re2 = re * re
                    out[k] = (re2 + w2 * numeratorQ) / (re2 + w2 * denominatorQ)
                    k += 1
                }
            }

        case .lowShelf, .highShelf:
            let isLow = type == .lowShelf
            let a2 = a * a
            let imaginary = a * inverseQ2
            let qTerm = -2 * imaginary * inverseQ
            let shelfGain = byGain * 2 / a
            var k = 0
            guard let derivatives else {
                while k < n {
                    let w = x[k] * inverseX0
                    let w2 = w * w
                    let im2 = w2 * imaginary
                    let aw2 = a * w2
                    let numeratorRe = isLow ? a - w2 : 1 - aw2
                    let denominatorRe = isLow ? 1 - aw2 : a - w2
                    out[k] = a2 * (numeratorRe * numeratorRe + im2) / (denominatorRe * denominatorRe + im2)
                    k += 1
                }
                return
            }
            let (du, dg, db) = derivatives
            while k < n {
                let w = x[k] * inverseX0
                let w2 = w * w
                let im2 = w2 * imaginary
                let aw2 = a * w2
                let numeratorRe = isLow ? a - w2 : 1 - aw2
                let denominatorRe = isLow ? 1 - aw2 : a - w2
                let numerator = numeratorRe * numeratorRe + im2
                let denominator = denominatorRe * denominatorRe + im2
                let inverseN = 1 / numerator
                let inverseD = 1 / denominator
                out[k] = a2 * numerator * inverseD
                // (dN/dw)/w, (dD/dw)/w, dN/da, dD/da
                let dNw = (isLow ? -4 * numeratorRe : -4 * a * numeratorRe) + 2 * imaginary
                let dDw = (isLow ? -4 * a * denominatorRe : -4 * denominatorRe) + 2 * imaginary
                let w2q = w2 * inverseQ2
                let dNa = (isLow ? 2 * numeratorRe : -2 * w2 * numeratorRe) + w2q
                let dDa = (isLow ? -2 * w2 * denominatorRe : 2 * denominatorRe) + w2q
                du[k] = byLogFrequency * w2 * (dNw * inverseN - dDw * inverseD)
                dg[k] = byGain * (dNa * inverseN - dDa * inverseD) + shelfGain
                db[k] = byBandwidth * qTerm * w2 * (inverseN - inverseD)
                k += 1
            }
        }
    }

    /// Level plus the sum of the bands in dB, at every grid point. The squared magnitudes of up
    /// to eight bands are multiplied before taking one log (within 1e±39 for gains up to 24 dB).
    private func computeResponse(of state: AutoEQFitState, into out: UnsafeMutablePointer<Double>) {
        var level = state.levelDB
        let n = vDSP_Length(count)
        vDSP_vfillD(&level, out, 1, n)
        var one = 1.0
        var scale = Self.dBPerLog
        var length = Int32(count)
        vDSP_vfillD(&one, product, 1, n)
        let bands = state.count
        state.parameters.withUnsafeBufferPointer { parameters in
            var band = 0
            while band < bands {
                evaluate(
                    state.types[band], parameters[3 * band], parameters[3 * band + 1], parameters[3 * band + 2],
                    ratio: ratio, derivatives: nil)
                vDSP_vmulD(product, 1, ratio, 1, product, 1, n)
                if band % 8 == 7 || band == bands - 1 {
                    vvlog(logs, product, &length)
                    vDSP_vsmaD(logs, 1, &scale, out, 1, out, 1, n)
                    vDSP_vfillD(&one, product, 1, n)
                }
                band += 1
            }
        }
    }

    /// `residual` = response - target.
    private func computeResidual(of state: AutoEQFitState) {
        computeResponse(of: state, into: total)
        vDSP_vsubD(target, 1, total, 1, residual, 1, vDSP_Length(count))
    }

    /// Sum of the squared errors, weighted by `weighted ? weights : 1`.
    private func cost(of state: AutoEQFitState, weighted: Bool = false) -> Double {
        computeResidual(of: state)
        var sum = 0.0
        if weighted {
            vDSP_vmulD(residual, 1, residual, 1, errors, 1, vDSP_Length(count))
            vDSP_dotprD(errors, 1, weights, 1, &sum, vDSP_Length(count))
        } else {
            vDSP_svesqD(residual, 1, &sum, vDSP_Length(count))
        }
        return sum
    }

    // MARK: - Levenberg-Marquardt

    private func clip(_ state: inout AutoEQFitState) {
        let maxGain = problem.maxGainDB
        var index = 0
        while index < state.count {
            let base = 3 * index
            state.parameters[base] = min(max(state.parameters[base], logLow), logHigh)
            state.parameters[base + 1] = min(max(state.parameters[base + 1], -maxGain), maxGain)
            state.parameters[base + 2] = min(max(state.parameters[base + 2], bandwidthLow), bandwidthHigh)
            index += 1
        }
    }

    /// Fill `normal` (JᵀWJ) and `gradient` (JᵀWr) for the state, with `residual` = r.
    private func buildNormalEquations(_ state: AutoEQFitState, weighted: Bool) {
        let n = count
        let parameterCount = 3 * state.count + 1
        computeResidual(of: state)
        state.parameters.withUnsafeBufferPointer { parameters in
            var band = 0
            while band < state.count {
                let row = jacobianT + 3 * band * n
                evaluate(
                    state.types[band], parameters[3 * band], parameters[3 * band + 1], parameters[3 * band + 2],
                    ratio: ratio, derivatives: (row, row + n, row + 2 * n))
                band += 1
            }
        }
        var one = 1.0
        vDSP_vfillD(&one, jacobianT + 3 * state.count * n, 1, vDSP_Length(n))
        var source = UnsafePointer(jacobianT)
        if weighted {
            var row = 0
            while row < parameterCount {
                vDSP_vmulD(jacobianT + row * n, 1, weights, 1, weightedJacobianT + row * n, 1, vDSP_Length(n))
                row += 1
            }
            source = UnsafePointer(weightedJacobianT)
        }
        let p = vDSP_Length(parameterCount)
        vDSP_mtransD(jacobianT, 1, jacobian, 1, vDSP_Length(n), p)
        vDSP_mmulD(source, 1, jacobian, 1, normal, 1, p, p, vDSP_Length(n))
        vDSP_mmulD(source, 1, residual, 1, gradient, 1, p, 1, vDSP_Length(n))
    }

    /// Solve `system` · x = `step` in place (Cholesky). False when the matrix is not positive
    /// definite.
    private func choleskySolve(size: Int) -> Bool {
        let a = system
        var j = 0
        while j < size {
            var sum = a[j * size + j]
            var k = 0
            while k < j {
                sum -= a[j * size + k] * a[j * size + k]
                k += 1
            }
            guard sum > 0 else { return false }
            let pivot = sqrt(sum)
            a[j * size + j] = pivot
            var i = j + 1
            while i < size {
                var value = a[i * size + j]
                k = 0
                while k < j {
                    value -= a[i * size + k] * a[j * size + k]
                    k += 1
                }
                a[i * size + j] = value / pivot
                i += 1
            }
            j += 1
        }
        var i = 0
        while i < size {
            var value = step[i]
            var k = 0
            while k < i {
                value -= a[i * size + k] * step[k]
                k += 1
            }
            step[i] = value / a[i * size + i]
            i += 1
        }
        i = size - 1
        while i >= 0 {
            var value = step[i]
            var k = i + 1
            while k < size {
                value -= a[k * size + i] * step[k]
                k += 1
            }
            step[i] = value / a[i * size + i]
            i -= 1
        }
        return true
    }

    /// Levenberg-Marquardt on the error in dB (weighted by `weights` when `weighted`), with the
    /// band limits applied by clipping each step.
    private func levenbergMarquardt(_ state: inout AutoEQFitState, weighted: Bool = false, iterations: Int) throws {
        clip(&state)
        var currentCost = cost(of: state, weighted: weighted)
        var lambda = 1e-3
        var iteration = 0
        while iteration < iterations {
            try Task.checkCancellation()
            iterationCount += 1
            let parameterCount = 3 * state.count + 1
            buildNormalEquations(state, weighted: weighted)
            var index = 0
            while index < parameterCount {
                diagonal[index] = normal[index * parameterCount + index] + 1e-12
                index += 1
            }
            var accepted = false
            var relativeGain = 1.0
            var attempt = 0
            while attempt < 25 {
                system.update(from: normal, count: parameterCount * parameterCount)
                index = 0
                while index < parameterCount {
                    system[index * parameterCount + index] += lambda * diagonal[index]
                    step[index] = -gradient[index]
                    index += 1
                }
                if choleskySolve(size: parameterCount) {
                    var trial = state
                    index = 0
                    while index < parameterCount - 1 {
                        trial.parameters[index] += step[index]
                        index += 1
                    }
                    trial.levelDB += step[parameterCount - 1]
                    clip(&trial)
                    let trialCost = cost(of: trial, weighted: weighted)
                    if trialCost < currentCost {
                        relativeGain = (currentCost - trialCost) / max(currentCost, 1e-30)
                        state = trial
                        currentCost = trialCost
                        lambda = max(lambda / 4, 1e-12)
                        accepted = true
                        break
                    }
                }
                lambda *= 5
                attempt += 1
            }
            if !accepted || relativeGain < 1e-10 { break }
            iteration += 1
        }
    }

    /// Lawson's reweighting: each round raises the weight of the grid points in proportion to
    /// their error, which drives the least-squares fit toward the smallest maximum error.
    /// Keeps the round with the smallest maximum error.
    private func minimax(_ state: inout AutoEQFitState, rounds: Int, iterations: Int) throws {
        let n = vDSP_Length(count)
        var one = 1.0
        vDSP_vfillD(&one, weights, 1, n)
        var best = state
        var bestError = maxError(of: state).errorDB
        for round in 0..<rounds {
            reportProgress(Double(round) / Double(rounds))
            computeResidual(of: state)
            vDSP_vabsD(residual, 1, errors, 1, n)
            var largest = 0.0
            vDSP_maxvD(errors, 1, &largest, n)
            guard largest > 0 else { break }
            var inverse = 1 / largest
            var minimum = 1e-4
            vDSP_vsmsaD(errors, 1, &inverse, &minimum, errors, 1, n)
            vDSP_vmulD(weights, 1, errors, 1, weights, 1, n)
            var mean = 0.0
            vDSP_meanvD(weights, 1, &mean, n)
            var normalize = 1 / mean
            vDSP_vsmulD(weights, 1, &normalize, weights, 1, n)
            try levenbergMarquardt(&state, weighted: true, iterations: iterations)
            let error = maxError(of: state).errorDB
            if error < bestError {
                bestError = error
                best = state
            }
        }
        state = best
    }

    // MARK: - Structure Search

    /// `bandCount` bands spread over the range: a low and a high shelf (when allowed), then
    /// peaking bands evenly spaced on a log scale with half the target's deviation as gain,
    /// and the median of the target as level.
    private func overcompleteStart(bandCount: Int) -> AutoEQFitState {
        let sorted = problem.target.sorted()
        let middle = sorted.count / 2
        let level = sorted.count % 2 == 1 ? sorted[middle] : 0.5 * (sorted[middle - 1] + sorted[middle])
        var state = AutoEQFitState(levelDB: level)
        var peaks = bandCount
        if problem.allowsShelves && bandCount >= 2 {
            state.append(AutoEQFitBand(type: .lowShelf, logFrequency: log(100), gainDB: 0, bandwidth: AutoEQFitBand.bandwidth(q: 0.7)))
            state.append(AutoEQFitBand(type: .highShelf, logFrequency: log(8_000), gainDB: 0, bandwidth: AutoEQFitBand.bandwidth(q: 0.7)))
            peaks -= 2
        }
        let low = logLow + 0.2
        let high = max(logHigh - 0.2, low)
        for index in 0..<peaks {
            let position = peaks > 1 ? low + (high - low) * Double(index) / Double(peaks - 1) : 0.5 * (low + high)
            state.append(AutoEQFitBand(
                type: .peaking, logFrequency: position, gainDB: (targetValue(atLogFrequency: position) - level) * 0.5,
                bandwidth: AutoEQFitBand.bandwidth(q: 2)))
        }
        clip(&state)
        return state
    }

    /// The target at ln(frequency), interpolated on the grid.
    private func targetValue(atLogFrequency position: Double) -> Double {
        let grid = logFrequencies
        guard let first = grid.first, let last = grid.last else { return 0 }
        if position <= first { return problem.target[0] }
        if position >= last { return problem.target[count - 1] }
        var low = 0
        var high = count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if grid[middle] <= position { low = middle } else { high = middle }
        }
        let t = (position - grid[low]) / (grid[high] - grid[low])
        return problem.target[low] + (problem.target[high] - problem.target[low]) * t
    }

    /// Fit the overcomplete start, then remove bands one at a time down to `bandCount`.
    private func prune(_ state: inout AutoEQFitState, to bandCount: Int) throws {
        try levenbergMarquardt(&state, iterations: 150)
        let removals = max(state.count - bandCount, 1)
        var removed = 0
        while state.count > bandCount {
            reportProgress(Double(removed) / Double(removals))
            try removeLeastUseful(&state, finalIterations: 30)
            removed += 1
        }
        try levenbergMarquardt(&state, iterations: 300)
    }

    /// Remove the band whose removal (followed by a short refit) costs least. Every band is
    /// tried, or with more than 24 bands the 8 whose removal alone costs least.
    private func removeLeastUseful(_ state: inout AutoEQFitState, finalIterations: Int) throws {
        guard state.count > 1 else { return }
        var candidates = Array(0..<state.count)
        if state.count > 24 { candidates = cheapestRemovals(of: state, keeping: 8) }
        var best: AutoEQFitState?
        var bestCost = Double.infinity
        for index in candidates {
            var trial = state
            trial.remove(at: index)
            try levenbergMarquardt(&trial, iterations: 3)
            let trialCost = cost(of: trial)
            if trialCost < bestCost {
                bestCost = trialCost
                best = trial
            }
        }
        if let best { state = best }
        try levenbergMarquardt(&state, iterations: finalIterations)
    }

    /// The `keeping` bands whose removal alone (the level re-adjusted) leaves the smallest error.
    private func cheapestRemovals(of state: AutoEQFitState, keeping: Int) -> [Int] {
        computeResidual(of: state)
        let n = vDSP_Length(count)
        var scored: [(index: Int, cost: Double)] = []
        for band in 0..<state.count {
            evaluate(
                state.types[band], state.parameters[3 * band], state.parameters[3 * band + 1],
                state.parameters[3 * band + 2], ratio: ratio, derivatives: nil)
            var length = Int32(count)
            vvlog(logs, ratio, &length)
            // Residual without the band: r - dB(band), centred (the level absorbs its mean)
            var scale = -Self.dBPerLog
            vDSP_vsmaD(logs, 1, &scale, residual, 1, errors, 1, n)
            var mean = 0.0
            vDSP_meanvD(errors, 1, &mean, n)
            var sum = 0.0
            vDSP_svesqD(errors, 1, &sum, n)
            scored.append((band, sum - Double(count) * mean * mean))
        }
        return scored.sorted { $0.cost < $1.cost }.prefix(keeping).map(\.index)
    }

    /// Try every other allowed type for each band; keep a change that lowers the error.
    private func tryOtherTypes(_ state: inout AutoEQFitState) throws {
        let types = problem.allowedTypes
        guard types.count > 1 else { return }
        var currentCost = cost(of: state)
        for index in 0..<state.count {
            for type in types where type != state.types[index] {
                var trial = state
                trial.types[index] = type
                try levenbergMarquardt(&trial, iterations: 40)
                let trialCost = cost(of: trial)
                if trialCost < currentCost * 0.999 {
                    state = trial
                    currentCost = trialCost
                }
            }
        }
    }

    /// Add a band where the (smoothed) error is worst, refit, and remove the least useful band;
    /// keep the result when it lowers the error. Stops at the first round that does not.
    private func swapBands(_ state: inout AutoEQFitState, rounds: Int) throws {
        var currentCost = cost(of: state)
        var candidates: [(AutoEQFilter.FilterType, Double)] = [
            (.peaking, AutoEQFitBand.bandwidth(q: 1.5)), (.peaking, AutoEQFitBand.bandwidth(q: 4)),
        ]
        if problem.allowsShelves {
            candidates.append((.lowShelf, AutoEQFitBand.bandwidth(q: 0.7)))
            candidates.append((.highShelf, AutoEQFitBand.bandwidth(q: 0.7)))
        }
        for _ in 0..<rounds {
            computeResidual(of: state)
            // The worst point of the error smoothed over 9 grid points
            var worst = 0
            var worstValue = 0.0
            var largest = -1.0
            for k in 0..<count {
                var sum = 0.0
                for neighbour in max(k - 4, 0)...min(k + 4, count - 1) { sum += residual[neighbour] }
                let smoothed = sum / 9
                if abs(smoothed) > largest {
                    largest = abs(smoothed)
                    worst = k
                    worstValue = smoothed
                }
            }
            var improved = false
            for (type, bandwidth) in candidates {
                var trial = state
                trial.append(AutoEQFitBand(
                    type: type, logFrequency: logFrequencies[worst], gainDB: -worstValue, bandwidth: bandwidth))
                try levenbergMarquardt(&trial, iterations: 15)
                try removeLeastUseful(&trial, finalIterations: 30)
                let trialCost = cost(of: trial)
                if trialCost < currentCost * 0.999 {
                    state = trial
                    currentCost = trialCost
                    improved = true
                    break
                }
            }
            if !improved { break }
        }
    }

    /// Random restarts around the result: shift every band's frequency and width a little,
    /// refit, keep the best. Deterministic (fixed seed), so a conversion gives the same result
    /// every time.
    private func hop(_ state: inout AutoEQFitState, cost bestCost: inout Double, restarts: Int) throws {
        for restart in 0..<restarts {
            reportProgress(Double(restart) / Double(restarts))
            var trial = state
            for band in 0..<trial.count {
                trial.parameters[3 * band] += 0.15 * nextGaussian()
                trial.parameters[3 * band + 2] *= exp(0.2 * nextGaussian())
            }
            try levenbergMarquardt(&trial, iterations: 120)
            let trialCost = cost(of: trial)
            if trialCost < bestCost {
                bestCost = trialCost
                state = trial
            }
        }
    }

    /// Standard normal value (xorshift64 and Box-Muller).
    private func nextGaussian() -> Double {
        func uniform() -> Double {
            random ^= random << 13
            random ^= random >> 7
            random ^= random << 17
            return (Double(random >> 11) + 0.5) / 9_007_199_254_740_992
        }
        let radius = sqrt(-2 * log(uniform()))
        return radius * cos(2 * Double.pi * uniform())
    }

    // MARK: - Progress

    private func setProgressStage(_ start: Double, _ span: Double) {
        progressStart = start
        progressSpan = span
        reportProgress(0)
    }

    private func reportProgress(_ fraction: Double) {
        guard let progress else { return }
        let value = min(max(progressStart + progressSpan * fraction, 0), 1)
        guard abs(value - lastReported) >= 0.005 || value == 1 else { return }
        lastReported = value
        progress(value)
    }
}
