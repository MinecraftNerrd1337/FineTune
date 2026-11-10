// FineTuneTests/FIREngineTests.swift
//
// The FIR correction engines: filter design (minimum and linear phase), the zero-latency
// convolver, the crossfading processor, and their use by AutoEQProcessor.
// Pure signal processing, no audio hardware.

import Testing
import Foundation
@testable import FineTune

// MARK: - Helpers

/// Small deterministic generator, so failures are reproducible.
private struct Noise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Next value in −1...1.
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
    }

    mutating func samples(_ count: Int, scale: Float = 1) -> [Float] {
        (0..<count).map { _ in next() * scale }
    }
}

/// y[n] = Σ h[j] · x[n − j], the definition the convolver must match.
private func directConvolution(_ x: [Float], _ h: [Float]) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    x.withUnsafeBufferPointer { x in
        h.withUnsafeBufferPointer { h in
            for n in 0..<x.count {
                var sum = 0.0
                for j in 0...min(n, h.count - 1) {
                    sum += Double(h[j]) * Double(x[n - j])
                }
                y[n] = Float(sum)
            }
        }
    }
    return y
}

/// Runs one channel of a convolver over `input`, cut into chunks of the given sizes in turn.
private func run(_ convolver: FIRConvolver, channel: Int, input: [Float], chunks: [Int]) -> [Float] {
    var output = [Float](repeating: 0, count: input.count)
    let total = input.count
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            var done = 0
            var turn = 0
            while done < total {
                let n = min(chunks[turn % chunks.count], total - done)
                convolver.process(
                    channel: channel,
                    input: source.baseAddress! + done, inputStride: 1,
                    output: destination.baseAddress! + done, outputStride: 1,
                    count: n)
                done += n
                turn += 1
            }
        }
    }
    return output
}

private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
    var worst: Float = 0
    for i in 0..<min(a.count, b.count) { worst = max(worst, abs(a[i] - b[i])) }
    return a.count == b.count ? worst : .infinity
}

/// A correction with a bit of everything: bass shelf, broad dip, narrow peak and dip, treble shelf.
private func testProfile(engine: AutoEQCorrectionEngine, preampDB: Float = -6) -> AutoEQProfile {
    AutoEQProfile(
        id: "test-\(engine.rawValue)", name: "Test", source: .imported, preampDB: preampDB,
        filters: [
            AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: 5.5, q: 0.7),
            AutoEQFilter(type: .peaking, frequency: 200, gainDB: -2.5, q: 0.5),
            AutoEQFilter(type: .peaking, frequency: 3200, gainDB: 3, q: 2),
            AutoEQFilter(type: .peaking, frequency: 6000, gainDB: -4, q: 4),
            AutoEQFilter(type: .highShelf, frequency: 10_000, gainDB: 2, q: 0.7),
        ],
        engine: engine)
}

private func gentleProfile(engine: AutoEQCorrectionEngine) -> AutoEQProfile {
    AutoEQProfile(
        id: "gentle-\(engine.rawValue)", name: "Gentle", source: .imported, preampDB: 0,
        filters: [
            AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 4, q: 1),
            AutoEQFilter(type: .highShelf, frequency: 8000, gainDB: -3, q: 0.7),
        ],
        engine: engine)
}

private let graphicPoints: [AutoEQCurvePoint] = [
    (20, -2), (50, 3), (100, 5), (200, 2), (500, 0), (1000, -1),
    (2000, 0), (4000, 3), (8000, -4), (16_000, 2), (20_000, 0),
].map { AutoEQCurvePoint(frequency: $0.0, gainDB: Float($0.1)) }

private func graphicProfile(engine: AutoEQCorrectionEngine = .minimumPhaseFIR) -> AutoEQProfile {
    AutoEQProfile(
        id: "graphic-\(engine.rawValue)", name: "Graphic", source: .imported, preampDB: 0, filters: [],
        kind: .graphic, engine: engine, curve: graphicPoints)
}

private func designTarget(_ profile: AutoEQProfile, sampleRate: Double) -> [Double] {
    AutoEQResponse.designGrid(
        of: profile, sampleRate: sampleRate, gridSize: FIRDesign.gridSize(sampleRate: sampleRate))
}

private func exactGain(_ profile: AutoEQProfile, at frequency: Double) -> Double {
    AutoEQResponse.exactCurve(of: profile, frequencies: [frequency])[0]
}

/// Left channel of what the processor answers to one full-scale sample on both channels.
private func impulseResponse(of processor: AutoEQProcessor, frames: Int) -> [Float] {
    let chunk = 512
    var left: [Float] = []
    left.reserveCapacity(frames + chunk)
    var isFirst = true
    while left.count < frames {
        var buffer = [Float](repeating: 0, count: chunk * 2)
        if isFirst {
            buffer[0] = 1
            buffer[1] = 1
            isFirst = false
        }
        buffer.withUnsafeMutableBufferPointer { samples in
            processor.process(input: UnsafePointer(samples.baseAddress!), output: samples.baseAddress!, frameCount: chunk)
        }
        for i in 0..<chunk { left.append(buffer[2 * i]) }
    }
    return left
}

// MARK: - Filter Design

@Suite("FIRDesign — minimum phase")
struct FIRDesignMinimumPhaseTests {

    @Test("A flat curve gives a plain impulse")
    func flatCurveIsImpulse() throws {
        let size = FIRDesign.gridSize(sampleRate: 48_000)
        let kernel = try #require(FIRDesign.minimumPhase(
            targetDB: [Double](repeating: 0, count: size / 2 + 1), sampleRate: 48_000))
        #expect(kernel.latencySamples == 0)
        #expect(abs(kernel.taps[0] - 1) < 1e-4)
        #expect(kernel.taps.dropFirst().allSatisfy { abs($0) < 1e-4 })
    }

    @Test("Follows the exact curve with no latency", arguments: [44_100.0, 48_000.0, 96_000.0])
    func followsCurve(sampleRate: Double) throws {
        let profile = testProfile(engine: .minimumPhaseFIR)
        let kernel = try #require(FIRDesign.minimumPhase(
            targetDB: designTarget(profile, sampleRate: sampleRate), sampleRate: sampleRate))

        #expect(kernel.latencySamples == 0)
        #expect(FIRDesign.minimumPhaseLengths(sampleRate: sampleRate).contains(kernel.taps.count))
        #expect(kernel.maxErrorDB < 0.2)
        for frequency in [30.0, 100, 1000, 3200, 6000, 10_000, 15_000] {
            let gain = FIRDesign.responseDB(of: kernel.taps, at: frequency, sampleRate: sampleRate)
            #expect(abs(gain - exactGain(profile, at: frequency)) < 0.25, "at \(frequency) Hz")
        }
    }

    @Test("Energy sits at the start of the filter")
    func energyAtStart() throws {
        let profile = testProfile(engine: .minimumPhaseFIR)
        let kernel = try #require(FIRDesign.minimumPhase(
            targetDB: designTarget(profile, sampleRate: 48_000), sampleRate: 48_000))
        let total = kernel.taps.reduce(0) { $0 + Double($1) * Double($1) }
        let start = kernel.taps.prefix(kernel.taps.count / 4).reduce(0) { $0 + Double($1) * Double($1) }
        #expect(start / total > 0.99)
    }

    @Test("Renders a graphic curve")
    func graphicCurve() throws {
        let profile = graphicProfile()
        let kernel = try #require(FIRDesign.minimumPhase(
            targetDB: designTarget(profile, sampleRate: 48_000), sampleRate: 48_000))
        #expect(kernel.maxErrorDB < 0.25)
        for point in graphicPoints where point.frequency >= 100 && point.frequency <= 16_000 {
            let gain = FIRDesign.responseDB(of: kernel.taps, at: point.frequency, sampleRate: 48_000)
            #expect(abs(gain - Double(point.gainDB)) < 0.25, "at \(point.frequency) Hz")
        }
    }

    @Test("A grid of the wrong size is refused")
    func wrongGridSize() {
        #expect(FIRDesign.minimumPhase(targetDB: [0, 0, 0], sampleRate: 48_000) == nil)
        #expect(FIRDesign.linearPhase(targetDB: [0, 0, 0], sampleRate: 48_000) == nil)
    }
}

@Suite("FIRDesign — linear phase")
struct FIRDesignLinearPhaseTests {

    @Test("Symmetric, with a latency of half its length", arguments: [44_100.0, 48_000.0, 96_000.0])
    func symmetric(sampleRate: Double) throws {
        let profile = testProfile(engine: .linearPhaseFIR)
        let kernel = try #require(FIRDesign.linearPhase(
            targetDB: designTarget(profile, sampleRate: sampleRate), sampleRate: sampleRate))

        let count = kernel.taps.count
        #expect(count == 2 * kernel.latencySamples + 1)
        for i in 0..<count / 2 {
            #expect(abs(kernel.taps[i] - kernel.taps[count - 1 - i]) < 1e-6)
        }
        // Low latency: this curve fits in well under 20 ms
        #expect(Double(kernel.latencySamples) / sampleRate < 0.02)
        for frequency in [100.0, 1000, 3200, 6000, 10_000, 15_000] {
            let gain = FIRDesign.responseDB(of: kernel.taps, at: frequency, sampleRate: sampleRate)
            #expect(abs(gain - exactGain(profile, at: frequency)) < 0.6, "at \(frequency) Hz")
        }
    }

    @Test("A gentle curve gets the shortest filter")
    func gentleCurveIsShort() throws {
        let profile = gentleProfile(engine: .linearPhaseFIR)
        let kernel = try #require(FIRDesign.linearPhase(
            targetDB: designTarget(profile, sampleRate: 48_000), sampleRate: 48_000))
        #expect(kernel.latencySamples == FIRDesign.linearPhaseHalfLengths(sampleRate: 48_000)[0])
        #expect(Double(kernel.latencySamples) / 48_000 < 0.004)
    }

    @Test("Latency in milliseconds does not grow with the sample rate")
    func latencyIndependentOfRate() throws {
        let profile = testProfile(engine: .linearPhaseFIR)
        let at48 = try #require(FIRDesign.linearPhase(
            targetDB: designTarget(profile, sampleRate: 48_000), sampleRate: 48_000))
        let at96 = try #require(FIRDesign.linearPhase(
            targetDB: designTarget(profile, sampleRate: 96_000), sampleRate: 96_000))
        #expect(at96.latencySamples == 2 * at48.latencySamples)
    }

    @Test("Design sizes scale with the sample rate")
    func rateScale() {
        #expect(FIRDesign.rateScale(sampleRate: 44_100) == 1)
        #expect(FIRDesign.rateScale(sampleRate: 48_000) == 1)
        #expect(FIRDesign.rateScale(sampleRate: 88_200) == 2)
        #expect(FIRDesign.rateScale(sampleRate: 96_000) == 2)
        #expect(FIRDesign.rateScale(sampleRate: 192_000) == 4)
    }
}

// MARK: - Convolver

@Suite("FIRConvolver")
struct FIRConvolverTests {

    @Test("Matches direct convolution for every filter length and buffer size",
          arguments: [1, 10, 64, 65, 200, 1024, 1025, 2500])
    func matchesDirectConvolution(length: Int) throws {
        var noise = Noise(seed: UInt64(length))
        let taps = noise.samples(length, scale: 0.05)
        let left = noise.samples(3000)
        let right = noise.samples(3000)
        let convolver = try #require(FIRConvolver(taps: taps))
        #expect(convolver.tapCount == length)

        // Each channel cut differently, with sizes on both sides of every block size
        let outLeft = run(convolver, channel: 0, input: left, chunks: [1, 7, 64, 100, 513, 1024, 31, 2048, 3])
        let outRight = run(convolver, channel: 1, input: right, chunks: [512, 63, 65, 1, 1, 1023, 256])

        #expect(maxDifference(outLeft, directConvolution(left, taps)) < 1e-3)
        #expect(maxDifference(outRight, directConvolution(right, taps)) < 1e-3)
    }

    @Test("No delay: the first tap acts on the very first sample")
    func noDelay() throws {
        var taps = [Float](repeating: 0, count: 4096)
        taps[0] = 0.5
        taps[4095] = 0.25
        let convolver = try #require(FIRConvolver(taps: taps))
        var input = [Float](repeating: 0, count: 5000)
        input[0] = 1
        let output = run(convolver, channel: 0, input: input, chunks: [1, 2, 3, 480])
        #expect(abs(output[0] - 0.5) < 1e-5)
        #expect(abs(output[4095] - 0.25) < 1e-4)
        #expect(output[1..<4095].allSatisfy { abs($0) < 1e-4 })
    }

    @Test("Processes interleaved stereo in place")
    func inPlaceInterleaved() throws {
        var noise = Noise(seed: 7)
        let taps = noise.samples(1500, scale: 0.05)
        let left = noise.samples(2400)
        let right = noise.samples(2400)
        let convolver = try #require(FIRConvolver(taps: taps))

        var interleaved = [Float](repeating: 0, count: 4800)
        for i in 0..<2400 {
            interleaved[2 * i] = left[i]
            interleaved[2 * i + 1] = right[i]
        }
        interleaved.withUnsafeMutableBufferPointer { samples in
            var done = 0
            while done < 2400 {
                let n = min(480, 2400 - done)
                let frame = samples.baseAddress! + 2 * done
                convolver.process(channel: 0, input: frame, inputStride: 2, output: frame, outputStride: 2, count: n)
                convolver.process(channel: 1, input: frame + 1, inputStride: 2, output: frame + 1, outputStride: 2, count: n)
                done += n
            }
        }
        let expectedLeft = directConvolution(left, taps)
        let expectedRight = directConvolution(right, taps)
        var worst: Float = 0
        for i in 0..<2400 {
            worst = max(worst, abs(interleaved[2 * i] - expectedLeft[i]), abs(interleaved[2 * i + 1] - expectedRight[i]))
        }
        #expect(worst < 1e-3)
    }

    @Test("An empty filter is refused")
    func emptyFilter() {
        #expect(FIRConvolver(taps: []) == nil)
    }
}

// MARK: - Processor (crossfades)

@Suite("FIRProcessor")
struct FIRProcessorTests {

    /// Feeds `frames` frames of a constant 1 and returns the left channel.
    private func render(_ processor: FIRProcessor, frames: Int) -> [Float] {
        var left: [Float] = []
        var remaining = frames
        while remaining > 0 {
            let n = min(256, remaining)
            var buffer = [Float](repeating: 1, count: n * 2)
            processor.process(&buffer, frameCount: n)
            for i in 0..<n {
                left.append(buffer[2 * i])
                // Both channels get the same filter
                if buffer[2 * i + 1] != buffer[2 * i] { left[left.count - 1] = .nan }
            }
            remaining -= n
        }
        return left
    }

    @Test("Without a filter the signal is untouched")
    func passthrough() {
        let processor = FIRProcessor()
        #expect(!processor.hasFilter)
        #expect(render(processor, frames: 1000).allSatisfy { $0 == 1 })
    }

    @Test("A filter installed before audio starts applies from the first sample")
    func installBeforeAudio() throws {
        let processor = FIRProcessor()
        processor.install(try #require(FIRConvolver(taps: [0.5], latencySamples: 12)), sampleRate: 48_000)
        #expect(processor.hasFilter)
        #expect(processor.latencySamples == 12)
        #expect(render(processor, frames: 1000).allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    @Test("A filter installed while audio runs fades in without a step")
    func fadesIn() throws {
        let processor = FIRProcessor()
        _ = render(processor, frames: 256)
        processor.install(try #require(FIRConvolver(taps: [0.5])), sampleRate: 48_000)

        let fadeFrames = Int(FIRProcessor.fadeSeconds * 48_000)
        let output = render(processor, frames: fadeFrames + 512)
        #expect(abs(output[0] - 1) < 1e-3)
        #expect(output.suffix(256).allSatisfy { abs($0 - 0.5) < 1e-6 })
        var largestStep: Float = 0
        for i in 1..<output.count {
            #expect(output[i] <= output[i - 1] + 1e-6)
            largestStep = max(largestStep, abs(output[i] - output[i - 1]))
        }
        #expect(largestStep < 1.5 * 0.5 / Float(fadeFrames))
    }

    @Test("Removing the filter fades back to the untouched signal")
    func fadesOut() throws {
        let processor = FIRProcessor()
        processor.install(try #require(FIRConvolver(taps: [0.5])), sampleRate: 48_000)
        _ = render(processor, frames: 256)
        processor.install(nil, sampleRate: 48_000)
        #expect(!processor.hasFilter)

        let output = render(processor, frames: 2048)
        #expect(abs(output[0] - 0.5) < 1e-3)
        #expect(output.suffix(256).allSatisfy { $0 == 1 })
    }

    @Test("A filter that arrives during a crossfade waits for its end, then fades in")
    func installDuringFade() async throws {
        let processor = FIRProcessor()
        _ = render(processor, frames: 256)
        processor.install(try #require(FIRConvolver(taps: [0.5])), sampleRate: 48_000)
        _ = render(processor, frames: 256)   // first crossfade under way
        processor.install(try #require(FIRConvolver(taps: [0.25])), sampleRate: 48_000)

        // The first crossfade completes on the first filter
        let first = render(processor, frames: 2048)
        #expect(first.suffix(256).allSatisfy { abs($0 - 0.5) < 1e-6 })

        // The waiting install retries on the main queue
        try await Task.sleep(for: .milliseconds(200))
        let second = render(processor, frames: 2048)
        #expect(second.suffix(256).allSatisfy { abs($0 - 0.25) < 1e-6 })
    }

    @Test("With audio stopped, a new filter replaces the old one directly")
    func installWhileIdle() throws {
        let processor = FIRProcessor()
        processor.install(try #require(FIRConvolver(taps: [0.5])), sampleRate: 48_000)
        _ = render(processor, frames: 256)
        processor.install(try #require(FIRConvolver(taps: [0.25])), sampleRate: 48_000, audioThreadIdle: true)
        #expect(render(processor, frames: 256).allSatisfy { abs($0 - 0.25) < 1e-6 })
    }
}

// MARK: - AutoEQProcessor

@Suite("AutoEQProcessor — correction engines")
struct AutoEQProcessorEngineTests {

    /// The cookbook biquads are only checked where they follow the exact curve at 48 kHz;
    /// the linear-phase filter trades some accuracy in the bass for a short latency.
    @Test("Every engine plays the preset's curve, preamp included", arguments: AutoEQCorrectionEngine.allCases)
    func playsCurve(engine: AutoEQCorrectionEngine) {
        let frequencies: [Double] = engine == .biquad ? [100, 1000, 3200] : [100, 1000, 3200, 6000, 12_000]
        let tolerance = engine == .linearPhaseFIR ? 0.6 : 0.3
        let profile = testProfile(engine: engine)
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(profile)
        #expect(processor.isEnabled)

        let response = impulseResponse(of: processor, frames: 16_384)
        for frequency in frequencies {
            let gain = FIRDesign.responseDB(of: response, at: frequency, sampleRate: 48_000)
            let expected = exactGain(profile, at: frequency) + Double(profile.preampDB)
            #expect(abs(gain - expected) < tolerance, "\(engine.displayName) at \(frequency) Hz")
        }
    }

    @Test("Only the linear-phase engine adds latency, and it is the one reported")
    func latency() {
        for engine in [AutoEQCorrectionEngine.biquad, .matchedBiquad, .minimumPhaseFIR] {
            let processor = AutoEQProcessor(sampleRate: 48_000)
            processor.updateProfile(testProfile(engine: engine))
            #expect(processor.latencySamples == 0)
            // The response starts on the first sample
            #expect(abs(impulseResponse(of: processor, frames: 512)[0]) > 0.1)
        }

        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(testProfile(engine: .linearPhaseFIR))
        let latency = processor.latencySamples
        #expect(latency > 0)
        #expect(latency < 960)   // under 20 ms
        let response = impulseResponse(of: processor, frames: 4096)
        let peak = response.indices.max { abs(response[$0]) < abs(response[$1]) }
        #expect(peak == latency)
    }

    @Test("A graphic preset is rendered even when left on a biquad engine")
    func graphicPreset() {
        let profile = graphicProfile(engine: .biquad)
        #expect(profile.effectiveEngine == .minimumPhaseFIR)
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(profile)
        #expect(processor.isEnabled)

        let response = impulseResponse(of: processor, frames: 16_384)
        for point in graphicPoints where point.frequency >= 200 && point.frequency <= 16_000 {
            let gain = FIRDesign.responseDB(of: response, at: point.frequency, sampleRate: 48_000)
            #expect(abs(gain - Double(point.gainDB)) < 0.3, "at \(point.frequency) Hz")
        }
    }

    @Test("A FIR filter is redesigned when the sample rate changes")
    func sampleRateChange() {
        let profile = testProfile(engine: .minimumPhaseFIR)
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(profile)
        _ = impulseResponse(of: processor, frames: 1024)

        processor.updateSampleRate(96_000)
        // Let the previous impulse leave nothing behind, then measure at the new rate
        let response = impulseResponse(of: processor, frames: 32_768)
        for frequency in [100.0, 1000, 6000] {
            let gain = FIRDesign.responseDB(of: response, at: frequency, sampleRate: 96_000)
            let expected = exactGain(profile, at: frequency) + Double(profile.preampDB)
            #expect(abs(gain - expected) < 0.3, "at \(frequency) Hz")
        }
    }

    @Test("Switching between engines keeps the curve")
    func switchEngines() {
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(testProfile(engine: .minimumPhaseFIR))
        _ = impulseResponse(of: processor, frames: 1024)

        // FIR → biquad: the FIR filter fades out, the cascade takes over
        processor.updateProfile(testProfile(engine: .matchedBiquad))
        _ = impulseResponse(of: processor, frames: 8192)
        var response = impulseResponse(of: processor, frames: 16_384)
        var gain = FIRDesign.responseDB(of: response, at: 1000, sampleRate: 48_000)
        let expected = exactGain(testProfile(engine: .biquad), at: 1000) - 6
        #expect(abs(gain - expected) < 0.3)

        // biquad → preamp only (correction switched off): just the preamp remains
        var preampOnly = testProfile(engine: .matchedBiquad)
        preampOnly.filters = []
        processor.updateProfile(preampOnly)
        #expect(processor.isEnabled)
        response = impulseResponse(of: processor, frames: 1024)
        gain = FIRDesign.responseDB(of: response, at: 1000, sampleRate: 48_000)
        #expect(abs(gain - (-6)) < 0.05)
    }

    @Test("Without a profile a biquad correction stops at once")
    func biquadStopsAtOnce() {
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(testProfile(engine: .biquad))
        _ = impulseResponse(of: processor, frames: 512)
        processor.updateProfile(nil)
        #expect(!processor.isEnabled)
    }

    @Test("Without a profile a FIR correction fades out, then stops")
    func firFadesOutThenStops() async throws {
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(testProfile(engine: .minimumPhaseFIR))
        _ = impulseResponse(of: processor, frames: 512)

        processor.updateProfile(nil)
        #expect(processor.isEnabled)   // still playing the fade-out
        _ = impulseResponse(of: processor, frames: 4096)
        try await Task.sleep(for: .milliseconds(900))
        #expect(!processor.isEnabled)
    }

    @Test("A profile applied during the fade-out cancels the stop")
    func newProfileCancelsStop() async throws {
        let processor = AutoEQProcessor(sampleRate: 48_000)
        processor.updateProfile(testProfile(engine: .minimumPhaseFIR))
        _ = impulseResponse(of: processor, frames: 512)
        processor.updateProfile(nil)
        processor.updateProfile(testProfile(engine: .biquad))
        try await Task.sleep(for: .milliseconds(900))
        #expect(processor.isEnabled)
    }
}

// MARK: - Kernel Cache

@Suite("FIRKernelCache")
struct FIRKernelCacheTests {

    @Test("Designs the kernel of FIR presets only, the same one each time")
    func kernels() throws {
        let profile = testProfile(engine: .minimumPhaseFIR)
        let first = try #require(FIRKernelCache.kernel(for: profile, sampleRate: 48_000))
        let second = try #require(FIRKernelCache.kernel(for: profile, sampleRate: 48_000))
        #expect(first == second)
        #expect(first.latencySamples == 0)

        let other = try #require(FIRKernelCache.kernel(for: gentleProfile(engine: .minimumPhaseFIR), sampleRate: 48_000))
        #expect(other != first)
        #expect(FIRKernelCache.kernel(for: testProfile(engine: .biquad), sampleRate: 48_000) == nil)
        #expect(FIRKernelCache.kernel(for: testProfile(engine: .matchedBiquad), sampleRate: 48_000) == nil)
    }

    @Test("Reports latency for linear phase only")
    func latency() {
        #expect(FIRKernelCache.latencyMilliseconds(of: testProfile(engine: .biquad), sampleRate: 48_000) == 0)
        #expect(FIRKernelCache.latencyMilliseconds(of: testProfile(engine: .minimumPhaseFIR), sampleRate: 48_000) == 0)
        let linear = FIRKernelCache.latencyMilliseconds(of: testProfile(engine: .linearPhaseFIR), sampleRate: 48_000)
        #expect(linear > 1)
        #expect(linear < 20)
    }
}
