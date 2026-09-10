// StreamingResampler — one persistent AVAudioConverter for the life of a take, fed
// incrementally, 250 ms at a time.
//
// This is NEW CODE rather than a reuse, and here is why.
// `meeting-capture`'s `Audio.resampleTo16k` is a ONE-SHOT WHOLE-ARRAY converter: it builds a
// fresh AVAudioConverter, feeds the entire array, then signals `.endOfStream`. Called once
// per chunk it resets converter state at every boundary, which gives a filter transient at
// each seam and cumulative rate error over an hour. It also lives inside the frozen
// `meeting-capture` target, so importing it means touching the archival path.
//
// The dangerous half of "for the life of the take" is that the take's input format can
// change under it — AirPods connecting, a screen-share flipping the system-audio tap. A
// converter built for 48 kHz fed 44.1 kHz either throws once into a callback designed not
// to block, or keeps converting and emits WELL-FORMED 16 kHz FRAMES OF GARBAGE. The socket
// stays up, VAD keeps firing on the garbage, and every downstream check that asks whether a
// transcript is grounded in captured audio answers yes over speech nobody said.
//
// So this type watches its input format on every push and either reinitialises or hard-fails.
// It NEVER emits samples converted across a transition it did not handle.
import Foundation
import AVFoundation

/// The identity of an input stream's format. A change in either field is a transition.
/// Channels is carried even though the tap only ever pushes mono (SCK is configured
/// `channelCount = 1`, and AVCaptureSession's mic path is downmixed before it gets here):
/// a device swap that changes the channel count must be a transition, not a reinterpretation
/// of the same bytes.
public struct AudioFormatID: Equatable, Sendable, CustomStringConvertible {
    public let sampleRate: Double
    public let channels: UInt32

    public init(sampleRate: Double, channels: UInt32 = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var description: String { "\(Int(sampleRate.rounded()))Hz/\(channels)ch" }
}

/// Emitted when the resampler handled a format change. The tap re-emits its stream header
/// carrying `generation`, which is how the consumer tells a restart from a continuation and
/// marks the ring stale with `reason: format_change`.
public struct FormatTransition: Equatable, Sendable {
    public let from: AudioFormatID
    public let to: AudioFormatID
    public let generation: Int
}

public enum ResampleError: Error, Equatable, CustomStringConvertible {
    /// Policy is `.hardFail` and the input format moved. Carries the transition so the
    /// caller can name it on stderr before exiting.
    case formatChanged(FormatTransition)
    /// AVAudioConverter refused the format pair. Unsupported input (multichannel, a
    /// nonsense rate) lands here rather than being silently reinterpreted as mono.
    case converterUnavailable(AudioFormatID)
    case convertFailed(String)

    public var description: String {
        switch self {
        case .formatChanged(let t): return "input format changed \(t.from) -> \(t.to)"
        case .converterUnavailable(let f): return "no converter for \(f)"
        case .convertFailed(let m): return "convert failed: \(m)"
        }
    }
}

public struct ResampleOutput: Equatable, Sendable {
    /// 16 kHz mono Float samples. Empty is legal: the converter holds back less than one
    /// output frame's worth of input.
    public let samples: [Float]
    /// Non-nil only on the chunk that crossed a handled format change. The samples in that
    /// same output are the NEW format's, converted by the NEW converter — nothing is ever
    /// carried across the seam.
    public let transition: FormatTransition?
}

public final class StreamingResampler {
    public enum FormatChangePolicy: Sendable {
        /// Rebuild the converter and report the transition. The default: a meeting must
        /// survive AirPods connecting.
        case reinitialise
        /// Throw. For the check target, and for any caller that would rather stop than
        /// resume with a discontinuity it has to explain.
        case hardFail
    }

    public static let targetRate: Double = 16_000

    /// Bumped once per handled transition. Starts at 0 and is the header's version counter.
    public private(set) var generation: Int = 0
    public private(set) var currentFormat: AudioFormatID?
    /// Cumulative counts, for the stderr status line. Not a correctness signal: correctness
    /// rides on `seq`, never on a parsed status line.
    public private(set) var inputSamplesSeen: Int = 0
    public private(set) var outputSamplesEmitted: Int = 0

    private let policy: FormatChangePolicy
    private let outFmt: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inFmt: AVAudioFormat?

    public init?(policy: FormatChangePolicy = .reinitialise) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: StreamingResampler.targetRate,
                                      channels: 1, interleaved: false) else { return nil }
        self.outFmt = out
        self.policy = policy
    }

    /// The teardown, as one named call rather than two assignments at each of the two call
    /// sites. Forgetting it is the whole failure this type exists to prevent: a converter
    /// built for the OLD format left in place, quietly emitting well-formed 16 kHz frames of
    /// garbage. A defect that is one missing line is one a reviewer's eye skips.
    private func invalidateConverter() {
        converter = nil
        inFmt = nil
    }

    /// Feed one chunk. Throws rather than returning a partial result, because a caller that
    /// ignores an error here ships garbage audio that reads as speech downstream.
    public func push(_ samples: [Float], format: AudioFormatID) throws -> ResampleOutput {
        var transition: FormatTransition?

        if let current = currentFormat, current != format {
            let t = FormatTransition(from: current, to: format, generation: generation + 1)
            switch policy {
            case .hardFail:
                // Drop the converter so a caller that catches and retries cannot resume
                // against the stale one.
                invalidateConverter()
                currentFormat = nil
                throw ResampleError.formatChanged(t)
            case .reinitialise:
                generation += 1
                transition = t
                invalidateConverter()
            }
        }

        if converter == nil {
            guard format.channels == 1,
                  format.sampleRate > 0,
                  let newIn = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: format.sampleRate,
                                            channels: format.channels, interleaved: false),
                  let conv = AVAudioConverter(from: newIn, to: outFmt)
            else { throw ResampleError.converterUnavailable(format) }
            converter = conv
            inFmt = newIn
        }
        currentFormat = format
        inputSamplesSeen += samples.count

        guard !samples.isEmpty else { return ResampleOutput(samples: [], transition: transition) }
        guard let conv = converter, let inFormat = inFmt else {
            throw ResampleError.converterUnavailable(format)
        }

        // Pass-through when the source is already at target rate. Still goes through the
        // format-change machinery above, so a 16 kHz -> 16 kHz device swap that changes the
        // channel count is still a transition.
        if abs(format.sampleRate - StreamingResampler.targetRate) < 1 {
            outputSamplesEmitted += samples.count
            return ResampleOutput(samples: samples, transition: transition)
        }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count))
        else { throw ResampleError.convertFailed("input buffer allocation") }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        // Headroom, not an exact expectation: the converter holds internal state across
        // chunks, so a given chunk may emit slightly more or fewer than the ratio implies.
        let ratio = StreamingResampler.targetRate / format.sampleRate
        let outCap = AVAudioFrameCount(Double(samples.count) * ratio + 4096)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else {
            throw ResampleError.convertFailed("output buffer allocation")
        }

        // `.noDataNow`, NOT `.endOfStream`. This is the whole difference from the one-shot
        // function: `.endOfStream` drains and resets the converter, so the next chunk starts
        // from a cold filter and the seam shows. `.noDataNow` leaves the state in place.
        //
        // THE TWO `nonisolated(unsafe)` ANNOTATIONS ARE AN ASSERTION, NOT A FIX, and the
        // reason they are honest is the calling convention. AVAudioConverter's input block is
        // imported as `@Sendable`, so the compiler has to assume it can run on any thread at
        // any time. It cannot. `convert(to:error:withInputFrom:)` calls the block
        // SYNCHRONOUSLY on this thread and returns only after the last call, so `fed` is read
        // and written by one thread and `input` never outlives the call. None of this is
        // thread-safe in general. It is safe under that one convention, and the annotations
        // are where a reader is told which convention to go and check.
        //
        // The alternative the compiler suggests, `@preconcurrency import AVFoundation`, is
        // worse for two reasons: it downgrades EVERY future Sendable diagnostic this file
        // gets from AVFAudio, including the ones that would be real, and it renames the
        // import line the mutation harness anchors one of its source invariants on.
        nonisolated(unsafe) let input = inBuf
        nonisolated(unsafe) var fed = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw ResampleError.convertFailed(err?.localizedDescription ?? "unknown")
        }

        let n = Int(outBuf.frameLength)
        let out = n == 0 ? [] : Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
        outputSamplesEmitted += out.count
        return ResampleOutput(samples: out, transition: transition)
    }
}
