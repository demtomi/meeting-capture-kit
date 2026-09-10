// Runnable verification for LiveAudio — `swift run live-audio-check`.
//
// It runs the LiveAudio limbs 1, 2, 3, 13, 15, 16, 17 and 18. No network, no device, no TCC
// grant, no credits. That is the whole reason LiveAudio is a library and not code inside the
// tap: a resampler that drifts over an hour, a ring that blocks the audio callback, and a
// mixer that wraps a loud passage are all wrong in ways a compiler cannot see, and all
// three must be replayable with nothing plugged in.
//
// An executable rather than a testTarget for the same reason as every other check in this
// package: this box has Command Line Tools only, so there is no XCTest to link against.
//
// The standing rule here: a limb that cannot fail is worse than no limb. Every
// check below names the mutation that must break it, and `live-audio-mutations.sh` applies
// each one and asserts the NAMED limb goes red.
import Foundation
import AVFoundation
import LiveAudio

// UNBUFFERED, and not as a style preference. Through a pipe — which is how the mutation
// harness runs this — stdout is block-buffered, so a limb that TRAPS takes every line
// printed before it down with the process. The "clamp only the positive rail" mutation does
// exactly that: it fails the negative-rail limb and then traps two limbs later on
// `Int16(-57342)`, and the harness saw an empty output and could not tell which limb bit.
setvbuf(stdout, nil, _IONBF, 0)

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

@MainActor
func section(_ s: String) { print("\n\(s)") }

// ------------------------------------------------------------------ signal generators

/// A continuous sine, generated over an absolute sample index so that slicing it into
/// chunks produces a phase-continuous stream. Any discontinuity the resampler's output
/// shows is therefore the resampler's, not the fixture's.
func sine(from start: Int, count: Int, hz: Double, rate: Double, amplitude: Float = 0.5) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    let w = 2.0 * Double.pi * hz / rate
    for i in 0..<count {
        out[i] = amplitude * Float(Foundation.sin(w * Double(start + i)))
    }
    return out
}

/// The largest absolute sample-to-sample step in a buffer. A clean 440 Hz sine at 16 kHz
/// can never step further than 2*pi*440/16000 ~= 0.173 of its amplitude; a converter that
/// restarts at every chunk boundary puts a filter transient there and the step blows past it.
func maxStep(_ xs: [Float]) -> Float {
    guard xs.count > 1 else { return 0 }
    var m: Float = 0
    for i in 1..<xs.count { m = max(m, abs(xs[i] - xs[i - 1])) }
    return m
}

// =========================================================== limb 1 — the streaming rate
section("limb 1 — resampler holds its rate across 60 s of 250 ms chunks")

let inRate = 48_000.0
let chunkSamples = Int(inRate * 0.25)          // 250 ms at 48 kHz = 12,000
let chunkCount = 240                           // 60 s
let fmt48 = AudioFormatID(sampleRate: inRate)

guard let r1 = StreamingResampler() else {
    print("  FAIL  could not build a resampler at all"); exit(1)
}

var streamed: [Float] = []
var streamedPerChunk: [Int] = []
var pushError: String?
for c in 0..<chunkCount {
    let input = sine(from: c * chunkSamples, count: chunkSamples, hz: 440, rate: inRate)
    do {
        let out = try r1.push(input, format: fmt48)
        streamed.append(contentsOf: out.samples)
        streamedPerChunk.append(out.samples.count)
    } catch {
        pushError = "\(error)"; break
    }
}

check("60 s of chunks convert without an error", pushError == nil,
      breaksIf: "push() starts throwing on a steady-format stream")

// The rate claim, stated as a rate and not as a count: over 60 s of input the output must
// be 16 kHz to within one sample per chunk. Expressed as total samples so a slow leak
// accumulates into the number instead of hiding inside per-chunk rounding.
let expectedTotal = Double(chunkSamples * chunkCount) * (16_000.0 / inRate)
let totalDrift = abs(Double(streamed.count) - expectedTotal)
print("        60 s in: \(chunkSamples * chunkCount) @ \(Int(inRate)) Hz"
      + " -> out: \(streamed.count) @ 16000 Hz (expected \(Int(expectedTotal)),"
      + " drift \(String(format: "%.0f", totalDrift)) samples)")

// One output frame of slack for the converter's own priming latency, and not one more.
// A per-chunk reset leaks a whole filter's worth at every one of the 240 boundaries.
check("total output is within 1 chunk of the exact 3:1 ratio over 60 s",
      totalDrift <= Double(chunkSamples) * (16_000.0 / inRate),
      breaksIf: "the converter is rebuilt per chunk, or endOfStream is signalled per chunk")

// Rate held at the END, not just on average: measure the last 10 s alone, so a converter
// that drifts early and settles cannot pass on a favourable total.
let tailChunks = 40
let tailOut = streamedPerChunk.suffix(tailChunks).reduce(0, +)
let tailExpected = Double(chunkSamples * tailChunks) * (16_000.0 / inRate)
// The label carries NO computed number. A label that interpolates a value the mutation
// changes cannot be grepped for by the falsification harness, so the limb becomes
// unmutatable — a check nothing is watching.
print("        last 10 s: \(tailOut) samples out (expected \(Int(tailExpected)))")
check("the last 10 s of the stream is still at 16 kHz",
      abs(Double(tailOut) - tailExpected) <= 4,
      breaksIf: "rate error accumulates over the take, or the stream stops mid-run")

// The boundary claim. This is the property the one-shot function cannot have.
let step = maxStep(streamed)
let sineCeiling: Float = 0.5 * Float(2.0 * Double.pi * 440.0 / 16_000.0)   // ~0.0864
print("        max sample-to-sample step: \(String(format: "%.5f", step))"
      + " (a clean 440 Hz sine cannot exceed \(String(format: "%.5f", sineCeiling)))")
check("no discontinuity at any of the 239 chunk boundaries",
      step < sineCeiling * 1.5,
      breaksIf: "converter state is reset between chunks (the boundary transient appears)")

// Not a tautology against the line above: prove the instrument can SEE a seam, by building
// the same stream the one-shot way — a fresh converter per chunk, endOfStream each time.
// If this does not blow the ceiling, the boundary limb above is measuring nothing.
func oneShotStream() -> [Float] {
    var acc: [Float] = []
    for c in 0..<chunkCount {
        let input = sine(from: c * chunkSamples, count: chunkSamples, hz: 440, rate: inRate)
        guard let rr = StreamingResampler() else { continue }
        // A fresh resampler per chunk reproduces the STATE-RESET half of the one-shot
        // function: a cold converter at every boundary, which is the half that puts the
        // transient there. It is deliberately NOT a claim of equivalence — the real
        // `Audio.resampleTo16k` also signals `.endOfStream` and flushes its tail, and it
        // cannot be called from here anyway: it lives in the frozen `meeting-capture` target
        // and the no-reuse invariant forbids importing it.
        if let out = try? rr.push(input, format: fmt48) { acc.append(contentsOf: out.samples) }
    }
    return acc
}
let oneShot = oneShotStream()
let oneShotStep = maxStep(oneShot)
print("        the same stream converted one-shot-per-chunk steps \(String(format: "%.5f", oneShotStep))")
check("the boundary instrument can see a seam (one-shot-per-chunk exceeds the ceiling)",
      oneShotStep > sineCeiling * 1.5,
      breaksIf: "maxStep stops resolving a filter transient — then limb 1's boundary check is blind")

// =============================================================== limb 2 — the PCM ring
section("limb 2 — PCM ring drops oldest, counts it, and never waits")

@Sendable func frame(_ n: UInt64) -> PCMFrame {
    PCMFrame(seq: n, hostTimeNs: n * 250_000_000, pcm: [Int16](repeating: 0, count: 4_000))
}

let ring = PCMRing(capacity: 8)
var headroomReports = 0
for i in 1...8 where ring.append(frame(UInt64(i))) { headroomReports += 1 }
check("a ring filled exactly to capacity drops nothing", ring.droppedFrames == 0,
      breaksIf: "eviction fires before the ring is actually full")
print("        appends reporting headroom: \(headroomReports)/8")
check("every append below capacity reports headroom",
      headroomReports == 8,
      breaksIf: "append returns false without having evicted anything")

let ring2 = PCMRing(capacity: 8)
var reportedEvictions = 0
for i in 1...20 where ring2.append(frame(UInt64(i))) == false { reportedEvictions += 1 }

check("20 frames into a ring of 8 evicts exactly 12", ring2.droppedFrames == 12,
      breaksIf: "the drop counter stops counting, or capacity is not enforced")
print("        evictions reported by append's return value: \(reportedEvictions)")
check("append's return value reports every eviction",
      reportedEvictions == 12,
      breaksIf: "append returns true on an evicting append — the tap's stderr under-reports")

let survivors = ring2.drain().map(\.seq)
check("the survivors are the NEWEST 8, not the oldest 8",
      survivors == [13, 14, 15, 16, 17, 18, 19, 20],
      breaksIf: "eviction changes to drop-newest")
check("the last dropped seq is 12, so the consumer sees the 12->13 hole",
      ring2.lastDroppedSeq == 12,
      breaksIf: "the arriving frame's seq is recorded as the dropped one instead of the evicted one")
check("drain empties the ring", ring2.pending == 0,
      breaksIf: "drain copies instead of taking")

// seq is assigned by the tap and must travel untouched: the whole staleness signal on the
// consumer side is a `seq` discontinuity. A ring that renumbers hides its own loss.
let ring3 = PCMRing(capacity: 4)
for i in stride(from: UInt64(100), through: 107, by: 1) { ring3.append(frame(i)) }
check("seq is carried, never reassigned", ring3.drain().map(\.seq) == [104, 105, 106, 107],
      breaksIf: "drain renumbers frames from zero")

// The "never waits" half. Measured with a watchdog rather than asserted, because a blocking
// append does not fail a check — it hangs the whole run, and a hung check reads as a stall
// in CI rather than as a defect in the ring.
let blockingRing = PCMRing(capacity: 4)
let done = DispatchSemaphore(value: 0)
let started = Date()
DispatchQueue.global().async {
    for i in 1...100_000 { blockingRing.append(frame(UInt64(i))) }
    done.signal()
}
let finished = done.wait(timeout: .now() + 5) == .success
let elapsed = Date().timeIntervalSince(started)
print("        100,000 appends into a never-drained ring of 4: "
      + (finished ? String(format: "%.3f s", elapsed) : "TIMED OUT at 5 s"))
check("100,000 appends against a full, never-drained ring complete without waiting",
      finished,
      breaksIf: "append waits on the writer — a semaphore, a sleep, or a retry loop")
check("the drop counter survives 100,000 evictions",
      blockingRing.droppedFrames == 100_000 - 4,
      breaksIf: "the counter is not held under the same lock as the eviction")

// ==================================================================== limb 3 — the mixer
section("limb 3 — mixer sums and clips without wrapping")

// THE TWO CLAMPS ARE MEASURED SEPARATELY, and the first version of this limb did not do
// that. It went only through `mixToPCM16`, where `sum` clamps to [-1, 1] before `toPCM16`
// ever sees a sample — so removing `toPCM16`'s clamp changed nothing the limb could see,
// and the mutation harness reported the suite passing under it. A guard whose input is
// already in range on the only path that reaches it is a guard that cannot fail.
// Each clamp is now driven with values only it can be given.

// (a) the summing clamp — the passage that matters: both people loud at once.
let loudA = [Float](repeating: 0.9, count: 1_000)
let loudB = [Float](repeating: 0.8, count: 1_000)
let summedLoud = Mixer.sum(loudA, loudB)
check("a 0.9 + 0.8 sum is clipped to the rail, not left at 1.7",
      summedLoud.allSatisfy { abs($0 - 1.0) < 1e-6 },
      breaksIf: "the clamp is removed from sum — 1.7 reaches the Int16 conversion")

let loudNegA = [Float](repeating: -0.9, count: 1_000)
let loudNegB = [Float](repeating: -0.85, count: 1_000)
let summedNeg = Mixer.sum(loudNegA, loudNegB)
check("the negative rail clips symmetrically",
      summedNeg.allSatisfy { abs($0 + 1.0) < 1e-6 },
      breaksIf: "only the positive rail is clamped")

// (b) the encoding clamp, driven directly with out-of-range floats. Nothing on the tap's
// own path can hand it these, which is precisely why it needs its own limb: it is the last
// line of defence for any future caller that encodes without summing first.
let encodedHot = Mixer.toPCM16([1.7, -1.75, 3.0, -3.0])
check("toPCM16 clamps out-of-range input to the Int16 rails",
      encodedHot == [32767, -32767, 32767, -32767],
      breaksIf: "the clamp is removed from toPCM16 — 1.7 * 32767 = 55,703 does not fit")
check("no sample flips sign (the wrap signature)",
      encodedHot[0] > 0 && encodedHot[1] < 0 && encodedHot[2] > 0 && encodedHot[3] < 0,
      breaksIf: "the Int16 conversion truncates instead of clamping")

// (c) and the end-to-end path the tap actually calls.
let mixed = Mixer.mixToPCM16(mic: loudA, system: loudB)
check("the full mix path clips a loud two-way passage to full scale",
      mixed.allSatisfy { $0 == 32767 },
      breaksIf: "either clamp is lost on the composed path")

// A quiet mix must be untouched: a clipper that clips when it should not is just as wrong,
// and would show up as distortion on every normal passage instead of only on loud ones.
let quietA = [Float](repeating: 0.2, count: 8)
let quietB = [Float](repeating: 0.1, count: 8)
let quietMix = Mixer.sum(quietA, quietB)
check("a quiet mix sums linearly and is not clipped",
      quietMix.allSatisfy { abs($0 - 0.3) < 1e-6 },
      breaksIf: "the clamp is applied at the wrong threshold")

// Unequal chunk lengths are the normal case, not the edge: mic and system are independent
// capture sources whose buffers never arrive frame-aligned.
let short = [Float](repeating: 0.25, count: 3)
let long = [Float](repeating: 0.25, count: 7)
let ragged = Mixer.sum(short, long)
print("        sum of a 3-sample and a 7-sample chunk is \(ragged.count) samples long")
check("unequal lengths keep every sample",
      ragged.count == 7,
      breaksIf: "the mixer truncates to the shorter track and discards real audio")
check("the overlap sums and the tail passes through",
      ragged.prefix(3).allSatisfy { abs($0 - 0.5) < 1e-6 }
        && ragged.suffix(4).allSatisfy { abs($0 - 0.25) < 1e-6 },
      breaksIf: "the ragged tail is zero-filled instead of carried")

check("an empty track leaves the other one intact",
      Mixer.sum([], [0.4, -0.4]) == [0.4, -0.4] && Mixer.sum([0.4], []) == [0.4],
      breaksIf: "an absent source zeroes the present one")

// Round-trip the wire encoding, since the tap writes these bytes straight to stdout.
let bytes = Mixer.littleEndianBytes([Int16(1), Int16(-2), Int16(32767)])
check("PCM16 goes out little-endian, 2 bytes per sample",
      bytes.count == 6 && [UInt8](bytes) == [0x01, 0x00, 0xFE, 0xFF, 0xFF, 0x7F],
      breaksIf: "the encoder emits big-endian or pads")

// ================================================== limb 13 — the mid-stream format change
section("limb 13 — a mid-stream format change reinitialises or hard-fails, never emits")

let fmt44 = AudioFormatID(sampleRate: 44_100)

// (a) hardFail: the transition is thrown, and NOTHING converted comes back with it.
guard let rFail = StreamingResampler(policy: .hardFail) else {
    print("  FAIL  could not build a hardFail resampler"); exit(1)
}
_ = try? rFail.push(sine(from: 0, count: chunkSamples, hz: 440, rate: inRate), format: fmt48)
var threwOnChange = false
var emittedAcrossChange = false
do {
    let out = try rFail.push(sine(from: 0, count: 11_025, hz: 440, rate: 44_100), format: fmt44)
    emittedAcrossChange = !out.samples.isEmpty
} catch ResampleError.formatChanged(let t) {
    threwOnChange = (t.from == fmt48 && t.to == fmt44)
} catch {
    // Any other error still means nothing was emitted, but the transition was not named.
}
check("hardFail throws .formatChanged naming both formats", threwOnChange,
      breaksIf: "the policy branch is dropped and the converter keeps going")
check("hardFail emits NO samples across the transition", !emittedAcrossChange,
      breaksIf: "the stale converter converts the new-format chunk anyway")

// A caught error must not leave a usable stale converter behind: a caller that retries the
// same chunk must not be handed a conversion the first call refused.
var resumedAfterThrow = false
if let out = try? rFail.push(sine(from: 0, count: 11_025, hz: 440, rate: 44_100), format: fmt44) {
    // Legal: the converter was torn down, so this rebuilds at 44.1 kHz. What must NOT
    // happen is it succeeding while still holding the 48 kHz converter.
    resumedAfterThrow = !out.samples.isEmpty && rFail.currentFormat == fmt44
}
check("after a hardFail throw the resampler is rebuilt, not resumed", resumedAfterThrow,
      breaksIf: "the stale converter is left in place after the throw")

// (b) reinitialise: the transition is REPORTED, the generation bumps, and the samples that
// come back are the new format's — converted by the new converter, never carried across.
guard let rReinit = StreamingResampler(policy: .reinitialise) else {
    print("  FAIL  could not build a reinitialise resampler"); exit(1)
}
_ = try? rReinit.push(sine(from: 0, count: chunkSamples, hz: 440, rate: inRate), format: fmt48)
let genBefore = rReinit.generation
var reported: FormatTransition?
var postChange: [Float] = []
do {
    let out = try rReinit.push(sine(from: 0, count: 11_025, hz: 440, rate: 44_100), format: fmt44)
    reported = out.transition
    postChange = out.samples
} catch {
    print("        unexpected throw under .reinitialise: \(error)")
}
check("the transition is reported to the caller so the tap can re-emit its header",
      reported?.from == fmt48 && reported?.to == fmt44,
      breaksIf: "the transition is handled silently — the ring never goes stale")
print("        generation \(genBefore) -> \(rReinit.generation) across one transition")
check("the header version counter bumps exactly once",
      rReinit.generation == genBefore + 1,
      breaksIf: "generation is not bumped — a restart is indistinguishable from a continuation")

// The garbage this limb exists to prevent, measured rather than asserted. 44.1 kHz audio
// pushed through a converter built for 48 kHz comes out at the wrong rate: a 440 Hz tone
// arrives as ~404 Hz. Counting zero crossings is enough to tell them apart.
func dominantHz(_ xs: [Float], rate: Double) -> Double {
    guard xs.count > 2 else { return 0 }
    var crossings = 0
    for i in 1..<xs.count where (xs[i - 1] < 0) != (xs[i] < 0) { crossings += 1 }
    return Double(crossings) * rate / (2.0 * Double(xs.count))
}
let hz = dominantHz(postChange, rate: 16_000)
print("        post-transition tone reads \(String(format: "%.1f", hz)) Hz"
      + " (440 correct; ~404 is 44.1 kHz audio through a 48 kHz converter)")
check("the post-transition audio is at the right pitch, not resampled by the stale converter",
      abs(hz - 440) < 15,
      breaksIf: "the converter is reused across the transition — the tone drops to ~404 Hz")
check("the pitch instrument resolves the 36 Hz it has to resolve",
      abs(dominantHz(sine(from: 0, count: 16_000, hz: 404, rate: 16_000), rate: 16_000) - 404) < 15,
      breaksIf: "dominantHz stops distinguishing 404 from 440 — then the limb above is blind")

// A same-rate, different-channel-count swap is still a transition. It is the one a rate
// comparison alone would wave through.
guard let rCh = StreamingResampler(policy: .reinitialise) else {
    print("  FAIL  could not build a channel-change resampler"); exit(1)
}
_ = try? rCh.push([Float](repeating: 0.1, count: 4_000), format: AudioFormatID(sampleRate: 16_000, channels: 1))
var stereoRefused = false
var stereoTransition: FormatTransition?
do {
    let out = try rCh.push([Float](repeating: 0.1, count: 4_000),
                           format: AudioFormatID(sampleRate: 16_000, channels: 2))
    stereoTransition = out.transition
} catch ResampleError.converterUnavailable {
    stereoRefused = true
} catch { }
check("a channel-count change at the same rate is a transition, not a pass-through",
      stereoRefused || stereoTransition != nil,
      breaksIf: "format identity compares sample rate only")
check("an unsupported channel count is refused rather than reinterpreted as mono",
      stereoRefused,
      breaksIf: "multichannel input is fed to a mono converter as though it were mono")

// The pass-through path is where a format change is easiest to miss, because there is no
// converter to rebuild. It must still count as a transition.
guard let rPass = StreamingResampler(policy: .hardFail) else {
    print("  FAIL  could not build a pass-through resampler"); exit(1)
}
_ = try? rPass.push([Float](repeating: 0.1, count: 4_000), format: AudioFormatID(sampleRate: 16_000))
var passThroughCaught = false
do {
    _ = try rPass.push([Float](repeating: 0.1, count: 4_000), format: fmt48)
} catch ResampleError.formatChanged { passThroughCaught = true } catch { }
check("a transition OUT of the 16 kHz pass-through path is caught too", passThroughCaught,
      breaksIf: "the pass-through shortcut returns before the format comparison")

// ======================================================= limb 15 — the framed stdout contract
section("limb 15 — the §2.0 wire format is the bytes the table says it is")

// EVERY ASSERTION HERE IS A BYTE LITERAL TRANSCRIBED FROM THE LAYOUT TABLE IN `WireFormat`,
// never a round-trip through a decoder written in this file. A Swift decoder beside a Swift
// encoder measures the pair against each other: both could be wrong in the same direction and
// agree perfectly. That is a bar scored against something other than the thing it certifies,
// and the consumer that has to agree with these bytes is written in another language. It gets
// these same literals as its fixture.

let hdr = WireFormat.header(sampleRate: 16_000, channels: 1, frameSamples: 4_000, generation: 0)
check("the stream header is exactly 16 bytes", hdr.count == 16,
      breaksIf: "a field is added, widened or dropped without the spec table moving with it")

// 4D 43 4B 31  'MCK1'
// 01           protocol version
// 01           channels
// 80 3E 00 00  sample rate 16000, LE
// A0 0F        frame samples 4000, LE
// 00 00 00 00  generation 0, LE
let hdrExpected: [UInt8] = [0x4D, 0x43, 0x4B, 0x31, 0x01, 0x01,
                            0x80, 0x3E, 0x00, 0x00, 0xA0, 0x0F,
                            0x00, 0x00, 0x00, 0x00]
print("        header: \([UInt8](hdr).map { String(format: "%02X", $0) }.joined(separator: " "))")
check("the header matches the §2.0 byte layout exactly",
      [UInt8](hdr) == hdrExpected,
      breaksIf: "field order, width or endianness changes — the consumer misdecodes every frame")

// The generation is a separate field from the protocol version, and here is why: folding
// them into one number makes a change to this file look to the consumer exactly like AirPods
// connecting. Driven with a value whose four bytes are all distinct so a misplaced write shows.
let hdrGen = WireFormat.header(sampleRate: 16_000, channels: 1, frameSamples: 4_000,
                               generation: 0x0102_0304)
check("generation is written little-endian at offset 12",
      [UInt8](hdrGen)[12...15] == [0x04, 0x03, 0x02, 0x01],
      breaksIf: "generation moves, changes width, or is written big-endian")
check("bumping the generation does not touch the protocol version byte",
      [UInt8](hdrGen)[4] == 0x01 && [UInt8](hdrGen)[4] == [UInt8](hdr)[4],
      breaksIf: "the two version fields are collapsed into one — a protocol change reads as a format transition")

let wireFrame = WireFormat.frame(seq: 1, tsMs: 250, pcm: [Int16(1), Int16(-2), Int16(32767)])
check("a frame is an 8-byte prefix plus 2 bytes per sample",
      wireFrame.count == 8 + 6,
      breaksIf: "the prefix is resized, or the payload is padded")
// 01 00 00 00  seq 1, LE
// FA 00 00 00  ts 250 ms, LE
print("        prefix: \([UInt8](wireFrame).prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))")
check("the frame prefix is seq then ts, both little-endian",
      [UInt8](wireFrame).prefix(8) == [0x01, 0x00, 0x00, 0x00, 0xFA, 0x00, 0x00, 0x00],
      breaksIf: "seq and ts swap places, or either is written big-endian")
check("the payload is the mixer's little-endian PCM16, unaltered",
      [UInt8](wireFrame).suffix(6) == [0x01, 0x00, 0xFE, 0xFF, 0xFF, 0x7F],
      breaksIf: "the frame encoder re-encodes the samples instead of using the wire encoder")

// The discriminator. A header is re-emitted mid-stream, so the consumer tells one from
// a frame prefix on the first four bytes. That is sound only while no legal seq has the magic
// as its little-endian form — which is one specific value, ~1.28e9 frames in.
check("the seq generator skips the one value that would be read as a header",
      WireFormat.nextSeq(after: WireFormat.magicSeq &- 1) == WireFormat.magicSeq &+ 1,
      breaksIf: "the skip is removed — one frame in 1.28 billion is decoded as a header and the stream desynchronises")
check("the skipped value really is the header magic read little-endian",
      [UInt8](WireFormat.frame(seq: WireFormat.magicSeq, tsMs: 0, pcm: []).prefix(4)) == WireFormat.magic,
      breaksIf: "magicSeq stops matching the magic — then the skip above guards the wrong number and the limb beside it is blind")
check("an ordinary seq advances by one",
      WireFormat.nextSeq(after: 7) == 8,
      breaksIf: "the skip fires on values it should not, silently gapping the stream every frame")

// ============================================== limb 16 — when a re-emitted header goes out
section("limb 16 — the header is announced at the frame that opens its generation")

// The ordering rule, and the race it exists to prevent: the tick thread discovers a
// discontinuity and assigns seq, while a different thread writes the bytes. A header written
// by the discovering thread lands in front of frames still sitting in the ring — telling the
// consumer that OLDER audio belongs to the NEWER generation, which is the staleness signal
// pointing at the wrong span.

let gl = GenerationLog()
gl.mark(seq: 0, generation: 0)
check("the opening header is announced before the first frame",
      gl.take(upTo: 0) == 0,
      breaksIf: "the opening header takes a different code path from a mid-stream re-emission")
check("announcing is one-shot — the same header is not re-emitted per frame",
      gl.take(upTo: 1) == nil,
      breaksIf: "take() peeks instead of consuming — a header before every frame")

gl.mark(seq: 10, generation: 1)
check("a generation whose frames have not been written yet is not announced early",
      gl.take(upTo: 9) == nil,
      breaksIf: "the comparison is >= off by one, or ordering is ignored entirely")
check("it is announced exactly at the frame that opens it",
      gl.take(upTo: 10) == 1,
      breaksIf: "the header lands one frame late — the first frame of the new generation reads as the old one")

// Two bumps with the ring dropping everything between them. Announcing the intermediate
// generation would name audio the consumer never received; the seq gap already says stale.
let gl2 = GenerationLog()
gl2.mark(seq: 5, generation: 1)
gl2.mark(seq: 7, generation: 2)
check("when the ring drops across two bumps, only the surviving generation is announced",
      gl2.take(upTo: 20) == 2,
      breaksIf: "intermediate generations are announced for frames that were never written")
check("both points are consumed, so neither is announced again later",
      gl2.pending == 0 && gl2.take(upTo: 100) == nil,
      breaksIf: "only the last point is popped and the earlier one is announced after it")

// ==================================================== limb 17 — the frame assembler
section("limb 17 — frames are whole, never padded, and one dead source cannot stall the mix")

let sec: UInt64 = 1_000_000_000
// `@Sendable` because limb 17(g) calls this from a `DispatchQueue.global()` closure. It is a
// pure function over its arguments with no captured state, so the annotation only tells the
// compiler what is already true. Without it the closure captures a non-`@Sendable` function
// type and the check target builds with a concurrency warning, which is the noise a real one
// would then hide in.
@Sendable func block(_ v: Float, _ n: Int) -> [Float] { [Float](repeating: v, count: n) }

// (a) nothing is emitted until a source exists, and a single-source take works.
let fa1 = FrameAssembler(frameSamples: 100)
check("an assembler with no source yet emits nothing", fa1.emit(atNs: sec) == nil,
      breaksIf: "emit builds a frame from an EMPTY contributing set — the stream opens with silence")
// 150 samples: one whole frame plus a remainder too short to be one.
fa1.push(block(0.5, 150), from: .mic, atNs: sec)
let single = fa1.emit(atNs: sec)
check("a mic-only take emits from the mic alone",
      single?.sources == [.mic],
      breaksIf: "the assembler waits for a source that was never started")
check("the frame is exactly one frame long, never the whole backlog",
      single?.pcm.count == 100,
      breaksIf: "emit drains the backlog into one oversized frame")
check("a partial remainder is held back, not padded out to a frame",
      fa1.emit(atNs: sec) == nil && fa1.backlog(.mic) == 50,
      breaksIf: "the shortfall is zero-padded — every jitter dip inserts silence that is never taken back")

// (b) with two sources, a frame needs a full frame from BOTH. This is also the positive
// control for the anti-stall limb below: without it, that limb could pass on an assembler
// that never waits for anything.
let fa2 = FrameAssembler(frameSamples: 100)
fa2.push(block(0.25, 100), from: .mic, atNs: sec)
fa2.push(block(0.25, 40), from: .system, atNs: sec)
check("a frame is withheld while one active source is short",
      fa2.emit(atNs: sec) == nil,
      breaksIf: "the shorter source is padded, or dropped from the mix without being starved")
fa2.push(block(0.25, 60), from: .system, atNs: sec)
let mixedFrame = fa2.emit(atNs: sec)
check("both sources present, the frame goes out", mixedFrame?.sources == [.mic, .system],
      breaksIf: "a source that caught up is not readmitted to the mix")
check("the frame is the SUM of the two sources, not one of them",
      mixedFrame?.pcm.allSatisfy { $0 == Int16((0.5 * 32767).rounded()) } == true,
      breaksIf: "the mixer is bypassed, or one track is dropped from the composed path")

// (c) the anti-stall rule. A source that dies must not take the stream with it.
let fa3 = FrameAssembler(frameSamples: 100, starveTimeoutNs: 2 * sec)
fa3.push(block(0.5, 100), from: .mic, atNs: sec)
fa3.push(block(0.5, 100), from: .system, atNs: sec)
_ = fa3.emit(atNs: sec)
// The system source now goes quiet while the mic keeps delivering.
fa3.push(block(0.5, 400), from: .mic, atNs: 2 * sec)
check("a source that is merely late does not stall the stream forever, but it does stall it for now",
      fa3.emit(atNs: 2 * sec) == nil,
      breaksIf: "the starvation timeout is ignored and a late source is dropped immediately")
fa3.push(block(0.5, 400), from: .mic, atNs: 4 * sec)
let afterStarve = fa3.emit(atNs: 4 * sec)
check("past the timeout the dead source is dropped and the stream CONTINUES",
      afterStarve?.sources == [.mic],
      breaksIf: "a dead source stalls the mix — the socket stays up and the transcript silently stops")
check("the surviving source's frames are still whole",
      afterStarve?.pcm.count == 100,
      breaksIf: "a starved source's absence is padded into the survivor's timeline")
// THE FRAME CARRIES ITS OWN REASON, and this limb is why it has to: `emit` latches the starve
// and returns the post-splice frame in the SAME call, so a reason read separately afterwards
// is read one frame too late and gets attached to the seq after this one.
check("the starve rides out ON the frame that opens the new generation",
      afterStarve?.discontinuityBefore == .sourceStarved,
      breaksIf: "the reason is polled separately from the frame — it lands on the wrong seq and a splice reads as seamless")
check("the reason is consumed by the frame, not left to fire again",
      fa3.pendingDiscontinuity == nil,
      breaksIf: "the latch is not cleared — the tap bumps the generation on every following frame")
check("the starve is counted", fa3.starveEvents(.system) == 1 && fa3.isStarved(.system),
      breaksIf: "the counter is not incremented under the same lock as the state change")

// (d) resume: the stale backlog is dropped rather than played late against live audio.
fa3.push(block(0.5, 100), from: .system, atNs: 5 * sec)
check("a resumed source is latched as a discontinuity too",
      fa3.pendingDiscontinuity == .sourceResumed,
      breaksIf: "resume is silent — the consumer never learns the two spans do not join up")
check("resume clears the starved flag and readmits the source",
      !fa3.isStarved(.system) && fa3.resumeEvents(.system) == 1,
      breaksIf: "a source that came back stays excluded for the rest of the take")
// A REASON MUST SURVIVE AN EMIT THAT RETURNS NIL. Written as its own fixture, because the
// first version of this limb tried to reuse fa3 and its `emit` had both sources ready — so it
// returned a frame, legitimately consumed the reason, and the limb failed while the code was
// right. A check whose setup does not reach the state it names is not a check.
let fa9 = FrameAssembler(frameSamples: 100, maxBacklogSamples: 200)
fa9.push(block(0.5, 250), from: .mic, atNs: sec)      // 250 > 200: resync latched
fa9.push(block(0.5, 40), from: .system, atNs: sec)    // active but short, so no frame is ready
check("no frame can be built while one active source is short of a whole frame",
      fa9.emit(atNs: sec) == nil,
      breaksIf: "the readiness guard is dropped — then this limb stops reaching the state it exists to test")
check("a reason latched while no frame can be built survives the nil emit",
      fa9.pendingDiscontinuity == .backlogResync,
      breaksIf: "the latch is cleared on an emit that returns nil — the splice after it is never announced")
fa9.push(block(0.5, 60), from: .system, atNs: sec)
check("and rides out on the first frame that can carry it",
      fa9.emit(atNs: sec)?.discontinuityBefore == .backlogResync,
      breaksIf: "the reason is dropped rather than held until a frame exists to attach it to")

// (e) the backlog bound. Only reachable when the OTHER source is behind, so it bounds
// inter-source skew rather than total memory.
let fa4 = FrameAssembler(frameSamples: 100, maxBacklogSamples: 400)
// The first 100 samples are marked distinctly from the other 400, so WHICH 100 were dropped
// is observable in the audio. A count cannot tell drop-oldest from drop-newest — both leave
// exactly 400 behind — and drop-newest is the whole reason this limb exists: it holds a
// stale window while live speech is thrown away, and leaves no seq gap to detect.
fa4.push(block(0.1, 100) + block(0.9, 400), from: .mic, atNs: sec)
fa4.push(block(0.0, 400), from: .system, atNs: sec)
check("a backlog past its bound is clipped to the bound",
      fa4.backlog(.mic) == 400,
      breaksIf: "the bound is not enforced — inter-source skew grows without limit")
check("the dropped count is the overflow, not the whole buffer",
      fa4.backlogDropped(.mic) == 100,
      breaksIf: "the counter records the wrong quantity — the soak's skew number becomes fiction")
check("a resync drop is latched as a discontinuity",
      fa4.pendingDiscontinuity == .backlogResync,
      breaksIf: "the splice is silent — a resync produces no seq gap, so nothing else can signal it")
let survivor = fa4.emit(atNs: sec)
check("the resync rides out on the first frame of post-hole audio",
      survivor?.discontinuityBefore == .backlogResync,
      breaksIf: "the reason is not attached to the frame — the header names a seq on the wrong side of the hole")
print("        first surviving sample reads \(survivor?.pcm.first ?? -1)"
      + " (~29490 = the 0.9 block survived; ~3277 = the 0.1 block did)")
check("it is the OLDEST samples that were dropped, not the newest",
      (survivor?.pcm.first ?? 0) > 20_000,
      breaksIf: "eviction changes to drop-newest — a stale window is kept and live speech discarded")

// (f) the latch is one-shot but the count is not: three events between two ticks collapse
// into one generation bump, which is correct, and all three are still counted.
let fa5 = FrameAssembler(frameSamples: 100, maxBacklogSamples: 200)
fa5.push(block(0.1, 100), from: .system, atNs: sec)
fa5.push(block(0.1, 300), from: .mic, atNs: sec)
fa5.push(block(0.1, 300), from: .mic, atNs: sec)
check("every discontinuity is counted", fa5.discontinuities == 2,
      breaksIf: "the counter is only incremented when the latch was empty")
check("three events between two frames collapse to ONE announced reason",
      fa5.emit(atNs: sec)?.discontinuityBefore == .backlogResync
        && fa5.emit(atNs: sec)?.discontinuityBefore == nil,
      breaksIf: "the latch is not cleared — the tap bumps the generation on every following frame forever")

// =============================== limb 18 — the format transition reaches the same latch
section("limb 18 — a mid-take format change is announced like every other discontinuity")

// THE DEFECT THIS LIMB EXISTS FOR. The tap used to take the resampler's transition report and
// bump its own generation counter directly, never touching the GenerationLog — so AirPods
// connecting mid-meeting, the one event the whole mechanism was written for, produced a bump
// with NO header on the wire, `seq` contiguous across the splice, and a consumer that read it
// as one continuous generation. Worse, the NEXT real discontinuity then announced a
// generation two higher, making the omission indistinguishable from an ordinary bump.
let fa7 = FrameAssembler(frameSamples: 100)
fa7.push(block(0.5, 100), from: .mic, atNs: sec)
_ = fa7.emit(atNs: sec)
check("a format transition latches a discontinuity like the other three",
      { fa7.noteFormatTransition(.mic); return fa7.pendingDiscontinuity == .sourceFormatChanged }(),
      breaksIf: "the tap bumps its own counter instead — a generation change with no header, which is no signal at all")
check("the format transition is counted per source",
      fa7.formatTransitions(.mic) == 1 && fa7.formatTransitions(.system) == 0,
      breaksIf: "the counter is shared or not incremented — the kv line stops distinguishing which device changed")
fa7.push(block(0.5, 100), from: .mic, atNs: 2 * sec)
check("it rides out on the next frame, through the one path all four causes share",
      fa7.emit(atNs: 2 * sec)?.discontinuityBefore == .sourceFormatChanged,
      breaksIf: "the format cause takes a different route to the wire than the assembler's three")

// THE DIRECTION OF THE ERROR, asserted rather than described. Samples captured BEFORE the
// transition are still in the FIFO, so the announcement can LEAD the splice by up to a
// backlog. It must never LAG it: leading makes the consumer distrust a little good audio,
// lagging makes it trust spliced audio, and only one of those loses a card its grounding.
let fa8 = FrameAssembler(frameSamples: 100)
fa8.push(block(0.5, 350), from: .mic, atNs: sec)      // 3 frames' worth already queued
fa8.noteFormatTransition(.mic)                        // the splice happens here
let leadFrame = fa8.emit(atNs: sec)
check("the announcement LEADS the splice rather than lagging it",
      leadFrame?.discontinuityBefore == .sourceFormatChanged,
      breaksIf: "the reason waits for the pre-transition backlog to drain — then frames of spliced audio ship as continuous")

// (g) push never waits. Measured with a watchdog for the same reason as the ring: a blocking
// push does not fail a check, it hangs the run, and a hung run reads as a stall in CI.
let fa6 = FrameAssembler(frameSamples: 100, maxBacklogSamples: 1_000)
let pushDone = DispatchSemaphore(value: 0)
let pushStart = Date()
DispatchQueue.global().async {
    let chunk = block(0.1, 100)
    for _ in 0..<50_000 { fa6.push(chunk, from: .mic, atNs: sec) }
    pushDone.signal()
}
let pushFinished = pushDone.wait(timeout: .now() + 10) == .success
print("        50,000 pushes into a never-drained assembler: "
      + (pushFinished ? String(format: "%.3f s", Date().timeIntervalSince(pushStart)) : "TIMED OUT at 10 s"))
check("50,000 pushes against a full, never-drained assembler complete without waiting",
      pushFinished,
      breaksIf: "push waits for the tick thread — a semaphore, a sleep, or a retry loop in an audio callback")

// ------------------------------------------------------------------------------ verdict
print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("live-audio-check FAILED")
    exit(1)
}
print("live-audio-check OK")
