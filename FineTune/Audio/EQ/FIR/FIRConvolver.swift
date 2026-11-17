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
///
/// The FFTs are real (`vDSP_DFT_zrop`): the spectrum of a real signal is symmetric, so only
/// its lower half is computed, stored and multiplied, which halves the work and the memory
/// of a complex FFT for the same result. A real FFT of `2 × blockSize` points takes the even
/// samples as real parts and the odd ones as imaginary parts, and gives `blockSize` bins, the
/// first of which packs two real values: DC as its real part, Nyquist as its imaginary part.
final class FIRPartitionStage: @unchecked Sendable {
    let blockSize: Int
    let partitionCount: Int
    private let channels: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    /// Spectra of the partitions (`partitionCount × blockSize` bins), scaled for the round trip.
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
    /// Input of the forward FFT, `blockSize` each: an input block split into even and odd
    /// samples fills the lower half, and the upper half, the zero padding, is never written.
    private let inputReal: UnsafeMutablePointer<Float>
    private let inputImag: UnsafeMutablePointer<Float>
    /// Accumulators, `blockSize` each; the one not holding the sum takes the inverse FFT.
    private let sumRealA: UnsafeMutablePointer<Float>
    private let sumImagA: UnsafeMutablePointer<Float>
    private let sumRealB: UnsafeMutablePointer<Float>
    private let sumImagB: UnsafeMutablePointer<Float>
    /// Result of the inverse FFT back in time order, `2 × blockSize`.
    private let time: UnsafeMutablePointer<Float>

    /// - Parameter taps: the kernel from offset `blockSize` on (so `taps[0]` is the tap at
    ///   offset `blockSize`). Must not be empty.
    init?(blockSize: Int, taps: [Float], channels: Int) {
        let fftSize = 2 * blockSize
        guard !taps.isEmpty, blockSize >= 8, blockSize & (blockSize - 1) == 0,
              let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD),
              let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE) else {
            return nil
        }
        self.blockSize = blockSize
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
        kernelReal = zeroed(partitions * blockSize)
        kernelImag = zeroed(partitions * blockSize)
        lineReal = zeroed(channels * partitions * blockSize)
        lineImag = zeroed(channels * partitions * blockSize)
        block = zeroed(channels * blockSize)
        ready = zeroed(channels * blockSize)
        overlap = zeroed(channels * blockSize)
        inputReal = zeroed(blockSize)
        inputImag = zeroed(blockSize)
        sumRealA = zeroed(blockSize)
        sumImagA = zeroed(blockSize)
        sumRealB = zeroed(blockSize)
        sumImagB = zeroed(blockSize)
        time = zeroed(fftSize)
        fill = .allocate(capacity: channels)
        fill.initialize(repeating: 0, count: channels)
        newest = .allocate(capacity: channels)
        newest.initialize(repeating: 0, count: channels)

        // Scale of a forward·forward → inverse round trip, measured rather than assumed:
        // an impulse convolved with an impulse must come back as 1.
        inputReal[0] = 1
        vDSP_DFT_Execute(forward, inputReal, inputImag, sumRealA, sumImagA)
        inputReal[0] = 0
        var impulseA = DSPSplitComplex(realp: sumRealA, imagp: sumImagA)
        var impulseB = DSPSplitComplex(realp: sumRealA, imagp: sumImagA)
        var product = DSPSplitComplex(realp: sumRealB, imagp: sumImagB)
        vDSP_zvmul(&impulseA, 1, &impulseB, 1, &product, 1, vDSP_Length(blockSize), 1)
        sumRealB[0] = sumRealA[0] * sumRealA[0]
        sumImagB[0] = sumImagA[0] * sumImagA[0]
        vDSP_DFT_Execute(inverse, sumRealB, sumImagB, sumRealA, sumImagA)
        let roundTrip = sumRealA[0]
        var scale: Float = roundTrip != 0 ? 1 / roundTrip : 1 / Float(fftSize)

        // Spectrum of each partition, zero-padded to the FFT size
        var input = DSPSplitComplex(realp: inputReal, imagp: inputImag)
        var partition = [Float](repeating: 0, count: blockSize)
        for k in 0..<partitions {
            let start = k * blockSize
            let count = min(blockSize, taps.count - start)
            for i in 0..<blockSize {
                partition[i] = i < count ? taps[start + i] : 0
            }
            partition.withUnsafeBufferPointer { samples in
                samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: blockSize / 2) {
                    vDSP_ctoz($0, 2, &input, 1, vDSP_Length(blockSize / 2))
                }
            }
            vDSP_DFT_Execute(forward, inputReal, inputImag, kernelReal + k * blockSize, kernelImag + k * blockSize)
        }
        vDSP_vsmul(kernelReal, 1, &scale, kernelReal, 1, vDSP_Length(partitions * blockSize))
        vDSP_vsmul(kernelImag, 1, &scale, kernelImag, 1, vDSP_Length(partitions * blockSize))
        vDSP_vclr(inputReal, 1, vDSP_Length(blockSize))
        vDSP_vclr(inputImag, 1, vDSP_Length(blockSize))
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
        for pointer in [kernelReal, kernelImag, lineReal, lineImag, block, ready, overlap,
                        inputReal, inputImag, sumRealA, sumImagA, sumRealB, sumImagB, time] {
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
        let b = blockSize
        let bins = vDSP_Length(b)
        let floatSize = MemoryLayout<Float>.size

        // Spectrum of the completed block (zero-padded) into the ring, as the newest entry
        var input = DSPSplitComplex(realp: inputReal, imagp: inputImag)
        (block + channel * b).withMemoryRebound(to: DSPComplex.self, capacity: b / 2) {
            vDSP_ctoz($0, 2, &input, 1, vDSP_Length(b / 2))
        }
        let slot = (newest[channel] + partitionCount - 1) % partitionCount
        newest[channel] = slot
        let base = channel * partitionCount * b
        vDSP_DFT_Execute(forward, inputReal, inputImag, lineReal + base + slot * b, lineImag + base + slot * b)

        // Σ spectrum(block m−1−k) · partition k, alternating between two accumulators so that
        // no vDSP call ever writes the buffer it reads. Bin 0 holds DC and Nyquist, two real
        // values that multiply separately, so it is summed on the side and set afterwards.
        var sourceReal = sumRealA, sourceImag = sumImagA
        var targetReal = sumRealB, targetImag = sumImagB
        vDSP_vclr(sourceReal, 1, bins)
        vDSP_vclr(sourceImag, 1, bins)
        var dc: Float = 0
        var nyquist: Float = 0
        for k in 0..<partitionCount {
            let entry = (slot + k) % partitionCount
            let spectrumReal = lineReal + base + entry * b, spectrumImag = lineImag + base + entry * b
            let partitionReal = kernelReal + k * b, partitionImag = kernelImag + k * b
            dc += spectrumReal[0] * partitionReal[0]
            nyquist += spectrumImag[0] * partitionImag[0]
            var spectrum = DSPSplitComplex(realp: spectrumReal, imagp: spectrumImag)
            var partition = DSPSplitComplex(realp: partitionReal, imagp: partitionImag)
            var sum = DSPSplitComplex(realp: sourceReal, imagp: sourceImag)
            var result = DSPSplitComplex(realp: targetReal, imagp: targetImag)
            vDSP_zvma(&spectrum, 1, &partition, 1, &sum, 1, &result, 1, bins)
            swap(&sourceReal, &targetReal)
            swap(&sourceImag, &targetImag)
        }
        sourceReal[0] = dc
        sourceImag[0] = nyquist

        // Back to time (2 blocks long), into the free accumulator then in sample order: the
        // first block plus what the previous result left over is this stage's share of the
        // next block; the second block is left over in turn
        vDSP_DFT_Execute(inverse, sourceReal, sourceImag, targetReal, targetImag)
        var result = DSPSplitComplex(realp: targetReal, imagp: targetImag)
        time.withMemoryRebound(to: DSPComplex.self, capacity: b) {
            vDSP_ztoc(&result, 1, $0, 2, bins)
        }
        vDSP_vadd(time, 1, overlap + channel * b, 1, ready + channel * b, 1, bins)
        memcpy(overlap + channel * b, time + b, b * floatSize)
    }
}
