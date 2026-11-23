// FineTuneTests/OutputFanOutTests.swift
//
// A tap that plays on several devices renders each device's buffer through that device's
// own chain: its own AutoEQ and its own master volume, as if the app played on it alone.

import Testing
import Foundation
import AudioToolbox
@testable import FineTune

/// A list of stereo interleaved buffers, freed by `release()`.
private struct StereoBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    let data: [UnsafeMutablePointer<Float>]
    let frames: Int

    init(count: Int, frames: Int) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: count)
        var data: [UnsafeMutablePointer<Float>] = []
        for i in 0..<count {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            samples.initialize(repeating: 0, count: frames * 2)
            data.append(samples)
            list[i] = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples))
        }
        self.data = data
    }

    /// A single sample of `amplitude` on both channels at frame 0, silence after.
    func setImpulse(_ amplitude: Float, buffer: Int = 0) {
        let samples = data[buffer]
        for i in 0..<(frames * 2) { samples[i] = 0 }
        samples[0] = amplitude
        samples[1] = amplitude
    }

    func samples(_ buffer: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: data[buffer], count: frames * 2))
    }

    func release() {
        for samples in data { samples.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

private let boost = AutoEQProfile(
    id: "boost", name: "Boost", source: .imported, preampDB: -6,
    filters: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 6, q: 1)])

private var plainSettings: OutputFanOut.Settings {
    var loudness = LoudnessEqualizerSettings()
    loudness.enabled = false
    return OutputFanOut.Settings(
        eqSettings: nil, autoEQPreampEnabled: true, loudnessEqualizerSettings: loudness,
        loudnessCompensationEnabled: false, loudnessVolume: 1)
}

/// What an AutoEQ processor of its own makes of the same impulse.
private func reference(_ profile: AutoEQProfile, impulse: Float, frames: Int) -> [Float] {
    let processor = AutoEQProcessor(sampleRate: 48_000)
    processor.updateProfile(profile)
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer[0] = impulse
    buffer[1] = impulse
    buffer.withUnsafeMutableBufferPointer { samples in
        processor.process(input: UnsafePointer(samples.baseAddress!), output: samples.baseAddress!, frameCount: frames)
    }
    return buffer
}

private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

private func render(_ fanOut: OutputFanOut, input: StereoBuffers, output: StereoBuffers) -> Bool {
    fanOut.render(
        inputBuffers: input.list, outputBuffers: output.list, targetVolume: 1,
        crossfadeMultiplier: 1, outputGateMultiplier: 1, rampCoefficient: 1)
}

@Suite("OutputFanOut — one chain per output device")
struct OutputFanOutTests {

    @Test("Each device gets its own AutoEQ and its own master volume")
    func perDeviceChains() throws {
        let fanOut = try #require(OutputFanOut(
            deviceUIDs: ["a", "b"], sampleRate: 48_000, settings: plainSettings,
            autoEQProfile: { $0 == "a" ? boost : nil },
            gain: { $0 == "a" ? 0.5 : 1.0 },
            initialVolume: 1, preferredChannels: { _ in (0, 1) }))
        let input = StereoBuffers(count: 1, frames: 512)
        let output = StereoBuffers(count: 2, frames: 512)
        defer { input.release(); output.release() }

        input.setImpulse(0.1)
        #expect(render(fanOut, input: input, output: output))

        // Device A: its correction, at half volume
        #expect(maxDifference(output.samples(0), reference(boost, impulse: 0.05, frames: 512)) < 1e-6)
        // Device B: no correction, full volume, untouched
        var untouched = [Float](repeating: 0, count: 1024)
        untouched[0] = 0.1
        untouched[1] = 0.1
        #expect(output.samples(1) == untouched)
    }

    @Test("Gains and corrections can change per device afterwards")
    func updates() throws {
        let fanOut = try #require(OutputFanOut(
            deviceUIDs: ["a", "b"], sampleRate: 48_000, settings: plainSettings,
            autoEQProfile: { _ in nil }, gain: { _ in 1 },
            initialVolume: 1, preferredChannels: { _ in (0, 1) }))
        let input = StereoBuffers(count: 1, frames: 512)
        let output = StereoBuffers(count: 2, frames: 512)
        defer { input.release(); output.release() }

        fanOut.setGain(0.25, for: "b")
        fanOut.updateAutoEQProfile(boost, for: "b")
        input.setImpulse(0.1)
        #expect(render(fanOut, input: input, output: output))

        #expect(maxDifference(output.samples(1), reference(boost, impulse: 0.025, frames: 512)) < 1e-6)
        #expect(output.samples(0)[0] == 0.1)
        #expect(output.samples(0).dropFirst(2).allSatisfy { $0 == 0 })
    }

    @Test("Buffers that do not match the devices are left to the single-chain path")
    func mismatch() throws {
        let fanOut = try #require(OutputFanOut(
            deviceUIDs: ["a", "b"], sampleRate: 48_000, settings: plainSettings,
            autoEQProfile: { _ in nil }, gain: { _ in 1 },
            initialVolume: 1, preferredChannels: { _ in (0, 1) }))
        let input = StereoBuffers(count: 1, frames: 64)
        let output = StereoBuffers(count: 3, frames: 64)
        defer { input.release(); output.release() }
        #expect(!render(fanOut, input: input, output: output))
    }

    @Test("One device needs no fan-out")
    func singleDevice() {
        #expect(OutputFanOut(
            deviceUIDs: ["a"], sampleRate: 48_000, settings: plainSettings,
            autoEQProfile: { _ in nil }, gain: { _ in 1 },
            initialVolume: 1, preferredChannels: { _ in (0, 1) }) == nil)
    }
}

@Suite("ProcessTapController — fanned-out aggregates")
struct AggregateFanOutPlanTests {

    @Test("Several plain single-stream devices: one output stream each, not stacked")
    func fannedOut() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["a", "b", "c"], expand: { _ in nil }, outputStreamCount: { _ in 1 })
        #expect(plan.isFannedOut)
        #expect(!plan.isStacked)
        #expect(plan.subDeviceUIDs == ["a", "b", "c"])
        #expect(plan.clockDeviceUID == "a")
    }

    @Test("A device with several output streams keeps the stacked mirror")
    func multiStreamDeviceStaysStacked() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["a", "motu"], expand: { _ in nil },
            outputStreamCount: { $0 == "motu" ? 2 : 1 })
        #expect(!plan.isFannedOut)
        #expect(plan.isStacked)
    }

    @Test("A selection that includes a user aggregate keeps the stacked mirror")
    func aggregateInSelectionStaysStacked() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg", "speaker"], expand: { $0 == "agg" ? ["scarlett"] : nil },
            outputStreamCount: { _ in 1 })
        #expect(!plan.isFannedOut)
        #expect(plan.isStacked)
    }

    @Test("A single device is never fanned out")
    func singleDevice() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["a"], expand: { _ in nil }, outputStreamCount: { _ in 1 })
        #expect(!plan.isFannedOut)
    }
}
