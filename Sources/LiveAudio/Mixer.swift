// Mixer — sum the host mic and the system tap into the one mono channel the wire format
// carries, and encode it as PCM16 LE.
//
// Why this is a named surface and not two lines inside the tap: summing is the only new DSP
// in this build, and its failure mode is silent. Two tracks each at a legitimate 0.8 sum to
// 1.6; scaled by 32767 that is 52,427, which does not fit in an Int16. Wrapped, a loud
// two-way passage — both people talking, exactly the passage a live agent most needs — turns
// into full-scale noise of the opposite sign. The socket stays up, VAD fires on the noise,
// and the transcript fills with plausible-looking nonsense.
//
// Clipping is the correct answer rather than normalising: a normaliser needs lookahead the
// callback does not have, and a clipped loud passage is still transcribable while a
// retro-scaled one arrives late.
import Foundation

public enum Mixer {

    /// Sum two mono tracks to one, clamped to [-1, 1].
    ///
    /// Unequal lengths are summed over the overlap and the remainder carried through — the
    /// two capture sources are independent and their chunks do not arrive frame-aligned, so
    /// truncating to the shorter would discard real audio on every single chunk.
    public static func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        if a.isEmpty { return b.map(clamp) }
        if b.isEmpty { return a.map(clamp) }
        let n = max(a.count, b.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            out[i] = clamp(l + r)
        }
        return out
    }

    /// Float -> PCM16 LE. The clamp here is the last point before a value that cannot fit
    /// in an Int16 is handed to an Int16 initialiser.
    ///
    /// The initialiser is deliberately the TRAPPING one, not `truncatingIfNeeded`. If this
    /// clamp is ever lost, a saturating-looking truncation would turn a loud passage into
    /// full-scale noise of the opposite sign and the transcript would fill with plausible
    /// nonsense; the trap kills the tap instead, which is a sibling process with defined
    /// exit codes and no reach into the archival take. Loud beats silent.
    public static func toPCM16(_ samples: [Float]) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(samples.count)
        for f in samples {
            out.append(Int16((clamp(f) * 32767).rounded()))
        }
        return out
    }

    /// The wire form: sum, clip, encode. One call so no caller can assemble the two halves
    /// and leave the clamp out of the path.
    public static func mixToPCM16(mic: [Float], system: [Float]) -> [Int16] {
        toPCM16(sum(mic, system))
    }

    public static func littleEndianBytes(_ pcm: [Int16]) -> Data {
        var d = Data(capacity: pcm.count * 2)
        for s in pcm { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    @inline(__always)
    static func clamp(_ f: Float) -> Float { max(-1, min(1, f)) }
}
