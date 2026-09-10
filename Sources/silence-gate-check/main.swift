// Runnable verification for SilenceGate:  swift run silence-gate-check
//
// An executable rather than a testTarget for the same reason speaker-naming-check
// is one — this box has only the Command Line Tools, no XCTest to link against.
//
// The headline case is a REPLAY OF THE REAL INCIDENT: the actual 5 s level trace of
// the 2026-07-27 2026-07-27 overrun recording, whose call ended at 21:12 while the
// recording ran to 50:00 and uploaded ~19,000 credits of silence. Every other case
// is a negative control designed to FAIL if a specific invariant is dropped. Each
// prints the mutation that should break it, so the next reader can check the test
// still bites instead of trusting that it does.
import Foundation
import SilenceGate

var failures = 0
var checks = 0

// Top-level code is @MainActor under Swift 6, so anything touching the counters is too.
@MainActor
func check(_ label: String, _ cond: Bool, breaksIf: String) {
    checks += 1
    if cond {
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)")
        print("        should break only if: \(breaksIf)")
    }
}

// ---------------------------------------------------------------- fixture replay
func loadFixture() -> [(TimeInterval, String)]? {
    // Resolved relative to the package, not the cwd, so `swift run` works from
    // anywhere. A missing fixture must FAIL the run, never silently skip: a check
    // that quietly tests nothing is worse than no check.
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // silence-gate-check
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Fixtures/overrun-trace.levels")
    guard let text = try? String(contentsOf: here, encoding: .utf8) else { return nil }
    var out: [(TimeInterval, String)] = []
    for line in text.split(whereSeparator: \.isNewline) {
        if line.hasPrefix("#") { continue }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let t = TimeInterval(parts[0]) else { continue }
        out.append((t, String(parts[1])))
    }
    return out.isEmpty ? nil : out
}

/// Replay a trace and report the elapsed time of the first `.stop`, or nil.
func replay(_ trace: [(TimeInterval, String)],
            config: SilenceGate.Config,
            dropSys: Bool = false,
            legacy: Bool = false) -> (stopAt: TimeInterval?, warnAt: TimeInterval?, hintAt: TimeInterval?) {
    var gate = SilenceGate(config: config)
    var stopAt: TimeInterval?
    var warnAt: TimeInterval?
    var hintAt: TimeInterval?
    for (t, rawLine) in trace {
        var line = rawLine
        if legacy, let s = LevelSample.parse(rawLine) {
            // Collapse to the OLD single-number format: max(mic, sys).
            line = String(format: "[level] %.4f", max(s.mic ?? 0, s.sys ?? 0))
        } else if dropSys, let cut = rawLine.range(of: " sys=") {
            line = String(rawLine[..<cut.lowerBound])
        }
        gate.note(line: line, at: t)
        if hintAt == nil, gate.remoteQuietSince(at: t) != nil { hintAt = t }
        switch gate.decide(at: t) {
        case .stop:
            if stopAt == nil { stopAt = t }
            return (stopAt, warnAt, hintAt)   // a real stop ends the recording
        case .warn:
            if warnAt == nil { warnAt = t }
        case .keepGoing:
            break
        }
    }
    return (stopAt, warnAt, hintAt)
}

func mmss(_ t: TimeInterval?) -> String {
    guard let t else { return "never" }
    return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
}

print("=== SilenceGate verification ===\n")

guard let trace = loadFixture() else {
    print("FATAL: fixture Fixtures/overrun-trace.levels missing or empty.")
    print("Refusing to report a result — this run would have verified nothing.")
    exit(2)
}
print("fixture: \(trace.count) ticks (\(mmss(trace.last?.0))) — real 2026-07-27 overrun recording")
print("         call ended 21:12, recording actually ran to 50:00\n")

print("[1] REPLAY OF THE REAL INCIDENT")
let live = replay(trace, config: SilenceGate.Config())
print("      remote-quiet hint at \(mmss(live.hintAt)) · warn at \(mmss(live.warnAt)) · STOP at \(mmss(live.stopAt))")
check("stops the overrun recording (it ran 50:00 unstopped)",
      live.stopAt != nil,
      breaksIf: "the remote track stops driving the decision on a virtual call")
check("stop lands after the call really ended (21:12), not during it",
      (live.stopAt ?? 0) > 21 * 60 + 12,
      breaksIf: "the fuse is short enough to cut a live call")
check("stop lands within 10 min of the call ending",
      (live.stopAt ?? .infinity) <= 21 * 60 + 12 + 600,
      breaksIf: "remoteStopAfter is raised past 10 min")
if let s = live.stopAt {
    let savedMin = (50 * 60 - s) / 60
    print(String(format: "      -> would have saved %.1f min of the 28.6 min overrun (~%.0f credits)",
                 savedMin, savedMin * 2 * 330))
}

print("\n[2] NEGATIVE CONTROL — the OLD collapsed max(mic,sys) line")
let legacyRun = replay(trace, config: SilenceGate.Config(), legacy: true)
check("legacy single-number trace does NOT stop (reproduces the bug)",
      legacyRun.stopAt == nil,
      breaksIf: "the legacy fallback starts remote-gating; it cannot, the tracks are merged")
print("      This is the control that proves case [1] is caused by the per-track")
print("      split and not by anything else in the replay.")

print("\n[3] NEGATIVE CONTROL — no mic threshold can substitute")
for thr in [Float(0.02), 0.05, 0.08, 0.12, 0.20] {
    var cfg = SilenceGate.Config()
    cfg.level = thr
    let r = replay(trace, config: cfg, legacy: true)
    print(String(format: "      mic-only @ %.2f -> stop %@", thr, mmss(r.stopAt)))
}
var thrCfg = SilenceGate.Config(); thrCfg.level = 0.20
check("even a 10x mic threshold does not stop the recording",
      replay(trace, config: thrCfg, legacy: true).stopAt == nil,
      breaksIf: "room noise and speech stop overlapping — re-measure before trusting a threshold")

print("\n[4] BROKEN SYSTEM CAPTURE must not read as a hung-up call")
// Same trace, but the system track never once crosses the threshold — the
// signature of a capture that silently failed, not of a call that ended.
let deadSys: [(TimeInterval, String)] = trace.map { (t, line) in
    guard let s = LevelSample.parse(line) else { return (t, line) }
    return (t, String(format: "[level] mic=%.4f sys=0.0000", s.mic ?? 0))
}
let broken = replay(deadSys, config: SilenceGate.Config())
check("never auto-stops when the system track was never live",
      broken.stopAt == nil,
      breaksIf: "remoteEverLive is dropped from isRemoteGated — then this stops at 8:00")

print("\n[5] IN-PERSON (no sys= field) must not be remote-gated")
let inPerson = replay(trace, config: { var c = SilenceGate.Config(); c.isVirtual = false; return c }(),
                      dropSys: true)
check("no remote-quiet hint is ever shown in-person",
      inPerson.hintAt == nil,
      breaksIf: "a missing sys= field is treated as sys=0 — inventing an absent track")
// Assert the parse result directly. Going through the gate instead would prove
// less than it looks: `remoteEverLive` independently blocks gating there, so the
// gate stays ungated even if a missing field IS mis-parsed as 0, and the check
// would pass while the property it names is broken.
check("a line with no sys= field parses to sys: nil, NOT sys: 0",
      LevelSample.parse("[level] mic=0.5000")?.sys == nil,
      breaksIf: "LevelSample.parse defaults a missing sys to 0 instead of nil")
var gateAbsent = SilenceGate(config: SilenceGate.Config())
gateAbsent.note(line: "[level] mic=0.5000", at: 5)
check("an absent sys= field leaves the gate ungated (second, independent guard)",
      !gateAbsent.isRemoteGated,
      breaksIf: "both the parse nil-ness AND remoteEverLive are dropped")

print("\n[6] A LIVE MONOLOGUE must NEVER be cut: remote silent, host talking")
// The genuine risk of remote-gating: you present for 60 min to a muted room, so
// the remote track is legitimately flat the whole time. Owner preference is
// explicit — over-record rather than truncate — so this must not stop, at any
// length, without a human saying so.
func monologue(minutes: Int, micLevel: String) -> (stop: TimeInterval?, warned: Bool) {
    var g = SilenceGate(config: SilenceGate.Config())
    g.note(line: "[level] mic=0.4000 sys=0.3000", at: 5)      // remote spoke once
    var stopped: TimeInterval?
    var warned = false
    var t: TimeInterval = 10
    while t <= TimeInterval(minutes * 60) {
        g.note(line: "[level] mic=\(micLevel) sys=0.0000", at: t)
        switch g.decide(at: t) {
        case .stop: if stopped == nil { stopped = t }
        case .warn: warned = true
        case .keepGoing: break
        }
        t += 5
    }
    return (stopped, warned)
}
let mono60 = monologue(minutes: 60, micLevel: "0.4000")
check("a 60-min monologue is NEVER auto-stopped",
      mono60.stop == nil,
      breaksIf: "the host-talking condition is removed from decide() — then this stops at 8:00")
check("...but it still warns, so the recording never goes silently unattended",
      mono60.warned,
      breaksIf: "the stop branch returns .keepGoing instead of .warn while held open")

// The condition must be a HOST-VOICE test, not a has-any-sound test. Room noise
// sitting between `level` (0.02) and `micActiveLevel` (0.08) must NOT hold the
// recording open — that is exactly the dead-room signature.
let roomNoise = monologue(minutes: 60, micLevel: "0.0300")
check("room noise below the talking threshold does NOT veto the stop",
      roomNoise.stop != nil,
      breaksIf: "micActiveLevel drops toward `level` — then dead air holds it open forever")
print("      quiet-room case stops at \(mmss(roomNoise.stop)); host-talking case: never.")

print("\n[7] 'Keep recording' must actually keep it")
var keep = SilenceGate(config: SilenceGate.Config())
keep.note(line: "[level] mic=0.4000 sys=0.3000", at: 5)
check("warns once the remote goes quiet past the fuse",
      keep.decide(at: 5 * 60 + 10) == .warn,
      breaksIf: "remoteWarnAfter is changed")
keep.keepRecording(at: 5 * 60 + 10)
check("keepRecording clears the warning",
      keep.decide(at: 5 * 60 + 15) == .keepGoing,
      breaksIf: "keepRecording stops resetting the remote clock")
check("stays calm through a FRESH fuse, not just one tick",
      keep.decide(at: 5 * 60 + 10 + 4 * 60) == .keepGoing,
      breaksIf: "keepRecording resets only lastAudioAt — then the old clock is still"
              + " past the stop fuse here and this reads .stop")
// Past the fresh warn fuse it SHOULD warn again — that is the fuse working, not a
// bug. What must never happen is a stop measured from the pre-keepRecording clock.
check("re-warns after the fresh fuse burns, but does not stop on the OLD clock",
      keep.decide(at: 5 * 60 + 10 + 7 * 60) == .warn,
      breaksIf: "keepRecording resets only lastAudioAt — then this reads .stop")

print("\n[8] PARSER")
check("parses the new two-field line",
      LevelSample.parse("[level] mic=0.0421 sys=0.0033") == LevelSample(mic: 0.0421, sys: 0.0033),
      breaksIf: "the emitted format changes without this being updated")
check("parses a legacy bare-number line as mic-only",
      LevelSample.parse("[level] 0.0421") == LevelSample(mic: 0.0421, sys: nil),
      breaksIf: "the legacy fallback is dropped while an old meeting-capture can still ship")
check("ignores a non-level line",
      LevelSample.parse("[meeting-capture] recording — press Enter") == nil,
      breaksIf: "the parser starts matching arbitrary stderr")

print("\n=== \(checks - failures)/\(checks) checks passed ===")
if failures > 0 {
    print("FAILED — do not ship the silence gate in this state.")
    exit(1)
}
print("OK")
