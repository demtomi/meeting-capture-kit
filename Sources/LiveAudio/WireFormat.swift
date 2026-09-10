// WireFormat — the byte layout of the framed stdout contract, and the rule that
// decides when a re-emitted header goes on the wire.
//
// Three reasons it is framed rather than a bare stream of 8,000-byte chunks: a later
// change to frame size or sample rate in this target would misdecode as garbage audio
// instead of failing loudly, the consumer could not detect a lost or duplicated frame at
// all, and a tap restart would be indistinguishable from a continuation.
//
// THIS LIVES IN THE LIBRARY, NOT IN THE TAP, and that is the same argument the resampler
// and the ring were split out on. A byte layout is wrong in ways a compiler cannot see, and
// the consumer that decodes it is in another language — so the encoder has to be replayable
// with no device, no TCC grant and no consumer on the other end of the pipe.
//
// `live-audio-check` asserts BYTE LITERALS transcribed from the layout table below, never a
// round-trip through a decoder written here. A Swift decoder beside a Swift encoder measures
// the pair against each other and would agree with itself while both disagreed with the
// layout. That is a bar scored against something other than the thing it certifies.
// A consumer written in another language gets those same literals as its fixture.
import Foundation

public enum WireFormat {

    /// `MCK1`. Also the discriminator: see `magicSeq`.
    public static let magic: [UInt8] = [0x4D, 0x43, 0x4B, 0x31]

    /// Bumped only when the byte LAYOUT changes. Deliberately not the same field as the
    /// stream generation: a format transition mid-take bumps `generation`, while a change
    /// to this file bumps this. Folding them into one number means a protocol change looks
    /// to the consumer exactly like AirPods connecting.
    public static let protocolVersion: UInt8 = 1

    public static let headerBytes = 16
    public static let framePrefixBytes = 8

    /// Default frame: 250 ms at 16 kHz mono = 4,000 samples = 8,000 bytes.
    public static let defaultFrameSamples = 4_000

    /// A header is re-emitted mid-stream, so the consumer has to tell one from a
    /// frame prefix at an arbitrary point in the byte stream. It discriminates on the first
    /// four bytes: `MCK1` starts a header, anything else starts a frame prefix.
    ///
    /// That works only while no legal `seq` has those four bytes as its little-endian form.
    /// This is that value, and `nextSeq(after:)` skips it. It is ~1.28e9 frames in — a
    /// decade of continuous streaming — so the skip will never fire in practice; it exists
    /// because "will never happen" is the sentence that precedes an ambiguity nothing can
    /// recover from, and skipping one seq costs the consumer a single visible gap.
    public static let magicSeq: UInt32 = 0x314B_434D

    /// The 16-byte stream header.
    ///
    ///  0..3  magic `MCK1`
    ///  4     protocol version (UInt8)
    ///  5     channels (UInt8)
    ///  6..9  sample rate (UInt32 LE)
    /// 10..11 frame samples (UInt16 LE)
    /// 12..15 generation (UInt32 LE)
    public static func header(sampleRate: UInt32,
                              channels: UInt8,
                              frameSamples: UInt16,
                              generation: UInt32) -> Data {
        var d = Data(capacity: headerBytes)
        d.append(contentsOf: magic)
        d.append(protocolVersion)
        d.append(channels)
        appendLE32(&d, sampleRate)
        appendLE16(&d, frameSamples)
        appendLE32(&d, generation)
        return d
    }

    /// One frame: an 8-byte prefix then `pcm.count * 2` bytes of PCM16 LE.
    ///
    /// 0..3 seq (UInt32 LE) · 4..7 ts (UInt32 LE, milliseconds since the first frame)
    ///
    /// Both fields are 32 bits because `framePrefixBytes` fixes the prefix at 8 bytes.
    /// `seq` wraps after ~1.36e9 frames (10 years at 4 frames/s) and `ts` after 49.7 days,
    /// and a take that reaches either has other problems.
    public static func frame(seq: UInt32, tsMs: UInt32, pcm: [Int16]) -> Data {
        var d = Data(capacity: framePrefixBytes + pcm.count * 2)
        appendLE32(&d, seq)
        appendLE32(&d, tsMs)
        d.append(Mixer.littleEndianBytes(pcm))
        return d
    }

    /// The next legal `seq`, skipping the one value that would be read as a header.
    public static func nextSeq(after s: UInt32) -> UInt32 {
        let n = s &+ 1
        return n == magicSeq ? n &+ 1 : n
    }

    private static func appendLE16(_ d: inout Data, _ v: UInt16) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }

    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
}

/// When a re-emitted header goes on the wire, relative to the frames around it.
///
/// The tap discovers a discontinuity on the tick thread, which assigns `seq`; the bytes are
/// written by a different thread draining the ring. Writing the header from the discovering
/// thread races: the ring still holds frames captured BEFORE the discontinuity, and the
/// header would land in front of them, telling the consumer that older audio belongs to the
/// newer generation. The header is announced by the writer instead, at the frame whose seq
/// opens the new generation.
///
/// This is a lock-guarded list rather than a single pending value because two discontinuities
/// can be latched between one drain and the next.
public final class GenerationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [(seq: UInt32, generation: UInt32)] = []

    public init() {}

    /// Frames from `seq` onward belong to `generation`.
    public func mark(seq: UInt32, generation: UInt32) {
        lock.lock(); defer { lock.unlock() }
        points.append((seq, generation))
    }

    /// The generation that must be announced before `seq` is written, or nil.
    ///
    /// Every point at or below `seq` is consumed and only the LAST is returned. That is not
    /// a shortcut: reaching a later point means the ring dropped the frames the intermediate
    /// generations covered, and those drops already show as a `seq` gap. Announcing a
    /// generation no surviving frame belongs to would be the header lying in the other
    /// direction.
    public func take(upTo seq: UInt32) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        var latest: UInt32?
        while let first = points.first, first.seq <= seq {
            latest = first.generation
            points.removeFirst()
        }
        return latest
    }

    public var pending: Int { lock.lock(); defer { lock.unlock() }; return points.count }
}
