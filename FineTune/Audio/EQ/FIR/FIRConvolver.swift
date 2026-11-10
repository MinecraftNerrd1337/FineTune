// FineTune/Audio/EQ/FIR/FIRConvolver.swift
import Accelerate
import Foundation

/// Real-time convolution of stereo audio with one FIR filter, adding no latency of its own
/// whatever the filter's length or the size of the buffers it is called with.
///
/// A long filter convolved directly costs one multiply-add per tap and per sample (4096 taps:
/// about 400 million a second for stereo at 48 kHz). The usual cure, FFT convolution, works on
/// whole blocks and so delays the signal by one block. This convolver combines both so that
/// neither drawback remains (W. G. Gardner, "Efficient Convolution without Input-Output
/// Delay", 1995):
///
/// - the first `headLength` taps are convolved directly, sample by sample: no delay;
/// - the taps after them are split into partitions and convolved by FFT. The part of the
///   output owed to taps at offset ≥ B only depends on input that is at least B samples old,
///   so it is computed one block of B samples ahead, when that block's input is complete, and
///   is ready when its samples are played. Two block sizes are used: `headLength` for the
///   taps up to `tailBlock`, `tailBlock` for the rest.
///
/// The work per sample then grows with the logarithm of the length rather than the length.
///
/// ## RT-safety
/// `process` allocates nothing, takes no lock and calls only vDSP and memcpy on memory
/// allocated in `init`. All its state lives behind raw pointers. An instance is processed by
/// one thread at a time; the kernel never changes after `init` (a new filter is a new
/// convolver, see `FIRProcessor`).
final class FIRConvolver: @unchecked Sendable {
    static let channelCount = 2
    /// Taps convolved directly, and block size of the first FFT stage.
    static let headLength = 64
    /// Block size of the second FFT stage.
    static let tailBlock = 1024

    let tapCount: Int
    /// Delay of the filter itself (linear phase), for display. The convolver adds none.
    let latencySamples: Int

    private static let historyLength = 2 * headLength - 1

    /// Head taps in reverse order, so the direct convolution is a plain correlation.
    private let head: UnsafeMutablePointer<Float>
    /// Per channel: the last `headLength - 1` input samples, then room for one chunk.
    private let history: UnsafeMutablePointer<Float>
    /// Output of the chunk being processed.
    private let scratch: UnsafeMutablePointer<Float>
    /// Per channel: position inside the current block of `headLength` samples.
    private let phase: UnsafeMutablePointer<Int>
    private let shortStage: FIRPartitionStage?
    private let longStage: FIRPartitionStage?

    /// - Parameters:
    ///   - taps: impulse response, first tap first. Must not be empty.
    ///   - latencySamples: the filter's own delay, kept for display.
    init?(taps: [Float], latencySamples: Int = 0) {
        guard !taps.isEmpty else { return nil }
        let headLength = Self.headLength
        let tailBlock = Self.tailBlock
        let channels = Self.channelCount

        var short: FIRPartitionStage?
        var long: FIRPartitionStage?
        if taps.count > headLength {
            let end = min(taps.count, tailBlock)
            guard let stage = FIRPartitionStage(blockSize: headLength, taps: Array(taps[headLength..<end]), channels: channels) else {
                return nil
            }
            short = stage
        }
        if taps.count > tailBlock {
            guard let stage = FIRPartitionStage(blockSize: tailBlock, taps: Array(taps[tailBlock...]), channels: channels) else {
                return nil
            }
            long = stage
        }
        shortStage = short
        longStage = long
        tapCount = taps.count
        self.latencySamples = latencySamples

        head = .allocate(capacity: headLength)
        head.initialize(repeating: 0, count: headLength)
        for i in 0..<min(taps.count, headLength) {
            head[headLength - 1 - i] = taps[i]
        }
        history = .allocate(capacity: Self.historyLength * channels)
        history.initialize(repeating: 0, count: Self.historyLength * channels)
        scratch = .allocate(capacity: headLength)
        scratch.initialize(repeating: 0, count: headLength)
        phase = .allocate(capacity: channels)
        phase.initialize(repeating: 0, count: channels)
    }

    deinit {
        head.deallocate()
        history.deallocate()
        scratch.deallocate()
        phase.deallocate()
    }

    /// Convolves `count` samples of one channel (RT-safe).
    ///
    /// `output` may be the same buffer as `input` with the same stride: every chunk is read
    /// completely before it is written. Each channel must be given every sample exactly once.
    func process(
        channel: Int,
        input: UnsafePointer<Float>, inputStride: Int,
        output: UnsafeMutablePointer<Float>, outputStride: Int,
        count: Int
    ) {
        let headLength = Self.headLength
        let chunkHistory = history + channel * Self.historyLength
        let fresh = chunkHistory + (headLength - 1)
        var position = phase[channel]
        var done = 0

        while done < count {
            // Never across a block boundary: the FFT stages hand over a new block there
            let n = min(count - done, headLength - position)

            var source = input + done * inputStride
            for i in 0..<n {
                fresh[i] = source.pointee
                source += inputStride
            }

            // Direct part: out[i] = Σ head[p] · history[i + p]
            vDSP_conv(chunkHistory, 1, head, 1, scratch, 1, vDSP_Length(n), vDSP_Length(headLength))

            // FFT parts, computed one block ago; the chunk's input goes into their next block
            shortStage?.consume(channel: channel, input: fresh, count: n, addTo: scratch)
            longStage?.consume(channel: channel, input: fresh, count: n, addTo: scratch)

            var destination = output + done * outputStride
            for i in 0..<n {
                destination.pointee = scratch[i]
                destination += outputStride
            }

            memmove(chunkHistory, chunkHistory + n, (headLength - 1) * MemoryLayout<Float>.size)
            position += n
            if position == headLength { position = 0 }
            done += n
        }
        phase[channel] = position
    }
}

/// One FFT stage of `FIRConvolver`: the taps from offset `blockSize` on (relative to the
/// start of the kernel), in partitions of `blockSize`, convolved by overlap-add in the
/// frequency domain. When a block of input is complete, the stage computes the contribution
/// of those taps to the *next* block of output.
final class FIRPartitionStage: @unchecked Sendable {
    let blockSize: Int
    let partitionCount: Int
    private let fftSize: Int
    private let channels: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    /// Spectra of the partitions (`partitionCount × fftSize`), scaled for the round trip.
    private let kernelReal: UnsafeMutablePointer<Float>
    private let kernelImag: UnsafeMutablePointer<Float>
    /// Per channel: spectra of the last `partitionCount` input blocks, as a ring.
    private let lineReal: UnsafeMutablePointer<Float>
    private let lineImag: UnsafeMutablePointer<Float>
    /// Per channel: input block being filled, contribution to the block being played,
    /// and the half of the last result that belongs to the following block.
    private let block: UnsafeMutablePointer<Float>
    private let ready: UnsafeMutablePointer<Float>
    private let overlap: UnsafeMutablePointer<Float>
    /// Per channel: fill of `block`, and ring index of the newest spectrum.
    private let fill: UnsafeMutablePointer<Int>
    private let newest: UnsafeMutablePointer<Int>
    /// Work buffers, `fftSize` each.
    private let timeReal: UnsafeMutablePointer<Float>
    private let timeImag: UnsafeMutablePointer<Float>
    private let sumRealA: UnsafeMutablePointer<Float>
    private let sumImagA: UnsafeMutablePointer<Float>
    private let sumRealB: UnsafeMutablePointer<Float>
    private let sumImagB: UnsafeMutablePointer<Float>

    /// - Parameter taps: the kernel from offset `blockSize` on (so `taps[0]` is the tap at
    ///   offset `blockSize`). Must not be empty.
    init?(blockSize: Int, taps: [Float], channels: Int) {
        let fftSize = 2 * blockSize
        guard !taps.isEmpty, blockSize >= 8, blockSize & (blockSize - 1) == 0,
              let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE) else {
            return nil
        }
        self.blockSize = blockSize
        self.fftSize = fftSize
        self.channels = channels
        self.forward = forward
        self.inverse = inverse
        let partitions = (taps.count + blockSize - 1) / blockSize
        partitionCount = partitions

        func zeroed(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        kernelReal = zeroed(partitions * fftSize)
        kernelImag = zeroed(partitions * fftSize)
        lineReal = zeroed(channels * partitions * fftSize)
        lineImag = zeroed(channels * partitions * fftSize)
        block = zeroed(channels * blockSize)
        ready = zeroed(channels * blockSize)
        overlap = zeroed(channels * blockSize)
        timeReal = zeroed(fftSize)
        timeImag = zeroed(fftSize)
        sumRealA = zeroed(fftSize)
        sumImagA = zeroed(fftSize)
        sumRealB = zeroed(fftSize)
        sumImagB = zeroed(fftSize)
        fill = .allocate(capacity: channels)
        fill.initialize(repeating: 0, count: channels)
        newest = .allocate(capacity: channels)
        newest.initialize(repeating: 0, count: channels)

        // Scale of a forward·forward → inverse round trip, measured rather than assumed:
        // an impulse convolved with an impulse must come back as 1.
        timeReal[0] = 1
        vDSP_DFT_Execute(forward, timeReal, timeImag, sumRealA, sumImagA)
        var impulseA = DSPSplitComplex(realp: sumRealA, imagp: sumImagA)
        var impulseB = DSPSplitComplex(realp: sumRealA, imagp: sumImagA)
        var product = DSPSplitComplex(realp: sumRealB, imagp: sumImagB)
        vDSP_zvmul(&impulseA, 1, &impulseB, 1, &product, 1, vDSP_Length(fftSize), 1)
        vDSP_DFT_Execute(inverse, sumRealB, sumImagB, sumRealA, sumImagA)
        let roundTrip = sumRealA[0]
        var scale: Float = roundTrip != 0 ? 1 / roundTrip : 1 / Float(fftSize)

        // Spectrum of each partition, zero-padded to the FFT size
        for k in 0..<partitions {
            vDSP_vclr(timeReal, 1, vDSP_Length(fftSize))
            vDSP_vclr(timeImag, 1, vDSP_Length(fftSize))
            let start = k * blockSize
            for i in 0..<min(blockSize, taps.count - start) {
                timeReal[i] = taps[start + i]
            }
            vDSP_DFT_Execute(forward, timeReal, timeImag, kernelReal + k * fftSize, kernelImag + k * fftSize)
        }
        vDSP_vsmul(kernelReal, 1, &scale, kernelReal, 1, vDSP_Length(partitions * fftSize))
        vDSP_vsmul(kernelImag, 1, &scale, kernelImag, 1, vDSP_Length(partitions * fftSize))
        vDSP_vclr(timeReal, 1, vDSP_Length(fftSize))
        vDSP_vclr(timeImag, 1, vDSP_Length(fftSize))
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
        for pointer in [kernelReal, kernelImag, lineReal, lineImag, block, ready, overlap,
                        timeReal, timeImag, sumRealA, sumImagA, sumRealB, sumImagB] {
            pointer.deallocate()
        }
        fill.deallocate()
        newest.deallocate()
    }

    /// Adds this stage's contribution for `count` samples to `output` and stores the same
    /// samples of input for the next block (RT-safe). `count` never crosses the end of the
    /// block: `FIRConvolver` cuts its chunks at multiples of its head length, which divides
    /// every stage's block size.
    func consume(channel: Int, input: UnsafePointer<Float>, count: Int, addTo output: UnsafeMutablePointer<Float>) {
        let position = fill[channel]
        let offset = channel * blockSize + position
        vDSP_vadd(output, 1, ready + offset, 1, output, 1, vDSP_Length(count))
        memcpy(block + offset, input, count * MemoryLayout<Float>.size)

        let filled = position + count
        if filled >= blockSize {
            step(channel: channel)
            fill[channel] = 0
        } else {
            fill[channel] = filled
        }
    }

    /// The channel's input block is complete: compute what this stage owes the next block.
    private func step(channel: Int) {
        let n = fftSize
        let b = blockSize
        let length = vDSP_Length(n)
        let floatSize = MemoryLayout<Float>.size

        // Spectrum of the completed block (zero-padded) into the ring, as the newest entry
        memcpy(timeReal, block + channel * b, b * floatSize)
        vDSP_vclr(timeReal + b, 1, vDSP_Length(b))
        vDSP_vclr(timeImag, 1, length)
        let slot = (newest[channel] + partitionCount - 1) % partitionCount
        newest[channel] = slot
        let base = channel * partitionCount * n
        vDSP_DFT_Execute(forward, timeReal, timeImag, lineReal + base + slot * n, lineImag + base + slot * n)

        // Σ spectrum(block m−1−k) · partition k, alternating between two accumulators so that
        // no vDSP call ever writes the buffer it reads
        var sourceReal = sumRealA, sourceImag = sumImagA
        var targetReal = sumRealB, targetImag = sumImagB
        vDSP_vclr(sourceReal, 1, length)
        vDSP_vclr(sourceImag, 1, length)
        for k in 0..<partitionCount {
            let entry = (slot + k) % partitionCount
            var spectrum = DSPSplitComplex(realp: lineReal + base + entry * n, imagp: lineImag + base + entry * n)
            var partition = DSPSplitComplex(realp: kernelReal + k * n, imagp: kernelImag + k * n)
            var sum = DSPSplitComplex(realp: sourceReal, imagp: sourceImag)
            var result = DSPSplitComplex(realp: targetReal, imagp: targetImag)
            vDSP_zvma(&spectrum, 1, &partition, 1, &sum, 1, &result, 1, length)
            swap(&sourceReal, &targetReal)
            swap(&sourceImag, &targetImag)
        }

        // Back to time (2 blocks long): the first block plus what the previous result left
        // over is this stage's share of the next block; the second block is left over in turn
        vDSP_DFT_Execute(inverse, sourceReal, sourceImag, timeReal, timeImag)
        vDSP_vadd(timeReal, 1, overlap + channel * b, 1, ready + channel * b, 1, vDSP_Length(b))
        memcpy(overlap + channel * b, timeReal + b, b * floatSize)
    }
}
