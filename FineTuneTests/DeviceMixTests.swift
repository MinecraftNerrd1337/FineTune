// FineTuneTests/DeviceMixTests.swift
//
// The real-time half of the per-DAC routing mode: each app's chain in its slot, the sum of the
// slots, and the device's AutoEQ and limiter run once on that sum. Pure buffers: no audio
// device needed.

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

    /// Every frame of `buffer` set to (left, right).
    func fill(_ buffer: Int, left: Float, right: Float) {
        for frame in 0..<frames {
            data[buffer][frame * 2] = left
            data[buffer][frame * 2 + 1] = right
        }
    }

    func fill(_ buffer: Int, _ value: Float) { fill(buffer, left: value, right: value) }

    /// One sample of `amplitude` on both channels at frame 0, silence after.
    func setImpulse(_ amplitude: Float, buffer: Int) {
        fill(buffer, 0)
        data[buffer][0] = amplitude
        data[buffer][1] = amplitude
    }

    func samples(_ buffer: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: data[buffer], count: frames * 2))
    }

    func release() {
        for samples in data { samples.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

private let frames = 512
private let sampleRate = 48_000.0

private var neutral: DeviceMixSlot.Settings {
    var settings = DeviceMixSlot.Settings()
    settings.loudnessEqualizerSettings.enabled = false
    return settings
}

/// Active slots with the neutral chain; `openGate` skips the soft start.
private func makeSlots(_ count: Int, active: Int? = nil, openGate: Bool = true) -> [DeviceMixSlot] {
    (0..<count).map { index in
        let slot = DeviceMixSlot(index: index, maxFrames: 4096)
        if index < (active ?? count) {
            slot.activate(settings: neutral, sampleRate: sampleRate)
            if openGate { slot.gatePhase = 2 }
        }
        return slot
    }
}

/// Mixes `inputs` into `output` with an instant volume ramp.
@discardableResult
private func mix(
    _ inputs: StereoBuffers, into output: StereoBuffers, slots: [DeviceMixSlot],
    autoEQ: AutoEQProcessor? = nil, forceSilence: Bool = false,
    preferred: (Int, Int) = (0, 1), fadeStep: Float = 1.0 / 2400, hostTime: UInt64 = 1000
) -> Int {
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 2)
    defer { scratch.deallocate() }
    return DeviceMixRenderer.render(
        inputs: inputs.list, outputs: output.list, slots: slots, mix: scratch, maxFrames: 4096,
        autoEQ: autoEQ, forceSilence: forceSilence, preferredLeft: preferred.0, preferredRight: preferred.1,
        rampCoefficient: 1, gateRampSamples: 1920, fadeStep: fadeStep, resumed: false, hostTime: hostTime)
}

private func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

private let boost = AutoEQProfile(
    id: "boost", name: "Boost", source: .imported, preampDB: -6,
    filters: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 6, q: 1)])

@Suite("DeviceMix — one aggregate per output device")
struct DeviceMixTests {

    @Test("The device plays the sum of its apps")
    func sumsTheSlots() {
        let inputs = StereoBuffers(count: 2, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.1)
        inputs.fill(1, 0.2)

        let mixed = mix(inputs, into: output, slots: makeSlots(2))

        #expect(mixed == 2)
        #expect(maxDifference(output.samples(0), [Float](repeating: 0.3, count: frames * 2)) < 1e-6)
    }

    @Test("One app through a neutral chain is bit-transparent")
    func singleAppIsTransparent() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        for i in 0..<(frames * 2) { inputs.data[0][i] = Float(i % 97) / 100 - 0.48 }

        mix(inputs, into: output, slots: makeSlots(1))

        #expect(output.samples(0) == inputs.samples(0))
    }

    @Test("Inactive and muted apps add nothing")
    func inactiveAndMutedSlots() {
        let inputs = StereoBuffers(count: 3, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.1)
        inputs.fill(1, 0.2)
        inputs.fill(2, 0.4)
        let slots = makeSlots(3, active: 2)
        slots[1].isMuted = true

        let mixed = mix(inputs, into: output, slots: slots)

        #expect(mixed == 1)
        #expect(output.samples(0) == inputs.samples(0))
    }

    @Test("Each app keeps its own volume")
    func perAppVolume() {
        let inputs = StereoBuffers(count: 2, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.2)
        inputs.fill(1, 0.2)
        let slots = makeSlots(2)
        slots[0].volume = 0.5

        mix(inputs, into: output, slots: slots)

        #expect(maxDifference(output.samples(0), [Float](repeating: 0.3, count: frames * 2)) < 1e-6)
    }

    @Test("A new app fades in through the soft-start gate")
    func softStart() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.5)
        let slots = makeSlots(1, openGate: false)

        // The first buffer with audio arms the gate, the next ones ramp it up (40 ms)
        mix(inputs, into: output, slots: slots)
        #expect(output.samples(0).allSatisfy { $0 == 0 })
        mix(inputs, into: output, slots: slots)
        let ramping = output.samples(0)[0]
        #expect(ramping > 0 && ramping < 0.5)
        for _ in 0..<6 { mix(inputs, into: output, slots: slots) }
        #expect(output.samples(0).allSatisfy { $0 == 0.5 })
    }

    @Test("A device switch fades the slot out, and in")
    func switchFade() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.5)
        let slots = makeSlots(1)

        slots[0].fadeTarget = 0
        mix(inputs, into: output, slots: slots)
        let fading = output.samples(0)
        #expect(fading[0] < 0.5 && fading[0] > fading[frames * 2 - 2])
        for _ in 0..<5 { mix(inputs, into: output, slots: slots) }
        #expect(output.samples(0).allSatisfy { $0 == 0 })
        #expect(slots[0].fade == 0)

        // 2400 frames of fade: the sixth buffer plays at full level throughout
        slots[0].fadeTarget = 1
        for _ in 0..<6 { mix(inputs, into: output, slots: slots) }
        #expect(output.samples(0).allSatisfy { $0 == 0.5 })
    }

    @Test("A slot that starts faded out stays silent until faded in")
    func startsFadedOut() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.5)
        let slot = DeviceMixSlot(index: 0, maxFrames: 4096)
        slot.activate(settings: neutral, sampleRate: sampleRate, fadedIn: false)

        mix(inputs, into: output, slots: [slot])

        #expect(output.samples(0).allSatisfy { $0 == 0 })
        #expect(slot.lastAudibleHostTime == 1000)
    }

    @Test("Force silence zeroes the device")
    func forceSilence() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.5)
        output.fill(0, 0.7)

        let mixed = mix(inputs, into: output, slots: makeSlots(1), forceSilence: true)

        #expect(mixed == 0)
        #expect(output.samples(0).allSatisfy { $0 == 0 })
    }

    @Test("The sum is limited below full scale")
    func limitsTheSum() {
        let inputs = StereoBuffers(count: 2, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.8)
        inputs.fill(1, 0.8)

        mix(inputs, into: output, slots: makeSlots(2))

        #expect(output.samples(0).allSatisfy { $0 > SoftLimiter.threshold && $0 <= 1 })
    }

    @Test("AutoEQ runs once, on the sum")
    func autoEQOnTheSum() {
        let inputs = StereoBuffers(count: 2, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.setImpulse(0.3, buffer: 0)
        inputs.setImpulse(0.2, buffer: 1)
        let autoEQ = AutoEQProcessor(sampleRate: sampleRate)
        autoEQ.updateProfile(boost)

        let reference = AutoEQProcessor(sampleRate: sampleRate)
        reference.updateProfile(boost)
        var expected = [Float](repeating: 0, count: frames * 2)
        expected[0] = 0.5
        expected[1] = 0.5
        expected.withUnsafeMutableBufferPointer { samples in
            reference.process(input: UnsafePointer(samples.baseAddress!), output: samples.baseAddress!, frameCount: frames)
        }

        mix(inputs, into: output, slots: makeSlots(2), autoEQ: autoEQ)

        #expect(maxDifference(output.samples(0), expected) < 1e-5)
    }

    @Test("The mix goes to the device's preferred stereo channels")
    func preferredChannels() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, left: 0.1, right: 0.2)

        mix(inputs, into: output, slots: makeSlots(1), preferred: (1, 0))

        let out = output.samples(0)
        #expect(out[0] == 0.2 && out[1] == 0.1)
    }

    @Test("Hardware inputs ahead of the taps are not mixed")
    func skipsHardwareInputs() {
        let inputs = StereoBuffers(count: 3, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.9)  // the device's own input
        inputs.fill(1, 0.1)
        inputs.fill(2, 0.2)

        mix(inputs, into: output, slots: makeSlots(2))

        #expect(maxDifference(output.samples(0), [Float](repeating: 0.3, count: frames * 2)) < 1e-6)
    }

    @Test("A slot records when its app's audio arrives")
    func arrival() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        let slots = makeSlots(1)

        mix(inputs, into: output, slots: slots, hostTime: 10)
        #expect(slots[0].lastAudibleHostTime == 0)
        #expect(slots[0].lastRenderHostTime == 10)

        inputs.fill(0, 0.25)
        mix(inputs, into: output, slots: slots, hostTime: 20)
        #expect(slots[0].lastAudibleHostTime == 20)
        #expect(slots[0].peakLevel > 0)
    }

    @Test("A rebuild for another sample rate keeps the app's settings")
    func rebuildKeepsSettings() {
        var settings = neutral
        settings.loudnessCompensationEnabled = true
        settings.loudnessVolume = 0.3
        let slot = DeviceMixSlot(index: 0, maxFrames: 4096)
        slot.activate(settings: settings, sampleRate: sampleRate)
        slot.volume = 0.4
        slot.isMuted = true
        let firstEQ = slot.eq

        slot.rebuild(sampleRate: 96_000)

        #expect(slot.isActive)
        #expect(slot.volume == 0.4)
        #expect(slot.isMuted)
        #expect(slot.settings.loudnessCompensationEnabled)
        #expect(slot.settings.loudnessVolume == 0.3)
        #expect(slot.eq !== firstEQ)
        #expect(slot.fade == 1)
    }

    @Test("Per-DAC routing is off unless saved on")
    func routingSetting() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!decoded.perDeviceMixingEnabled)
        var settings = AppSettings()
        settings.perDeviceMixingEnabled = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.perDeviceMixingEnabled)
    }

    @Test("A released slot is mixed no more")
    func deactivate() {
        let inputs = StereoBuffers(count: 1, frames: frames)
        let output = StereoBuffers(count: 1, frames: frames)
        defer { inputs.release(); output.release() }
        inputs.fill(0, 0.5)
        let slots = makeSlots(1)
        slots[0].deactivate()

        let mixed = mix(inputs, into: output, slots: slots)

        #expect(mixed == 0)
        #expect(output.samples(0).allSatisfy { $0 == 0 })
        #expect(!slots[0].isActive)
    }
}
