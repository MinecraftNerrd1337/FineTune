// FineTune/Audio/EQ/FIR/FIRProcessor.swift
import Accelerate
import Darwin.C  // OSMemoryBarrier
import Foundation

/// The FIR correction of one tap: runs the current `FIRConvolver` on the tap's stereo
/// stream and replaces it without a click.
///
/// A FIR filter cannot be changed in place the way biquad coefficients can: all its taps
/// change at once, which is heard as a click. So a new filter is a new convolver, and the
/// processor crossfades from the old one to the new one over `fadeSeconds` while both run on
/// the same input. "No filter" is a convolver slot left empty, which stands for the unprocessed
/// signal, so switching the FIR correction on or off is the same crossfade.
///
/// ## Threads
/// `process` runs on the HAL I/O thread; `install` and the properties on the main thread.
/// The two convolver slots and `_target` are only written by the main thread, `_fade` only
/// by the audio thread. While audio runs, the main thread writes a slot only when the audio
/// thread does not use it: the slot that is not the target, once the previous crossfade has
/// finished. A new filter that arrives during a crossfade waits for its end. A replaced
/// convolver is released a second later (deferred destruction, as for biquad setups).
final class FIRProcessor: @unchecked Sendable {
    static let fadeSeconds = 0.03
    /// Frames crossfaded per pass (size of the scratch buffers).
    private static let maxChunk = 1024
    private static let retryInterval: DispatchTimeInterval = .milliseconds(15)
    /// Retries before concluding that the audio thread is not running (about 300 ms).
    private static let maxRetries = 20

    // MARK: - Shared State

    private nonisolated(unsafe) var slot0: FIRConvolver?
    private nonisolated(unsafe) var slot1: FIRConvolver?
    /// Slot the audio thread fades to, then stays on (0 or 1).
    private nonisolated(unsafe) var _target: Int32 = 0
    /// Position of the crossfade: 0 = slot 0 alone, 1 = slot 1 alone. Audio thread only.
    private nonisolated(unsafe) var _fade: Float = 0
    /// Asks the audio thread to jump to the target without fading.
    private nonisolated(unsafe) var _snap = false
    /// Crossfade progress per frame.
    private nonisolated(unsafe) var _fadeStep: Float = 1.0 / (0.03 * 48_000)
    /// Calls of `process` so far (wraps). 0 = the audio thread has not used this processor yet.
    private nonisolated(unsafe) var _renderCount: UInt32 = 0

    private let scratchA: UnsafeMutablePointer<Float>
    private let scratchB: UnsafeMutablePointer<Float>

    // MARK: - Main-Thread State

    /// Bumped by every `install`, so a waiting older request is dropped.
    private var generation = 0
    /// Latency of the filter last installed, in samples (0 without one).
    private(set) var latencySamples = 0
    /// Whether a filter is installed (or on its way in).
    private(set) var hasFilter = false

    init() {
        scratchA = .allocate(capacity: Self.maxChunk)
        scratchA.initialize(repeating: 0, count: Self.maxChunk)
        scratchB = .allocate(capacity: Self.maxChunk)
        scratchB.initialize(repeating: 0, count: Self.maxChunk)
    }

    deinit {
        scratchA.deallocate()
        scratchB.deallocate()
    }

    // MARK: - Installing a Filter (main thread)

    /// Makes `convolver` the correction (nil = none), crossfading from the current one if
    /// audio is running. Main thread only.
    ///
    /// - Parameter audioThreadIdle: true when the caller knows `process` is not being called
    ///   (the owning processor is switched off). The filter is then put in place directly:
    ///   there is nothing to fade from, and the old convolver's memory of past audio must not
    ///   be played when processing resumes.
    func install(_ convolver: FIRConvolver?, sampleRate: Double, audioThreadIdle: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        generation += 1
        latencySamples = convolver?.latencySamples ?? 0
        hasFilter = convolver != nil
        _fadeStep = Float(1.0 / (Self.fadeSeconds * max(sampleRate, 8_000)))

        if audioThreadIdle || _renderCount == 0 {
            // One filter in the target slot, and the audio thread goes straight to it
            let target = _target
            _snap = true
            setSlot(target, to: convolver)
            setSlot(target == 0 ? 1 : 0, to: nil)
            OSMemoryBarrier()
            return
        }
        attemptInstall(convolver, generation: generation, retries: 0)
    }

    private func attemptInstall(_ convolver: FIRConvolver?, generation: Int, retries: Int) {
        guard generation == self.generation else { return }
        let target = _target

        if _fade == Float(target) {
            // Settled on `target`: the other slot is free. Fill it, then send the audio thread there.
            let other: Int32 = target == 0 ? 1 : 0
            setSlot(other, to: convolver)
            OSMemoryBarrier()
            _target = other
            return
        }
        if retries >= Self.maxRetries {
            // A crossfade that does not end: the audio thread is not running, so nothing is
            // audible. Have it jump to the new filter when it resumes.
            let other: Int32 = target == 0 ? 1 : 0
            _snap = true
            setSlot(other, to: convolver)
            OSMemoryBarrier()
            _target = other
            return
        }
        // A crossfade is in progress and uses both slots: wait for its end
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            self?.attemptInstall(convolver, generation: generation, retries: retries + 1)
        }
    }

    private func setSlot(_ index: Int32, to convolver: FIRConvolver?) {
        let old: FIRConvolver?
        if index == 0 {
            old = slot0
            slot0 = convolver
        } else {
            old = slot1
            slot1 = convolver
        }
        if let old {
            // The audio thread may still be inside it for the buffer in progress
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                _ = old
            }
        }
    }

    // MARK: - Audio Processing (RT-safe)

    /// Applies the correction in place to stereo interleaved audio. RT-safe.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        _renderCount = _renderCount == UInt32.max ? 1 : _renderCount + 1

        let target = _target
        let goal: Float = target == 0 ? 0 : 1
        var fade = _fade
        if _snap {
            _snap = false
            fade = goal
            _fade = goal
        }

        var done = 0
        while done < frameCount {
            let chunk = samples + done * 2

            if fade == goal {
                // Steady state: one convolver, or nothing at all
                if let convolver = target == 0 ? slot0 : slot1 {
                    let remaining = frameCount - done
                    convolver.process(channel: 0, input: chunk, inputStride: 2, output: chunk, outputStride: 2, count: remaining)
                    convolver.process(channel: 1, input: chunk + 1, inputStride: 2, output: chunk + 1, outputStride: 2, count: remaining)
                }
                break
            }

            // Crossfade: both slots run on the same input; an empty slot is the dry signal
            let n = min(frameCount - done, Self.maxChunk)
            let step = goal > fade ? _fadeStep : -_fadeStep
            let first = slot0
            let second = slot1
            for channel in 0..<2 {
                let io = chunk + channel
                Self.render(first, channel: channel, input: io, count: n, into: scratchA)
                Self.render(second, channel: channel, input: io, count: n, into: scratchB)
                var weight = fade
                var destination = io
                for i in 0..<n {
                    let w = min(max(weight, 0), 1)
                    destination.pointee = scratchA[i] + (scratchB[i] - scratchA[i]) * w
                    destination += 2
                    weight += step
                }
            }
            fade += step * Float(n)
            if (step > 0 && fade >= goal) || (step < 0 && fade <= goal) {
                fade = goal
            }
            done += n
        }
        _fade = fade
    }

    /// One slot's output for one channel of a chunk, into a contiguous buffer.
    @inline(__always)
    private static func render(
        _ convolver: FIRConvolver?, channel: Int, input: UnsafeMutablePointer<Float>, count: Int,
        into output: UnsafeMutablePointer<Float>
    ) {
        if let convolver {
            convolver.process(channel: channel, input: input, inputStride: 2, output: output, outputStride: 1, count: count)
        } else {
            var source = input
            for i in 0..<count {
                output[i] = source.pointee
                source += 2
            }
        }
    }
}
