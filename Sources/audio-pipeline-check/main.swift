// Runnable verification for the audio pipeline: `swift run audio-pipeline-check`.
//
// This is the path EVERY user of `meeting-capture` runs, and until this file existed it
// was the only part of the package with no coverage at all. It needs no microphone, no
// screen recording grant, no display and no network. Every input here is synthesised.
//
// The load-bearing check is EQUIVALENCE. The recorder used to hold an entire meeting in
// memory, so finalizing was a one-shot resample of one enormous array. It now streams
// from disk in chunks through a single converter. That change is only safe if the bytes
// it produces are the bytes the one-shot path produced, and "only if" is the whole
// reason this file exists rather than a comment claiming it is fine.
import Foundation
import AVFoundation
import CaptureIO

var failures = 0
func check(_ name: String, _ ok: Bool, breaksIf: String = "") {
    if ok {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)" + (breaksIf.isEmpty ? "" : "\n         breaks if: \(breaksIf)"))
    }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("audio-pipeline-check-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

print("=== audio pipeline verification ===\n")

// ---------------------------------------------------------------- fixtures
/// A signal with content across the band, so a resampler that drops or smears
/// anything shows up as a difference rather than as silence matching silence.
func signal(frames: Int, rate: Double) -> [Float] {
    (0..<frames).map { i in
        let t = Double(i) / rate
        let v = 0.45 * sin(2 * .pi * 440 * t)
            + 0.25 * sin(2 * .pi * 1_970 * t)
            + 0.12 * sin(2 * .pi * 5_100 * t)
        return Float(v)
    }
}

func writeRaw(_ samples: [Float], to url: URL) throws {
    try samples.withUnsafeBytes { try Data($0).write(to: url) }
}

func readPCM16(_ path: String) throws -> [Int16] {
    let d = try Data(contentsOf: URL(fileURLWithPath: path))
    guard d.count > 44 else { return [] }
    let body = d.dropFirst(44)
    return body.withUnsafeBytes { raw in
        Array(UnsafeBufferPointer(start: raw.bindMemory(to: Int16.self).baseAddress!,
                                  count: body.count / 2))
    }
}

func wavHeader(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path)).prefix(44)
}

// ---------------------------------------------------------------- 1. equivalence
print("1. streaming finalize vs the one-shot path")

for (nativeRate, seconds, label) in [(48000.0, 3.0, "48 kHz"), (44100.0, 3.0, "44.1 kHz"), (16000.0, 2.0, "16 kHz passthrough")] {
    let frames = Int(nativeRate * seconds)
    let src = signal(frames: frames, rate: nativeRate)

    let oneShotPath = tmp.appendingPathComponent("oneshot-\(Int(nativeRate)).wav").path
    let resampled = try Audio.resampleTo16k(src, nativeRate: nativeRate)
    try Audio.writeWav16(resampled, to: oneShotPath)

    let rawURL = tmp.appendingPathComponent("raw-\(Int(nativeRate)).f32")
    try writeRaw(src, to: rawURL)
    let streamPath = tmp.appendingPathComponent("stream-\(Int(nativeRate)).wav").path
    let dur = try Audio.streamResampleToWav(rawURL: rawURL, nativeRate: nativeRate, leadFrames: 0, to: streamPath)

    let a = try readPCM16(oneShotPath)
    let b = try readPCM16(streamPath)

    check("\(label): frame counts agree (\(a.count) vs \(b.count))",
          abs(a.count - b.count) <= 1,
          breaksIf: "the chunked feed drops or duplicates a frame at a chunk boundary")

    let n = min(a.count, b.count)
    var maxDelta = 0
    var differing = 0
    for i in 0..<n {
        let d = abs(Int(a[i]) - Int(b[i]))
        if d > maxDelta { maxDelta = d }
        if d > 0 { differing += 1 }
    }
    // One LSB of PCM16 is -90 dBFS. Anything beyond a couple of LSBs is a real
    // difference in the filtering, not arithmetic noise.
    check("\(label): samples match within 2 LSB (max delta \(maxDelta), \(differing)/\(n) differ)",
          maxDelta <= 2,
          breaksIf: "each chunk gets its own converter, so the filter rings at every boundary")

    check("\(label): reported duration matches the frames written (\(String(format: "%.4f", dur))s)",
          abs(dur - Double(b.count) / 16000.0) < 0.0005,
          breaksIf: "the duration is computed from the input rather than from what was written")

    check("\(label): headers are byte-identical",
          try wavHeader(oneShotPath) == wavHeader(streamPath),
          breaksIf: "the streaming writer patches a different rate, channel count or size")
}

// ---------------------------------------------------------------- 2. lead padding
print("\n2. alignment padding")
do {
    let rate = 48000.0
    let src = signal(frames: Int(rate), rate: rate)
    let rawURL = tmp.appendingPathComponent("lead.f32")
    try writeRaw(src, to: rawURL)

    let leadFrames = Int(rate / 2)      // 0.5 s at the native rate
    let path = tmp.appendingPathComponent("lead.wav").path
    let dur = try Audio.streamResampleToWav(rawURL: rawURL, nativeRate: rate, leadFrames: leadFrames, to: path)

    check("padding lands at the head, not the tail",
          abs(dur - 1.5) < 0.01,
          breaksIf: "lead frames are counted at the output rate instead of the native rate")

    let pcm = try readPCM16(path)
    let head = pcm.prefix(7_000)        // 0.4375 s of the 0.5 s pad
    check("the padded head is silent",
          head.allSatisfy { abs(Int($0)) <= 2 },
          breaksIf: "the pad is written after the audio, so every timestamp shifts")

    check("a zero lead adds nothing",
          try abs(Audio.streamResampleToWav(rawURL: rawURL, nativeRate: rate, leadFrames: 0,
                                            to: tmp.appendingPathComponent("nolead.wav").path) - 1.0) < 0.01,
          breaksIf: "a guard on leadFrames > 0 is dropped and a negative or zero pad writes frames")
}

// ---------------------------------------------------------------- 3. refusal
print("\n3. failures are refusals, never a quietly wrong file")
do {
    var threw = false
    do { _ = try Audio.resampleTo16k([0.1, 0.2, 0.3], nativeRate: -1) } catch { threw = true }
    check("an impossible rate throws instead of returning the input unresampled",
          threw,
          breaksIf: "the guard returns `samples`, so 48 kHz audio gets a 16 kHz header and plays 3x fast")

    var threw2 = false
    let neverPath = tmp.appendingPathComponent("never.wav").path
    do { _ = try Audio.streamResampleToWav(rawURL: tmp.appendingPathComponent("does-not-exist.f32"),
                                           nativeRate: 48000, leadFrames: 0,
                                           to: neverPath)
    } catch { threw2 = true }
    check("a missing raw capture file throws", threw2,
          breaksIf: "a missing scratch file yields an empty WAV reported as a successful recording")

    // The half of this section's own title that it used to leave untested. Throwing is
    // the easy half; the file is the half a user opens. A 44-byte placeholder header
    // at the destination is not a RIFF file and not a recording, and it used to be
    // exactly what this case left behind.
    check("and leaves NO file at the destination",
          !FileManager.default.fileExists(atPath: neverPath),
          breaksIf: "the writer opens the destination directly, so a failed finalize leaves a 44-byte non-RIFF stub where the recording was announced")

    var threw4 = false
    let rateFailPath = tmp.appendingPathComponent("badrate.wav").path
    do { _ = try Audio.streamResampleToWav(rawURL: tmp.appendingPathComponent("lead.f32"),
                                           nativeRate: -1, leadFrames: 0,
                                           to: rateFailPath)
    } catch { threw4 = true }
    check("an impossible rate throws in the streaming path too", threw4,
          breaksIf: "converter setup failure is swallowed and the raw samples are written under a 16 kHz header")
    check("and that failure leaves NO file either",
          !FileManager.default.fileExists(atPath: rateFailPath),
          breaksIf: "the destination is opened before the converter is built, so a setup failure strands an empty stub")

    // A destination that exists ALREADY must survive a failed rewrite. The temp-file
    // move is what makes that true: without it the previous take is truncated to 44
    // bytes the moment the new one starts, and lost when the new one fails.
    let occupied = tmp.appendingPathComponent("occupied.wav").path
    FileManager.default.createFile(atPath: occupied, contents: Data("PRIOR-TAKE".utf8))
    var threw5 = false
    do { _ = try Audio.streamResampleToWav(rawURL: tmp.appendingPathComponent("does-not-exist.f32"),
                                           nativeRate: 48000, leadFrames: 0, to: occupied)
    } catch { threw5 = true }
    check("a failed write does not destroy the file already at the destination",
          threw5 && (try? Data(contentsOf: URL(fileURLWithPath: occupied))) == Data("PRIOR-TAKE".utf8),
          breaksIf: "the destination is opened for writing before the work that can fail, so a failed take eats the previous one")

    var threw3 = false
    do { _ = try Audio.streamResampleToWav(rawURL: tmp.appendingPathComponent("lead.f32"),
                                           nativeRate: 48000, leadFrames: 0,
                                           to: "/nonexistent-directory-xyz/out.wav")
    } catch { threw3 = true }
    check("an unwritable destination throws", threw3,
          breaksIf: "the write is swallowed and the run reports a duration for a file that is not there")
}

// ---------------------------------------------------------------- 4. the sink
print("\n4. the capture sink")
do {
    let dir = tmp.appendingPathComponent("sink")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sink = try SampleSink(directory: dir.path, name: "mic")
    sink.start()

    let block = signal(frames: 4_800, rate: 48000)
    for _ in 0..<10 {
        block.withUnsafeBufferPointer { sink.append($0.baseAddress!, count: $0.count) }
    }
    let peak = sink.takeLevelPeak()
    check("the sink reports a peak while samples flow (\(String(format: "%.3f", peak)))",
          peak > 0.5 && peak <= 1.0,
          breaksIf: "the peak is not tracked, so every level line reads 0.0000 and the silence gate is blind")

    check("the peak read is destructive", sink.takeLevelPeak() == 0,
          breaksIf: "an untaken peak leaks into the next tick and a quiet interval reads loud")

    try sink.finish()
    let size = try FileManager.default.attributesOfItem(atPath: sink.url.path)[.size] as! Int
    check("every appended frame reached the disk (\(size) bytes for 48,000 frames)",
          size == 48_000 * MemoryLayout<Float>.size,
          breaksIf: "the final flush is skipped, so the tail of every recording is silently lost")

    // Interleaved stereo downmix, which is what the process tap delivers.
    let sink2 = try SampleSink(directory: dir.path, name: "stereo")
    sink2.start()
    let stereo: [Float] = [1.0, 0.0, 1.0, 0.0, 0.6, 0.2]
    stereo.withUnsafeBufferPointer { sink2.append($0.baseAddress!, count: 3, stride: 2, channels: 2) }
    try sink2.finish()
    let d = try Data(contentsOf: sink2.url)
    let got = d.withUnsafeBytes { Array(UnsafeBufferPointer(start: $0.bindMemory(to: Float.self).baseAddress!, count: 3)) }
    check("a stereo pair is averaged, not summed (\(got))",
          abs(got[0] - 0.5) < 1e-6 && abs(got[2] - 0.4) < 1e-6,
          breaksIf: "channels are summed, so anything centred in the mix clips")

    // `finish()` JOINS the flush thread rather than outwaiting it. These two cases
    // exist because a join has failure modes a sleep does not: it can wait on a thread
    // that was never started, and it can wait a second time on one that has already
    // gone. Both hang forever if the handshake is wrong, and a hang in a CI runner
    // reads as an infrastructure problem rather than as this defect.
    //
    // HONEST LIMIT: neither of these reproduces the race the join was added to close.
    // That needed a write slow enough to outlast the old 250 ms sleep, which at the
    // 38 KB production chunk size does not happen on a local disk. What is covered
    // here is the new code, not the old bug.
    let sink3 = try SampleSink(directory: dir.path, name: "never-started")
    let lone: [Float] = [0.25, 0.25]
    lone.withUnsafeBufferPointer { sink3.append($0.baseAddress!, count: 2) }
    try sink3.finish()
    let size3 = try FileManager.default.attributesOfItem(atPath: sink3.url.path)[.size] as! Int
    check("finish() on a sink that was never started still writes its staging (\(size3) bytes)",
          size3 == 2 * MemoryLayout<Float>.size,
          breaksIf: "finish() waits unconditionally on a flush thread that does not exist, and the call never returns")

    try sink3.finish()
    check("finish() is idempotent and the second call does not hang",
          true,
          breaksIf: "the flusher handshake is consumed once, so a second finish() blocks forever")
}

// ---------------------------------------------------------------- 5. the encoder
// The PCM16 encoder in `WavWriter.append` is the last thing that touches every sample
// of every recording, and both of its invariants were unfalsifiable until now.
//
// The equivalence cases in section 1 could not see either one. They compare the
// streaming path against the one-shot path with a tolerance of 2 LSB, and BOTH paths
// would carry the same defect, so the comparison stays green while every sample is
// wrong in the same direction. A tolerance that forgives a systematic bias is not a
// tolerance, it is a blind spot.
print("\n5. the PCM16 encoder, against arithmetic rather than against itself")
do {
    // ROUNDING, not truncation. Truncation biases every sample toward zero: it is
    // inaudible on one sample, and it is a DC-shifted quieter recording across a
    // meeting. These values are chosen so the two differ — 0.5 LSB apart or more.
    let awkward: [Float] = [0.00002, 0.00005, 0.0001, -0.00002, -0.00005, -0.0001,
                            0.123456, -0.123456, 0.5, -0.5, 0.999, -0.999]
    let rawURL = tmp.appendingPathComponent("encoder.f32")
    try writeRaw(awkward, to: rawURL)
    let out = tmp.appendingPathComponent("encoder.wav").path
    // 16 kHz in, 16 kHz out: the passthrough path, so the converter cannot smear the
    // values and the only arithmetic left between input and file is the encoder.
    _ = try Audio.streamResampleToWav(rawURL: rawURL, nativeRate: 16_000, leadFrames: 0, to: out)
    let got = try readPCM16(out)
    let wantRounded = awkward.map { Int16((max(-1, min(1, $0)) * 32767).rounded()) }
    let wantTruncated = awkward.map { Int16(max(-1, min(1, $0)) * 32767) }
    check("every sample is the ROUNDED PCM16 value, exactly",
          got == wantRounded,
          breaksIf: "the encoder truncates instead of rounding, biasing every sample of every recording toward zero")
    // A positive control on the fixture itself. If these two agreed, the case above
    // would pass under either arithmetic and would be testing nothing.
    check("the fixture actually distinguishes rounding from truncation",
          wantRounded != wantTruncated,
          breaksIf: "the sample values no longer differ under the two arithmetics, so the case above cannot fail")

    // THE CLAMP. Section 1's fixture peaks at 0.82, so nothing there ever reaches the
    // clamp and deleting it changes nothing those cases can see. A mixed or gained
    // signal absolutely does exceed 1.0, and an unclamped Int16 conversion either traps
    // or wraps a loud passage to full-scale noise of the opposite sign.
    let hot: [Float] = [1.5, -1.5, 2.0, -2.0, 1.0, -1.0, 0.0]
    let hotURL = tmp.appendingPathComponent("hot.f32")
    try writeRaw(hot, to: hotURL)
    let hotOut = tmp.appendingPathComponent("hot.wav").path
    _ = try Audio.streamResampleToWav(rawURL: hotURL, nativeRate: 16_000, leadFrames: 0, to: hotOut)
    let hotGot = try readPCM16(hotOut)
    check("over-unity samples clamp to full scale instead of wrapping (\(hotGot.prefix(4)))",
          hotGot == [32767, -32767, 32767, -32767, 32767, -32767, 0],
          breaksIf: "the clamp is removed, so a loud passage wraps to full-scale noise of the opposite sign")
}

// ---------------------------------------------------------------- 6. public API
// `Audio.padLead` and `Audio.finalizeTrack` are exported from a library product and
// have no caller anywhere in this package. Exported API with no caller and no check is
// how a library ships a function nobody has ever run. These are the cases that make
// them exercised rather than merely compiled.
print("\n6. exported helpers that the CLI itself does not call")
do {
    let rate = 48_000.0
    let body = signal(frames: 4_800, rate: rate)          // 0.1 s
    // padLead counts its silence at the NATIVE rate. Counting at the target rate is a
    // 3x alignment error at 48 kHz, which shifts every timestamp in a transcript.
    let padded = Audio.padLead(body, leadNs: 250_000_000, nativeRate: rate)   // 0.25 s
    check("padLead prepends lead frames counted at the NATIVE rate (\(padded.count - body.count))",
          padded.count - body.count == 12_000,
          breaksIf: "the lead is counted at the target rate, so alignment is out by the resample ratio")
    check("padLead's padding is silence and the body survives it",
          padded.prefix(12_000).allSatisfy { $0 == 0 } && Array(padded.suffix(body.count)) == body,
          breaksIf: "the pad is appended rather than prepended, or it overwrites the head of the take")
    check("a zero lead leaves the samples untouched",
          Audio.padLead(body, leadNs: 0, nativeRate: rate) == body,
          breaksIf: "a zero lead still allocates a pad, shifting a single-track recording")

    // finalizeTrack is the one-shot path section 1 compares against, called here through
    // its public face so the exported entry point is exercised, not just its internals.
    let rawURL = tmp.appendingPathComponent("oneshot.f32")
    try writeRaw(body, to: rawURL)
    let out = tmp.appendingPathComponent("oneshot.wav").path
    let dur = try Audio.finalizeTrack(body, firstBufferNs: 0, sharedStartNs: 0,
                                      nativeRate: rate, to: out)
    let oneShotFrames = try readPCM16(out).count
    check("finalizeTrack reports the duration it wrote (\(String(format: "%.4f", dur))s)",
          abs(dur - 0.1) < 0.001 && oneShotFrames == Int(dur * 16_000),
          breaksIf: "the reported duration is computed from the input rather than from the frames written")
}

print("\n" + (failures == 0 ? "audio-pipeline-check OK" : "\(failures) check(s) FAILED"))
exit(failures == 0 ? 0 : 1)
