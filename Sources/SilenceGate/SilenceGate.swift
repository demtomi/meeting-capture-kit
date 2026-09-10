// SilenceGate — the "should this recording still be running?" decision, as pure
// logic with no AppKit, no Date(), and no capture dependency.
//
// It lives in its own library target for the same reason SpeakerNaming does: so it
// can be replayed and falsified with `swift run silence-gate-check` without
// launching the app or touching TCC-gated capture. The decision guards real money
// (every idle minute is uploaded and billed) and the meeting record itself (a wrong
// stop truncates a live call), and it rests on ordering invariants that no compiler
// can check — so it is worth the split.
//
// Time is injected as elapsed seconds since recording start, never read from a
// clock. That is what makes a 50-minute meeting replayable in milliseconds and the
// results deterministic.
import Foundation

public enum SilenceDecision: Equatable {
    case keepGoing
    case warn
    case stop
}

/// One parsed `[level]` line. `sys == nil` means the line carried no `sys=` field
/// at all — there is no system capturer. A track that does not exist has not gone
/// quiet, and conflating the two would auto-stop every in-person recording.
public struct LevelSample: Equatable {
    public let mic: Float?
    public let sys: Float?
    public init(mic: Float?, sys: Float?) { self.mic = mic; self.sys = sys }

    /// Parse `[level] mic=0.0421 sys=0.0033`, or a bare `[level] 0.0421` from an
    /// older meeting-capture. Returns nil for any line that is not a level line.
    public static func parse(_ line: String) -> LevelSample? {
        guard let r = line.range(of: "[level]") else { return nil }
        let tail = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        var mic: Float?
        var sys: Float?
        for field in tail.split(separator: " ") {
            let kv = field.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let v = Float(kv[1]) else { continue }
            if kv[0] == "mic" { mic = v } else if kv[0] == "sys" { sys = v }
        }
        if mic == nil, sys == nil {
            // Legacy collapsed max(mic, system). The tracks are already merged, so
            // it can only ever drive the mic path — reported as mic, sys absent.
            guard let v = Float(tail) else { return nil }
            return LevelSample(mic: v, sys: nil)
        }
        return LevelSample(mic: mic, sys: sys)
    }
}

public struct SilenceGate {
    public struct Config {
        /// peak |sample| that counts as audio.
        public var level: Float = 0.02
        /// Fuse on the mic-only path. Long, because the signal is weak: measured on
        /// the 2026-07-27 overrun take, room noise and live speech overlap almost
        /// completely (dead-air p50 0.0246 / p90 0.0641 vs live-call p25 0.0250),
        /// so no threshold separates them and this path can only ever be a backstop.
        public var micWarnAfter: TimeInterval = 15 * 60
        public var micStopAfter: TimeInterval = 18 * 60
        /// Fuse on the remote-gated path. Short, because the signal is categorical:
        /// a hung-up call reads exactly 0.0000 on every block.
        public var remoteWarnAfter: TimeInterval = 5 * 60
        public var remoteStopAfter: TimeInterval = 8 * 60
        /// When the host-facing UI should start saying "no remote audio".
        public var remoteQuietHint: TimeInterval = 2 * 60
        /// Virtual call (mic+system). In-person recordings have no remote track.
        public var isVirtual: Bool = true

        /// Mic peak that counts as THE HOST ACTIVELY TALKING — deliberately well
        /// above `level`, which only asks "is there any sound at all".
        ///
        /// This exists to make one outcome impossible: cutting a recording while
        /// the host is still speaking (presenting to a muted room, so the remote track
        /// is legitimately flat). Owner preference is explicit and asymmetric —
        /// over-recording is cheap, a truncated meeting is not.
        ///
        /// Note what this condition can and cannot do: it is an EXTRA requirement on
        /// stopping, so it can only ever PREVENT a stop, never cause one. Its worst
        /// case is over-recording, which is the accepted failure. That is why a
        /// threshold fitted to a single meeting is safe here in a way that a
        /// threshold deciding to stop would not be.
        ///
        /// 0.08 measured on the 2026-07-27 overrun take: while he was actually
        /// speaking, the longest sub-0.08 gap was 1.2 min; in the dead room after
        /// the call there was a 7.2 min run below it. ~6x margin.
        public var micActiveLevel: Float = 0.08
        /// How long the mic must stay below `micActiveLevel` before a stop is allowed.
        public var micQuietBeforeStop: TimeInterval = 3 * 60

        public init() {}
    }

    public private(set) var config: Config

    private var lastAudioAt: TimeInterval = 0
    private var lastRemoteAudioAt: TimeInterval = 0
    private var lastMicLoudAt: TimeInterval = 0
    private var hasSystemTrack = false
    private var remoteEverLive = false

    public init(config: Config = Config()) { self.config = config }

    /// True once the remote track is a trustworthy end-of-meeting signal.
    ///
    /// `remoteEverLive` is the load-bearing condition, not bookkeeping: a recording
    /// whose system capture silently failed (permission missing, tap never attached)
    /// reads 0.0000 from the first second. Without this, that reads identically to
    /// "the remote hung up" and would stop a live meeting at 8 minutes. A track that
    /// has never made a sound is a broken capture, not a finished call.
    public var isRemoteGated: Bool {
        config.isVirtual && hasSystemTrack && remoteEverLive
    }

    public mutating func note(_ sample: LevelSample, at t: TimeInterval) {
        if let m = sample.mic, m >= config.level { lastAudioAt = t }
        if let m = sample.mic, m >= config.micActiveLevel { lastMicLoudAt = t }
        if let s = sample.sys {
            hasSystemTrack = true
            if s >= config.level {
                lastAudioAt = t
                lastRemoteAudioAt = t
                remoteEverLive = true
            }
        }
    }

    public mutating func note(line: String, at t: TimeInterval) {
        guard let s = LevelSample.parse(line) else { return }
        note(s, at: t)
    }

    /// Seconds the deciding track has been quiet.
    public func quietFor(at t: TimeInterval) -> TimeInterval {
        max(0, t - (isRemoteGated ? lastRemoteAudioAt : lastAudioAt))
    }

    /// Elapsed-time mark the remote went quiet, once past the hint window. nil on the
    /// mic-only path: with no remote track there is no "other side" to have gone
    /// quiet, and showing one would be an invented signal.
    public func remoteQuietSince(at t: TimeInterval) -> TimeInterval? {
        guard isRemoteGated, quietFor(at: t) >= config.remoteQuietHint else { return nil }
        return lastRemoteAudioAt
    }

    /// True while the host has been audibly talking recently. Blocks the auto-stop,
    /// never the warning: a banner while you speak is a glance, a stop is a lost
    /// recording. Only meaningful on the remote-gated path — on a mic-only recording
    /// the mic IS the deciding track and this would veto every stop forever.
    public func hostTalkingRecently(at t: TimeInterval) -> Bool {
        guard isRemoteGated else { return false }
        return (t - lastMicLoudAt) < config.micQuietBeforeStop
    }

    public func decide(at t: TimeInterval) -> SilenceDecision {
        let quiet = quietFor(at: t)
        let warnAfter = isRemoteGated ? config.remoteWarnAfter : config.micWarnAfter
        let stopAfter = isRemoteGated ? config.remoteStopAfter : config.micStopAfter
        // The stop needs BOTH doors: the remote gone AND the host not mid-sentence.
        // Downgrading to .warn (rather than .keepGoing) keeps the banner up the whole
        // time, so a recording that is being held open by the host's own voice still
        // says so instead of going quiet about it.
        if quiet >= stopAfter { return hostTalkingRecently(at: t) ? .warn : .stop }
        if quiet >= warnAfter { return .warn }
        return .keepGoing
    }

    /// "Keep recording" on the banner. Resets BOTH clocks — on the remote-gated path
    /// it is the remote clock that fired, so clearing only the any-audio clock would
    /// let the warning re-appear on the next tick and the stop land on schedule
    /// anyway. "Keep recording" has to actually keep it.
    public mutating func keepRecording(at t: TimeInterval) {
        lastAudioAt = t
        lastRemoteAudioAt = t
    }
}
