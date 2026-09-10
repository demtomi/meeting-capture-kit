// FrameAssembler — turns two independent 16 kHz source streams into the fixed-size mono
// frames the tap puts on the wire.
//
// This is the piece of the tap that is easiest to get quietly wrong, which is why it is in
// the library and not in the executable. The two capture sources are separate hardware
// clocks arriving on separate queues in separate buffer sizes; nothing aligns them. Three
// failure modes, none of which a compiler or a type can see:
//
//   IT STALLS. Wait for both sources and a source that dies takes the stream with it. The
//   socket stays up, no error is raised, and the transcript simply stops.
//
//   IT DRIFTS. Emit on a wall-clock tick and pad whatever is short, and every jitter dip
//   inserts silence that is never taken back. Over an hour the padding accumulates and the
//   audio runs ahead of the meeting.
//
//   IT LIES. Drop a backlog to resynchronise and the output is no longer contiguous — but
//   `seq` keeps counting, and `seq` is the ONLY staleness signal the consumer has, which is
//   what keeps correctness off the status line. A spliced-together window reads as seamless,
//   so everything downstream treats audio either side of the hole as one continuous span.
//
// So: emit only whole frames, only when every contributing source has one, and treat every
// event that makes the output non-contiguous as a DISCONTINUITY the tap must announce by
// re-emitting its header with a bumped generation. There are four such events and they are
// named in `DiscontinuityReason`. A source that stops delivering is dropped from the mix
// rather than allowed to stall it.
//
// The clock is passed in on every call rather than read here, so the starvation rule is
// replayable in a check with no sleeping and no real time.
import Foundation

public enum TapSource: Int, Sendable, CaseIterable, CustomStringConvertible {
    case mic = 0
    case system = 1
    public var description: String { self == .mic ? "mic" : "system" }
}

/// Why the tap's output stopped being contiguous. All four are announced the same way — a
/// header re-emission with a bumped generation — because from the consumer's side they are
/// one fact: the audio either side of this point does not join up. The distinction is
/// telemetry and goes to stderr, which is never allowed to carry a correctness load.
///
/// `sourceFormatChanged` is here rather than in the tap, and that is the fix for a defect
/// found in review: the tap used to bump its own generation counter straight from the
/// resampler's transition report and never record the bump in the `GenerationLog`, so the ONE
/// cause this whole mechanism exists for, AirPods connecting mid-meeting, was the one cause
/// no header ever announced. Routing it through the same latch as the other three means there
/// is exactly one path from "the audio does not join up" to "a header goes on the wire", so
/// the mid-stream case cannot be the untested one.
public enum DiscontinuityReason: String, Sendable {
    /// An active source stopped delivering and was dropped from the mix.
    case sourceStarved
    /// A starved source came back; its stale backlog was discarded rather than played late.
    case sourceResumed
    /// A source's backlog passed its bound and the oldest samples were dropped.
    case backlogResync
    /// A source's capture format changed mid-take and its converter was rebuilt.
    case sourceFormatChanged
}

public struct AssembledFrame: Equatable, Sendable {
    public let pcm: [Int16]
    /// Which sources are in this frame. A one-source frame is legal and is what a mic-only
    /// take, a system-only take, and a starved-source stretch all produce.
    public let sources: [TapSource]
    /// Set when this frame is the FIRST one whose audio follows a splice, and nil otherwise.
    ///
    /// THE REASON RIDES OUT ON THE FRAME rather than being polled separately, and that is the
    /// second half of that same fix. The tap used to poll a latch at the top of each
    /// tick and mark the generation at the seq it found there — but `emit` latches
    /// `sourceStarved` itself and returns the post-splice frame in the SAME call, and a
    /// capture callback can latch `sourceResumed` or `backlogResync` while the tick thread is
    /// mid-drain. Either way the first frames of the new generation were written under the
    /// OLD one, with `seq` contiguous, so the consumer read a splice as seamless audio. A
    /// reason that travels with its frame cannot be attached to the wrong seq.
    public let discontinuityBefore: DiscontinuityReason?

    public init(pcm: [Int16], sources: [TapSource], discontinuityBefore: DiscontinuityReason? = nil) {
        self.pcm = pcm
        self.sources = sources
        self.discontinuityBefore = discontinuityBefore
    }
}

public final class FrameAssembler: @unchecked Sendable {

    public let frameSamples: Int
    /// Per-source ceiling. A backlog only grows when the OTHER source is behind, so this
    /// bounds inter-source skew. Default 1 s: far above the tens of milliseconds of ordinary
    /// jitter, far below anything a listener would accept as lip-sync.
    public let maxBacklogSamples: Int
    /// How long an active source may deliver nothing before it is dropped from the mix.
    public let starveTimeoutNs: UInt64

    private let lock = NSLock()
    private var fifo: [[Float]] = [[], []]
    private var active: [Bool] = [false, false]
    private var starved: [Bool] = [false, false]
    private var lastPushNs: [UInt64] = [0, 0]

    private var _backlogDropped: [Int] = [0, 0]
    private var _starveEvents: [Int] = [0, 0]
    private var _resumeEvents: [Int] = [0, 0]
    private var _formatTransitions: [Int] = [0, 0]
    private var _discontinuities = 0
    private var pendingReason: DiscontinuityReason?

    public init(frameSamples: Int = WireFormat.defaultFrameSamples,
                maxBacklogSamples: Int = 16_000,
                starveTimeoutNs: UInt64 = 2_000_000_000) {
        self.frameSamples = max(1, frameSamples)
        self.maxBacklogSamples = max(self.frameSamples, maxBacklogSamples)
        self.starveTimeoutNs = starveTimeoutNs
    }

    // ------------------------------------------------------------------ the audio callback

    /// Called from a capture callback. Appends and returns; there is no path here that
    /// waits, sleeps or retries, for the reason `PCMRing.append` gives: the archival take is
    /// the artifact that cannot be re-recorded, and a tap callback blocking on a stalled
    /// downstream is the exact backpressure condition that no-wait rule exists to keep out.
    public func push(_ samples: [Float], from source: TapSource, atNs now: UInt64) {
        let i = source.rawValue
        lock.lock()
        defer { lock.unlock() }

        active[i] = true
        if starved[i] {
            // Back after an outage. Its backlog is stale by definition — the meeting moved
            // on — so it is discarded rather than mixed in late against live audio from the
            // other source. That discard is a discontinuity, in the other source's timeline
            // as much as this one's.
            starved[i] = false
            fifo[i].removeAll(keepingCapacity: true)
            _resumeEvents[i] += 1
            latch(.sourceResumed)
        }
        lastPushNs[i] = now
        fifo[i].append(contentsOf: samples)

        if fifo[i].count > maxBacklogSamples {
            let excess = fifo[i].count - maxBacklogSamples
            fifo[i].removeFirst(excess)
            _backlogDropped[i] += excess
            latch(.backlogResync)
        }
    }

    /// Called from a capture callback when the resampler reports a mid-take format
    /// transition. Latches the same way the other three causes do, so the tap has ONE path
    /// from a discontinuity to a re-emitted header.
    ///
    /// THE DIRECTION THIS ERRS IN, STATED. The samples already in this source's FIFO were
    /// captured before the transition, so the header can LEAD the splice by up to one backlog
    /// (1 s at the default bound), and it can never LAG it. Leading makes the consumer treat
    /// a little good audio as stale, which costs a downstream claim its grounding. Lagging
    /// would make it treat spliced audio as continuous, which is the failure this whole
    /// mechanism exists to prevent. The asymmetry is deliberate and `live-audio-check` limb 18
    /// asserts the sign.
    public func noteFormatTransition(_ source: TapSource) {
        lock.lock(); defer { lock.unlock() }
        _formatTransitions[source.rawValue] += 1
        latch(.sourceFormatChanged)
    }

    // ---------------------------------------------------------------------- the tick thread

    /// One frame if one is ready, nil otherwise. Call it in a loop: after a jitter dip two
    /// frames can be ready at the same tick, and returning only one per tick would let the
    /// backlog grow until the bound clipped it.
    ///
    /// Never pads. A frame is built from `frameSamples` real samples per contributing source
    /// or it is not built at all, which is what keeps the output from drifting ahead of the
    /// meeting one jitter dip at a time.
    public func emit(atNs now: UInt64) -> AssembledFrame? {
        lock.lock()
        defer { lock.unlock() }

        // Starvation is evaluated here rather than on push, because the whole point is a
        // source that has stopped pushing.
        for i in 0..<2 where active[i] && !starved[i] {
            if now > lastPushNs[i], now - lastPushNs[i] > starveTimeoutNs {
                starved[i] = true
                fifo[i].removeAll(keepingCapacity: true)
                _starveEvents[i] += 1
                latch(.sourceStarved)
            }
        }

        let contributing = (0..<2).filter { active[$0] && !starved[$0] }
        guard !contributing.isEmpty else { return nil }
        guard contributing.allSatisfy({ fifo[$0].count >= frameSamples }) else { return nil }

        var take: [[Float]] = [[], []]
        for i in contributing {
            take[i] = Array(fifo[i].prefix(frameSamples))
            fifo[i].removeFirst(frameSamples)
        }

        // The latch is consumed HERE, and only when a frame is actually built. A reason
        // latched while no frame can be emitted stays pending until one is, so it lands on the
        // first frame that carries post-splice audio rather than on a seq that was never
        // written. If the take ends with a reason still pending there is no frame to mislabel,
        // and nothing is announced — which is correct, not a leak.
        let reason = pendingReason
        pendingReason = nil

        return AssembledFrame(pcm: Mixer.mixToPCM16(mic: take[0], system: take[1]),
                              sources: contributing.compactMap { TapSource(rawValue: $0) },
                              discontinuityBefore: reason)
    }

    // ------------------------------------------------------------------------- the counters

    /// Whether a discontinuity is latched and waiting for a frame to ride out on. READ-ONLY
    /// telemetry — it does not consume, because consuming is `emit`'s job and a second
    /// consumer is exactly how the reason came adrift from its frame in the first place.
    public var pendingDiscontinuity: DiscontinuityReason? {
        lock.lock(); defer { lock.unlock() }; return pendingReason
    }

    public var discontinuities: Int { lock.lock(); defer { lock.unlock() }; return _discontinuities }
    public func formatTransitions(_ s: TapSource) -> Int {
        lock.lock(); defer { lock.unlock() }; return _formatTransitions[s.rawValue]
    }
    public func backlogDropped(_ s: TapSource) -> Int {
        lock.lock(); defer { lock.unlock() }; return _backlogDropped[s.rawValue]
    }
    public func starveEvents(_ s: TapSource) -> Int {
        lock.lock(); defer { lock.unlock() }; return _starveEvents[s.rawValue]
    }
    public func resumeEvents(_ s: TapSource) -> Int {
        lock.lock(); defer { lock.unlock() }; return _resumeEvents[s.rawValue]
    }
    public func backlog(_ s: TapSource) -> Int {
        lock.lock(); defer { lock.unlock() }; return fifo[s.rawValue].count
    }
    public func isStarved(_ s: TapSource) -> Bool {
        lock.lock(); defer { lock.unlock() }; return starved[s.rawValue]
    }
    public func isActive(_ s: TapSource) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active[s.rawValue]
    }

    /// Caller already holds the lock.
    private func latch(_ r: DiscontinuityReason) {
        _discontinuities += 1
        if pendingReason == nil { pendingReason = r }
    }
}
