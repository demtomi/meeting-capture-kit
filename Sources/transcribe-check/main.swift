// Runnable verification for the transcriber, the queue worker and the capture CLI's
// delete rule:  swift build && "$(swift build --show-bin-path)/transcribe-check"
//
// An executable rather than a test target, for the same reason as every other check in
// this package: a machine with only the Command Line Tools has no XCTest.
//
// NO NETWORK. Every HTTP request goes to a loopback stub server started by this process.
// No real key is read: the transcriber only accepts a test key when its API base is a
// loopback host. Each case prints the defect that should make it fail, and
// Scripts/transcribe-mutations.sh plants each of those defects and watches the named case
// go red.
import Foundation
import NotetakerCore

var failures = 0
var checks = 0

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

/// A missing prerequisite means the run tested nothing. That is exit 2, never a pass.
func missing(_ what: String) -> Never {
    print("MISSING: \(what). This run tested nothing.")
    exit(2)
}

// ------------------------------------------------------------------ fixtures
let fm = FileManager.default
let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("transcribe-check-\(getpid())")
try? fm.removeItem(at: scratchRoot)
try! fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)

var dirCounter = 0
/// A fresh output dir per case, so no case can pass on another case's leftovers.
func freshOutputDir(_ name: String) -> URL {
    dirCounter += 1
    let u = scratchRoot.appendingPathComponent("\(dirCounter)-\(name)")
    try! fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A 16 kHz mono PCM16 WAV. `amplitude` 0 is digital silence.
func wavData(seconds: Double, amplitude: Int16) -> Data {
    let frames = Int(seconds * 16_000)
    var pcm = Data(capacity: frames * 2)
    for i in 0..<frames {
        let v: Int16 = amplitude == 0 ? 0 : Int16(Double(amplitude) * sin(Double(i) * 0.05))
        withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
    }
    var h = Data()
    func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { h.append(contentsOf: $0) } }
    func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { h.append(contentsOf: $0) } }
    h.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
    h.append(contentsOf: Array("WAVE".utf8)); h.append(contentsOf: Array("fmt ".utf8))
    u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
    h.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    return h + pcm
}

struct Take {
    let outputDir: URL
    let id: String
    var workDir: URL { outputDir.appendingPathComponent(".work/\(id)") }
    var manifest: URL { workDir.appendingPathComponent("manifest.json") }
}

/// A completed take on disk: WAVs first, manifest last, as the capture CLI writes it.
@discardableResult
func makeTake(in out: URL, id: String = "2026-01-02T03-04-05Z-ab12", label: String = "weekly sync",
              source: String = "mic+system", schema: Int = 2, expectedSpeakers: Int? = nil,
              mic: Data? = wavData(seconds: 1, amplitude: 8000),
              system: Data? = wavData(seconds: 1, amplitude: 8000)) -> Take {
    let t = Take(outputDir: out, id: id)
    try! fm.createDirectory(at: t.workDir, withIntermediateDirectories: true)
    var tracks: [String: Any] = [:]
    if let mic {
        try! mic.write(to: t.workDir.appendingPathComponent("mic.wav"))
        tracks["mic"] = ["path": "mic.wav", "host": true, "speaker": "Alex Host"]
    }
    if let system {
        try! system.write(to: t.workDir.appendingPathComponent("system.wav"))
        tracks["system"] = ["path": "system.wav", "host": false]
    }
    var m: [String: Any] = [
        "schema": schema, "meeting_id": id, "label": label, "source": source,
        "started_at": "2026-01-02T04:04:05+01:00", "shared_start_monotonic_ns": 1,
        "tracks": tracks, "output_dir": out.path,
    ]
    if let expectedSpeakers { m["expected_speakers"] = expectedSpeakers }
    let d = try! JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])
    try! d.write(to: t.manifest)
    return t
}

/// An executable shell script, used as a stand-in transcriber.
func stubTranscriber(_ name: String, _ body: String) -> String {
    let p = scratchRoot.appendingPathComponent("bin-\(name).sh")
    try! ("#!/bin/sh\n" + body + "\n").write(to: p, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
    return p.path
}

// ------------------------------------------------------------------ [0] harness
print("[0] HARNESS")
let stub: StubServer
do {
    stub = try StubServer { _ in StubResponse(status: 200, body: "{}") }
    try stub.start()
} catch {
    missing("the loopback stub server did not start (\(error))")
}
do {
    var req = URLRequest(url: URL(string: stub.baseURL + "/v1/speech-to-text")!)
    req.httpMethod = "POST"
    let boundary = "harness"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"diarize\"\r\n\r\ntrue\r\n".utf8)
    body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"mic.wav\"\r\n\r\nabc\r\n--\(boundary)--\r\n".utf8)
    req.httpBody = body
    let done = DispatchSemaphore(value: 0)
    var status = 0
    URLSession.shared.dataTask(with: req) { _, r, _ in
        status = (r as? HTTPURLResponse)?.statusCode ?? -1; done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 10)
    check("the stub server answers and counts one upload per request",
          status == 200 && stub.uploads(track: "mic") == 1 && stub.uploads.first?.fields["diarize"] == "true",
          breaksIf: "the stub stops parsing multipart, so every upload count below reads zero")
    stub.reset()
}

// ------------------------------------------------------------------ [g2] capture delete
print("\n[g2] CAPTURE CLI DELETE RULE")
do {
    let out = freshOutputDir("g2")
    let t = makeTake(in: out)
    let exitsZero = stubTranscriber("exit0", "exit 0")
    let rc = runTranscriberHandoff(workDir: t.workDir.path, manifestPath: t.manifest.path,
                                   transcriber: exitsZero, outputDir: out.path,
                                   keepAudio: false, foreground: true)
    check("g2 a transcriber that exits 0 and writes nothing leaves .work/<id>/ intact",
          rc == 0 && fm.fileExists(atPath: t.workDir.appendingPathComponent("mic.wav").path),
          breaksIf: "the capture CLI deletes the take on exit 0 without re-reading a transcript")
}

stub.stop()
// Only removed on a finished run. A crash leaves it behind for a look.
try? fm.removeItem(at: scratchRoot)
print("\n=== \(checks - failures)/\(checks) checks passed ===")
if failures > 0 {
    print("FAILED")
    exit(1)
}
print("OK")
