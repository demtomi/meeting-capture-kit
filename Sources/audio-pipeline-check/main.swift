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
    do { _ = try Audio.streamResampleToWav(rawURL: tmp.appendingPathComponent("does-not-exist.f32"),
                                           nativeRate: 48000, leadFrames: 0,
                                           to: tmp.appendingPathComponent("never.wav").path)
    } catch { threw2 = true }
    check("a missing raw capture file throws", threw2,
          breaksIf: "a missing scratch file yields an empty WAV reported as a successful recording")

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
}

print("\n" + (failures == 0 ? "audio-pipeline-check OK" : "\(failures) check(s) FAILED"))
exit(failures == 0 ? 0 : 1)
