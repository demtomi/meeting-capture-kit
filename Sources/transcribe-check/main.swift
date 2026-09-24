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

// Line-buffered stdout. Block buffering let a stderr write from the handoff land inside a
// half-flushed "  FAIL  " line, which split the word, and a grep for the named failure
// (the mutation harness's whole test) then missed a real red.
setvbuf(stdout, nil, _IOLBF, 0)

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
              source: String = "mic+system", schema: Int = 2, expectedSpeakers: Int? = nil, keepAudio: Bool? = nil,
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
    if let keepAudio { m["keep_audio"] = keepAudio }
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

    // The positive control. Without it, "never delete anything" passes g2.
    let out2 = freshOutputDir("g2-positive")
    let t2 = makeTake(in: out2)
    let md = OutputNames.transcriptPath(outputDir: out2.path, label: "weekly sync", meetingID: t2.id)
    let raw = OutputNames.rawPath(outputDir: out2.path, label: "weekly sync", meetingID: t2.id)
    let writesProof = stubTranscriber("writes-proof", """
        mkdir -p '\(out2.path)/.raw'
        printf -- '---\\nmeeting_id: \(t2.id)\\n---\\n1  [00:00:00] A: hi\\n' > '\(md)'
        echo '{}' > '\(raw)'
        exit 0
        """)
    let rc2 = runTranscriberHandoff(workDir: t2.workDir.path, manifestPath: t2.manifest.path,
                                    transcriber: writesProof, outputDir: out2.path,
                                    keepAudio: false, foreground: true)
    check("g2 a transcriber that exits 0 with a proof-valid transcript gets its take deleted",
          rc2 == 0 && !fm.fileExists(atPath: t2.workDir.path),
          breaksIf: "the proof gate refuses a valid transcript, so no take is ever cleaned up")

    let out3 = freshOutputDir("g2-keep")
    let t3 = makeTake(in: out3)
    let writesProof3 = stubTranscriber("writes-proof-3", """
        mkdir -p '\(out3.path)/.raw'
        printf -- '---\\nmeeting_id: \(t3.id)\\n---\\n' > '\(OutputNames.transcriptPath(outputDir: out3.path, label: "weekly sync", meetingID: t3.id))'
        echo '{}' > '\(OutputNames.rawPath(outputDir: out3.path, label: "weekly sync", meetingID: t3.id))'
        exit 0
        """)
    _ = runTranscriberHandoff(workDir: t3.workDir.path, manifestPath: t3.manifest.path,
                              transcriber: writesProof3, outputDir: out3.path,
                              keepAudio: true, foreground: true)
    check("g2 keep-audio keeps the take even when the proof passes",
          fm.fileExists(atPath: t3.workDir.appendingPathComponent("mic.wav").path),
          breaksIf: "keep-audio stops being consulted before the delete")
}

// ------------------------------------------------------------------ [manifest] schemas
print("\n[manifest] SCHEMA 1, 2 AND 3")
do {
    func manifestJSON(_ schema: Int, source: String = "mic+system", extra: String = "",
                      micPath: String = "mic.wav") -> Data {
        Data("""
        {"schema": \(schema), "meeting_id": "2026-01-02T03-04-05Z-ab12", "label": "x", "source": "\(source)",
         "started_at": "2026-01-02T04:04:05+01:00", "shared_start_monotonic_ns": 1, "output_dir": "/tmp/x",
         "tracks": {"mic": {"path": "\(micPath)", "host": true, "speaker": "A"}} \(extra)}
        """.utf8)
    }
    let v1 = try? Manifest.decode(manifestJSON(1, source: "mic-multi", extra: #", "expected_speakers": 4"#))
    check("manifest: schema 1 decodes, with mic-multi expected_speakers", v1?.expectedSpeakers == 4 && v1?.schema == 1,
          breaksIf: "schema 1 is dropped, so every take recorded before this change stops transcribing")
    let v2 = try? Manifest.decode(manifestJSON(2, extra: #", "expected_speakers": 1"#))
    check("manifest: schema 2 decodes expected_speakers on mic+system", v2?.expectedSpeakers == 1,
          breaksIf: "expected_speakers is read only for mic-multi")
    let v2none = try? Manifest.decode(manifestJSON(2))
    check("manifest: an absent expected_speakers decodes as unknown", v2none != nil && v2none?.expectedSpeakers == nil,
          breaksIf: "an absent head count becomes a default number")
    var threeRefused = false
    do { _ = try Manifest.decode(manifestJSON(3)) } catch Manifest.LoadError.unsupportedSchema(3) { threeRefused = true } catch {}
    check("manifest: schema 3 is refused", threeRefused,
          breaksIf: "the reader accepts a schema it does not know")
    let climbing = try? Manifest.decode(manifestJSON(2, micPath: "../../elsewhere.wav"))
    check("manifest: a track path that leaves the take dir is refused", climbing == nil,
          breaksIf: "track paths are used without checking they are plain file names")
}

print("\n[g2] A RELATIVE OUTPUT DIR")
do {
    // The capture CLI accepts --output-dir as typed. Relative, it used to be resolved twice:
    // once as the child's cwd and again inside the manifest path handed to the child.
    let base = freshOutputDir("relative")
    let saved = fm.currentDirectoryPath
    fm.changeCurrentDirectoryPath(base.path)
    let t = makeTake(in: base.appendingPathComponent("rel"))
    let seesManifest = stubTranscriber("sees-manifest", "[ -f \"$1\" ] && exit 0\nexit 7")
    let rc = runTranscriberHandoff(workDir: "rel/.work/\(t.id)", manifestPath: "rel/.work/\(t.id)/manifest.json",
                                   transcriber: seesManifest, outputDir: "rel", keepAudio: false, foreground: true)
    fm.changeCurrentDirectoryPath(saved)
    check("g2 a relative output dir still hands the transcriber a manifest path that exists",
          rc == 0,
          breaksIf: "relative paths are resolved against the child's cwd a second time (got exit \(rc))")
}

print("\n[capture-manifest] WHAT THE CAPTURE CLI WRITES")
do {
    func made(_ source: String, speakers: Int? = nil) -> [String: Any] {
        CaptureManifest.make(meetingID: "2026-01-02T03-04-05Z-ab12", label: "x", source: source,
                             startedAt: "2026-01-02T04:04:05+01:00", sharedStartNs: 1, host: "A",
                             hasSystemTrack: source == "mic+system", outputDir: "/tmp/x",
                             languageHint: nil, expectedSpeakers: speakers)
    }
    func schema(_ m: [String: Any]) -> Int? { m["schema"] as? Int }
    check("capture-manifest: a take with no schema-2 field is written as schema 1",
          schema(made("mic+system")) == 1 && schema(made("mic")) == 1,
          breaksIf: "every manifest is stamped schema 2, so every schema-1 reader refuses takes it could read")
    check("capture-manifest: mic-multi with a head count is still schema 1, as schema 1 already had it",
          schema(made("mic-multi", speakers: 4)) == 1 && made("mic-multi", speakers: 4)["expected_speakers"] as? Int == 4,
          breaksIf: "a field schema 1 already carried bumps the schema")
    check("capture-manifest: expected_speakers on mic+system is written, as schema 2",
          schema(made("mic+system", speakers: 1)) == 2 && made("mic+system", speakers: 1)["expected_speakers"] as? Int == 1,
          breaksIf: "the remote head count is dropped, or written under a schema that does not define it")
    let kept = CaptureManifest.make(meetingID: "2026-01-02T03-04-05Z-ab12", label: "x", source: "mic",
                                    startedAt: "", sharedStartNs: 1, host: "A", hasSystemTrack: false,
                                    outputDir: "/tmp/x", languageHint: nil, expectedSpeakers: nil, keepAudio: true)
    check("capture-manifest: --keep-audio is written into the take as keep_audio, as schema 2",
          kept["keep_audio"] as? Bool == true && schema(kept) == 2 && made("mic")["keep_audio"] == nil,
          breaksIf: "the keep decision stays in the capture process, and the worker deletes a take the user asked to keep")
    let decoded = try? Manifest.decode(try! JSONSerialization.data(withJSONObject: made("mic+system", speakers: 1)))
    check("capture-manifest: what the capture CLI writes, the transcriber reads",
          decoded?.expectedSpeakers == 1 && decoded?.schema == 2,
          breaksIf: "the writer and the reader drift apart")
}

// ------------------------------------------------------------------ [proof] the rule itself
print("\n[proof] THE SHARED PROOF FUNCTION")
do {
    let out = freshOutputDir("proof")
    let id = "2026-01-02T03-04-05Z-cd34"
    let label = "a/b ../c"
    let md = OutputNames.transcriptPath(outputDir: out.path, label: label, meetingID: id)
    let raw = OutputNames.rawPath(outputDir: out.path, label: label, meetingID: id)
    try! fm.createDirectory(atPath: out.path + "/.raw", withIntermediateDirectories: true)
    func proof() -> ProofFailure? { proveTranscript(outputDir: out.path, label: label, meetingID: id) }

    check("proof: a missing transcript fails", proof() == .missingTranscript,
          breaksIf: "the proof stops checking that the transcript exists")
    try! Data().write(to: URL(fileURLWithPath: md))
    check("proof: an empty transcript fails", proof() == .emptyTranscript,
          breaksIf: "the proof accepts a zero-byte transcript, which is what a crash mid-write leaves")
    try! "no frontmatter here\n1  [00:00:00] A: hi\n".write(toFile: md, atomically: true, encoding: .utf8)
    check("proof: a transcript without frontmatter fails", proof() == .badFrontmatter,
          breaksIf: "the proof stops parsing the frontmatter")
    try! "---\nmeeting_id: 2026-01-02T03-04-05Z-ffff\n---\n".write(toFile: md, atomically: true, encoding: .utf8)
    check("proof: a transcript naming another meeting fails",
          proof() == .wrongMeetingID("2026-01-02T03-04-05Z-ffff"),
          breaksIf: "the proof stops comparing meeting_id")
    try! "---\ntitle: \"x\"\nmeeting_id: \"\(id)\"\nparticipants:\n  - \"A (host, mic)\"\n---\n".write(toFile: md, atomically: true, encoding: .utf8)
    check("proof: a valid transcript without its raw file fails", proof() == .missingRaw,
          breaksIf: "the proof stops checking .raw/")
    try! "{}".write(toFile: raw, atomically: true, encoding: .utf8)
    check("proof: a valid transcript plus its raw file passes", proof() == nil,
          breaksIf: "the proof refuses a complete take")
    check("proof: the slug cannot climb out of the output dir",
          (md as NSString).deletingLastPathComponent == out.path && !OutputNames.slug(label).contains("/")
            && !OutputNames.slug("..").hasPrefix("."),
          breaksIf: "the slug keeps a path separator or a leading dot")
}

// ------------------------------------------------------------------ [r] renderer
print("\n[r] THE RENDERER")
do {
    // Resolved relative to the package, not the cwd. A missing fixture FAILS the run.
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/scribe")
    guard let micData = fm.contents(atPath: fixtures.appendingPathComponent("mic.json").path),
          let sysData = fm.contents(atPath: fixtures.appendingPathComponent("system-diarized.json").path),
          let micR = ScribeResult.parse(micData), let sysR = ScribeResult.parse(sysData) else {
        missing("Fixtures/scribe/mic.json or system-diarized.json")
    }
    func manifest(source: String = "mic+system", label: String = "weekly sync", host: String = "Alex Host") -> Manifest {
        var tracks: [String: Manifest.Track] = ["mic": .init(path: "mic.wav", host: true, speaker: host)]
        if source == "mic+system" { tracks["system"] = .init(path: "system.wav", host: false, speaker: nil) }
        return Manifest(schema: 2, meetingID: "2026-01-02T03-04-05Z-ab12", label: label, source: source,
                        startedAt: "2026-01-02T04:04:05+01:00", tracks: tracks, languageHint: nil, expectedSpeakers: nil)
    }
    let full = RenderInput(manifest: manifest(), results: ["mic": micR, "system": sysR],
                           diarized: ["mic": false, "system": true], silentTracks: [], durationSeconds: 3710)
    let text = Renderer.render(full)
    let body = text.components(separatedBy: "\n---\n").last!.split(separator: "\n").map(String.init)
    let expected = [
        "1  [00:00:00] Alex Host: good morning",
        "2  [00:00:00] Speaker 1: hi all",
        "3  [00:00:01] Speaker 2: hey",
        "4  [00:00:05] Alex Host: sounds fine",
        "5  [00:00:08] Alex Host: again",
        "6  [01:01:40] Speaker 1: great",
    ]
    check("r line format: <n>, two spaces, [HH:MM:SS], speaker, colon, text",
          body == expected,
          breaksIf: "the body line shape changes (got \(body))")
    check("r interleave: both tracks merge by start time, a long pause splits a turn",
          body.count == 6 && body[1].contains("Speaker 1") && body[4].hasSuffix("again"),
          breaksIf: "tracks are concatenated instead of merged, or the 1.2 s turn gap is not applied")
    check("r only spoken words: no audio events, no spacing tokens, no Markdown bold or list dot",
          !text.contains("laughs") && !text.contains("**") && !body.contains { $0.hasPrefix("1. ") },
          breaksIf: "non-word entries reach the text, or the private bullet format comes back")
    let fmKeys = text.components(separatedBy: "\n---\n")[0].split(separator: "\n")
        .filter { !$0.hasPrefix(" ") && $0 != "---" }.map { String($0.split(separator: ":")[0]) }
    check("r frontmatter keys, in order",
          fmKeys == ["schema", "title", "date", "start", "duration", "language", "participants", "source",
                     "diarization", "transcription", "meeting_id"],
          breaksIf: "a frontmatter key is added, dropped or reordered (got \(fmKeys))")
    check("r frontmatter values: date, start with offset, duration, provider language, schema 1",
          text.contains("date: \"2026-01-02\"") && text.contains("start: \"04:04 +01:00\"")
            && text.contains("duration: \"61m50s\"") && text.contains("language: \"eng\"") && text.contains("schema: 1\n"),
          breaksIf: "a frontmatter value is derived from the wrong field")
    check("r the rendered file passes the proof parser",
          parseFrontmatter(text)?["meeting_id"] == "2026-01-02T03-04-05Z-ab12",
          breaksIf: "the renderer and the proof disagree on the frontmatter shape, so no take is ever deleted")

    let solo = RenderInput(manifest: manifest(), results: ["mic": micR, "system": sysR],
                           diarized: ["mic": false, "system": false], silentTracks: [], durationSeconds: 10)
    let micOnly = RenderInput(manifest: manifest(source: "mic"), results: ["mic": micR],
                              diarized: ["mic": false], silentTracks: [], durationSeconds: 10)
    check("r diarization enum: all three values",
          text.contains("diarization: \"elevenlabs, 3 speakers\"")
            && Renderer.render(solo).contains("diarization: \"none (single remote track)\"")
            && Renderer.render(micOnly).contains("diarization: \"none (in-person single track)\""),
          breaksIf: "the diarization value drifts from the three locked strings")
    check("r an undiarized remote track is one speaker",
          !Renderer.render(solo).contains("Speaker 2"),
          breaksIf: "speaker ids are honoured on a track that was not diarized")

    let silent = RenderInput(manifest: manifest(), results: ["mic": micR], diarized: ["mic": false],
                             silentTracks: ["system"], durationSeconds: 10)
    check("r silent_tracks is written when a track was skipped, and only then",
          Renderer.render(silent).contains("silent_tracks:\n  - \"system\"\n") && !text.contains("silent_tracks"),
          breaksIf: "a one-sided transcript reads as a complete take")

    let hostile = RenderInput(manifest: manifest(label: "../../etc/x \"quoted\"", host: "Eve: Admin\nX"),
                              results: ["mic": micR], diarized: ["mic": false], silentTracks: [], durationSeconds: 1)
    let ht = Renderer.render(hostile)
    check("r a hostile label and host name cannot break the file shape",
          parseFrontmatter(ht)?["meeting_id"] == "2026-01-02T03-04-05Z-ab12" && ht.contains("] Eve Admin X: good morning"),
          breaksIf: "a quote, newline or colon in a name leaks into YAML or the speaker split")
    let outDir = "/tmp/out"
    let escapes = ["../../etc/passwd", "a/b", "..", "/abs", ".hidden"].allSatisfy { l in
        let p = OutputNames.transcriptPath(outputDir: outDir, label: l, meetingID: "id")
        return (p as NSString).deletingLastPathComponent == outDir && !((p as NSString).lastPathComponent.hasPrefix("."))
    }
    check("r slug: a / or .. in a label cannot leave the output dir or hide the file", escapes,
          breaksIf: "the slug keeps a separator or a leading dot")

    let many = (0..<300).map { i in ScribeWord(text: "w", start: Double(i), end: Double(i) + 0.5, speakerID: i == 150 ? "speaker_9" : "speaker_0") }
    let phantom = RenderInput(manifest: manifest(), results: ["system": ScribeResult(words: many, languageCode: "eng", audioDurationSecs: 300)],
                              diarized: ["system": true], silentTracks: [], durationSeconds: 300)
    check("r a speaker with under 0.5% of the words is reported as a likely phantom",
          Renderer.phantomSpeakers(phantom).map(\.label) == ["Speaker 2"],
          breaksIf: "the phantom-speaker warning is dropped")
}

// ================================================================== WORKER AND TRANSCRIBER
// Everything below runs the REAL `meeting-transcribe` binary as a child process, pointed at
// the loopback stub. It is found next to this check, so `swift build` must have built it.
let transcribeBin = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().appendingPathComponent("meeting-transcribe").path
guard fm.isExecutableFile(atPath: transcribeBin) else {
    missing("meeting-transcribe is not built next to this check (\(transcribeBin)). Run `swift build` first")
}

/// A synthetic speech-to-text response. No real speech: fixed words, fixed times.
func scribeJSON(track: String, diarize: Bool) -> String {
    let words: [(String, Double, Double, String)] = track == "mic"
        ? [("hello", 0.10, 0.40, "speaker_0"), ("there", 0.50, 0.80, "speaker_0")]
        : diarize ? [("yes", 0.20, 0.45, "speaker_0"), ("okay", 0.90, 1.10, "speaker_1")]
                  : [("yes", 0.20, 0.45, "speaker_0"), ("okay", 0.90, 1.10, "speaker_0")]
    var items: [String] = []
    for (i, w) in words.enumerated() {
        if i > 0 { items.append(#"{"text":" ","start":\#(w.1),"end":\#(w.1),"type":"spacing","speaker_id":"\#(w.3)"}"#) }
        items.append(#"{"text":"\#(w.0)","start":\#(w.1),"end":\#(w.2),"type":"word","speaker_id":"\#(w.3)"}"#)
    }
    return #"{"language_code":"eng","language_probability":0.99,"text":"x","audio_duration_secs":1.0,"words":[\#(items.joined(separator: ","))]}"#
}
stub.defaultResponse = { req in
    StubResponse(status: 200, body: scribeJSON(track: req.track ?? "mic", diarize: req.fields["diarize"] == "true"))
}

// No real key may reach any child. The children get a built environment, never this one.
unsetenv("ELEVENLABS_API_KEY")

enum ConsentFixture { case valid, none, mismatch }
func freshHome(_ name: String, consent: ConsentFixture = .valid) -> URL {
    let h = freshOutputDir("home-" + name)
    let path = h.path + "/.config/meeting-capture/consent"
    switch consent {
    case .valid: try! Consent.write(Consent.currentRecord(), to: path)
    case .mismatch:
        var r = Consent.currentRecord(); r.disclosure_sha256 = String(repeating: "0", count: 64)
        try! Consent.write(r, to: path)
    case .none: break
    }
    return h
}

func toolEnv(home: URL, _ extra: [String: String]) -> [String: String] {
    var e: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "TMPDIR": NSTemporaryDirectory(),
        "MEETING_TRANSCRIBE_API_BASE": stub.baseURL, "MEETING_TRANSCRIBE_TEST_KEY": "test-key",
        "MEETING_TRANSCRIBE_TEST_BACKOFF_SCALE": "0",
    ]
    for (k, v) in extra { e[k] = v.isEmpty ? nil : v }
    return e
}

struct Launched {
    let proc: Process
    let outFile: URL
    func wait() -> (rc: Int32, out: String) {
        proc.waitUntilExit()
        return (proc.terminationStatus, (try? String(contentsOf: outFile, encoding: .utf8)) ?? "")
    }
}
func launch(_ args: [String], home: URL, env: [String: String] = [:], exe: String = transcribeBin) -> Launched {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.environment = toolEnv(home: home, env)
    // stdin is NEVER a terminal here, whoever runs the check, so a TTY-gated path is
    // exercised the way an agent's shell would exercise it.
    p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
    let out = scratchRoot.appendingPathComponent("out-\(UUID().uuidString).log")
    fm.createFile(atPath: out.path, contents: nil)
    let h = try! FileHandle(forWritingTo: out)
    p.standardOutput = h; p.standardError = h
    try! p.run()
    return Launched(proc: p, outFile: out)
}
func run(_ args: [String], home: URL, env: [String: String] = [:]) -> (rc: Int32, out: String) {
    launch(args, home: home, env: env).wait()
}

func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return cond()
}
func exists(_ u: URL, _ name: String = "") -> Bool {
    fm.fileExists(atPath: name.isEmpty ? u.path : u.appendingPathComponent(name).path)
}
func transcriptOf(_ t: Take, label: String = "weekly sync") -> String? {
    try? String(contentsOfFile: OutputNames.transcriptPath(outputDir: t.outputDir.path, label: label, meetingID: t.id),
                encoding: .utf8)
}
func attempts(_ t: Take) -> Int? {
    guard let s = try? String(contentsOf: t.workDir.appendingPathComponent(".upload-attempts"), encoding: .utf8) else { return nil }
    return Int(s.split(separator: " ").first ?? "")
}
/// A stand-in transcriber that logs each call, then runs `body`. `$1` is the manifest.
func loggingTranscriber(_ name: String, _ body: String) -> (path: String, calls: () -> Int) {
    let log = scratchRoot.appendingPathComponent("calls-\(name).log")
    let p = stubTranscriber(name, "echo \"$1\" >> '\(log.path)'\n" + body)
    return (p, { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count })
}
/// Shell that writes a proof-valid transcript for the take whose manifest is `$1`.
let writeProofShell = """
    work="$(dirname "$1")"; id="$(basename "$work")"; out="$(dirname "$(dirname "$work")")"
    mkdir -p "$out/.raw"
    printf -- '---\\nmeeting_id: %s\\n---\\n1  [00:00:00] A: hi\\n' "$id" > "$out/weekly-sync_$id.md"
    echo '{}' > "$out/.raw/weekly-sync_$id.json"
    """

// ------------------------------------------------------------------ [a] exit 0 without proof
print("\n[a] THE WORKER DELETES ONLY ON PROOF")
do {
    let home = freshHome("a")
    let out = freshOutputDir("a-nothing")
    let t = makeTake(in: out)
    let tr = stubTranscriber("a-exit0", "exit 0")
    _ = run(["--drain", out.path, "--transcriber", tr], home: home)
    check("a exit 0 with no transcript leaves .work/<id>/ intact and marks .no-transcript",
          exists(t.workDir, "mic.wav") && exists(t.workDir, ".no-transcript"),
          breaksIf: "the worker deletes a take on the transcriber's exit code alone")

    let out2 = freshOutputDir("a-truncated")
    let t2 = makeTake(in: out2)
    let tr2 = stubTranscriber("a-trunc", """
        work="$(dirname "$1")"; id="$(basename "$work")"; out="$(dirname "$(dirname "$work")")"
        mkdir -p "$out/.raw"; printf -- '---\\nmeeting_id: %s\\n' "$id" > "$out/weekly-sync_$id.md"
        echo '{}' > "$out/.raw/weekly-sync_$id.json"; exit 0
        """)
    _ = run(["--drain", out2.path, "--transcriber", tr2], home: home)
    check("a exit 0 with a truncated transcript leaves .work/<id>/ intact",
          exists(t2.workDir, "mic.wav"),
          breaksIf: "the proof accepts a transcript whose frontmatter never closes")

    let out3 = freshOutputDir("a-valid")
    let t3 = makeTake(in: out3)
    let tr3 = stubTranscriber("a-valid", writeProofShell + "\nexit 0")
    _ = run(["--drain", out3.path, "--transcriber", tr3], home: home)
    check("a exit 0 with a proof-valid transcript deletes the take",
          !exists(t3.workDir),
          breaksIf: "the worker never deletes, so audio piles up forever")
}

// ------------------------------------------------------------------ [b] per-track cache
print("\n[b] A RETRY NEVER RE-UPLOADS A TRACK THAT ALREADY SUCCEEDED")
do {
    stub.reset()
    let home = freshHome("b")
    let out = freshOutputDir("b")
    let t = makeTake(in: out)
    stub.enqueue("system", [StubResponse(status: 500, body: #"{"detail":{"status":"internal_error"}}"#)])
    let r1 = run([t.manifest.path], home: home)
    let r2 = run([t.manifest.path], home: home)
    check("b mic 200 then system 500, then a retry, sends zero new mic uploads",
          r1.rc == 1 && r2.rc == 0 && stub.uploads(track: "mic") == 1 && stub.uploads(track: "system") == 2,
          breaksIf: "a track's 200 response is not cached in .work/<id>/ and reused on retry")
    check("b the retry completes the transcript",
          transcriptOf(t) != nil,
          breaksIf: "the cached track is not merged into the transcript on the retry")
}

// ------------------------------------------------------------------ [c] the status table
print("\n[c] EVERY ROW OF THE HTTP STATUS TABLE")
do {
    let rows: [(String, [StubResponse], Int32, Int?)] = [
        ("200", [StubResponse(status: 200, body: scribeJSON(track: "mic", diarize: false))], 0, 1),
        ("401 invalid key", [StubResponse(status: 401, body: #"{"detail":{"status":"invalid_api_key"}}"#)], 5, 1),
        ("402 payment", [StubResponse(status: 402, body: #"{"detail":{"status":"payment_required"}}"#)], 5, 1),
        ("403 plan gate", [StubResponse(status: 403, body: #"{"detail":{"status":"forbidden"}}"#)], 5, 1),
        ("400 quota body", [StubResponse(status: 400, body: #"{"detail":{"status":"quota_exceeded"}}"#)], 5, 1),
        ("400 validation", [StubResponse(status: 400, body: #"{"detail":{"status":"invalid_request"}}"#)], 3, 1),
        ("413 too large", [StubResponse(status: 413, body: "{}")], 3, 1),
        ("422 unprocessable", [StubResponse(status: 422, body: "{}")], 3, 1),
        ("500", [StubResponse(status: 500, body: "{}")], 1, 1),
        ("503", [StubResponse(status: 503, body: "{}")], 1, 1),
        ("429 x4 backs off 3 times then exit 1",
         Array(repeating: StubResponse(status: 429, body: #"{"detail":{"status":"system_busy"}}"#), count: 4), 1, 4),
        ("429 then 200 recovers inside the run",
         [StubResponse(status: 429, body: "{}"), StubResponse(status: 200, body: scribeJSON(track: "mic", diarize: false))], 0, 2),
        ("a response slower than the timeout", [StubResponse(status: 200, body: "{}", delay: 4)], 1, nil),
    ]
    for (i, row) in rows.enumerated() {
        stub.reset()
        let home = freshHome("c\(i)")
        let out = freshOutputDir("c\(i)")
        let t = makeTake(in: out, source: "mic", system: nil)
        stub.enqueue("mic", row.1)
        let r = run([t.manifest.path], home: home, env: ["MEETING_TRANSCRIBE_TEST_TIMEOUT_SECONDS": "1"])
        let uploadsOK = row.3.map { stub.uploads(track: "mic") == $0 } ?? true
        check("c row \(row.0) -> exit \(row.2)", r.rc == row.2 && uploadsOK && exists(t.workDir, "mic.wav"),
              breaksIf: "the status table maps this row to a different exit (got \(r.rc), \(stub.uploads(track: "mic")) uploads)")
    }
}

check("c timeouts: 900 s plus half the audio in total, and 30/60/120 s backoff",
      ScribeClient.resourceTimeout(audioSeconds: 3600) == 2700 && ScribeClient.backoff == [30, 60, 120],
      breaksIf: "the timeouts fall back to a fixed value, so a slow answer about a long take is uploaded and billed again")
// No bytes move while the provider works on an uploaded take, so the idle timeout must
// outlast the whole processing time, not a fixed 300 s that a long take exceeds.
check("c the idle timeout covers server processing: it is never shorter than the total timeout",
      [60.0, 3600, 36_000].allSatisfy { ScribeClient.requestTimeout(audioSeconds: $0) >= ScribeClient.resourceTimeout(audioSeconds: $0) },
      breaksIf: "the idle timeout fires while the provider is still processing, and the take is uploaded and billed again")

print("\n[c] HOW THE WORKER TREATS EACH EXIT")
do {
    let home = freshHome("cw")
    // exit 5: pause, reason, no attempt, next take not touched
    let out = freshOutputDir("cw-5")
    let older = makeTake(in: out, id: "2026-01-02T03-04-05Z-0001")
    Thread.sleep(forTimeInterval: 1.1)
    let newer = makeTake(in: out, id: "2026-01-02T03-04-06Z-0002")
    let five = loggingTranscriber("cw5", "echo 'reason: key rejected' >&2\nexit 5")
    _ = run(["--drain", out.path, "--transcriber", five.path], home: home)
    let pause = OutputLayout(root: out.path).pauseFile
    let reason = (try? String(contentsOfFile: pause, encoding: .utf8)) ?? ""
    check("c drain: exit 5 pauses the drain with the reason and burns no attempt",
          five.calls() == 1 && reason.contains("key rejected") && attempts(older) == nil
            && exists(older.workDir, "mic.wav") && exists(newer.workDir, "mic.wav"),
          breaksIf: "an account-wide stop is counted as a per-take failure, or the drain carries on")
    _ = run(["--drain", out.path, "--transcriber", five.path], home: home)
    check("c drain: a paused drain runs nothing", five.calls() == 1,
          breaksIf: "the pause file is not checked before each item")

    // exit 1: one attempt, then cooldown
    let out1 = freshOutputDir("cw-1")
    let t1 = makeTake(in: out1)
    let one = loggingTranscriber("cw1", "exit 1")
    _ = run(["--drain", out1.path, "--transcriber", one.path], home: home)
    _ = run(["--drain", out1.path, "--transcriber", one.path], home: home)
    check("c drain: exit 1 keeps the take, counts one attempt and cools down",
          one.calls() == 1 && attempts(t1) == 1 && exists(t1.workDir, "mic.wav"),
          breaksIf: "a failed take is retried with no cooldown, burning its attempts in seconds")

    // the cap
    let outCap = freshOutputDir("cw-cap")
    let tCap = makeTake(in: outCap)
    let capT = loggingTranscriber("cwcap", "exit 1")
    _ = run(["--drain", outCap.path, "--transcriber", capT.path], home: home,
            env: ["MEETING_TRANSCRIBE_TEST_COOLDOWN_SECONDS": "0"])
    check("c drain: three failed attempts write .upload-failed and keep the audio",
          capT.calls() == 3 && exists(tCap.workDir, ".upload-failed") && exists(tCap.workDir, "mic.wav"),
          breaksIf: "the attempt cap is not enforced")

    for (code, marker) in [(3, ".refused"), (4, ".silent-capture")] {
        let o = freshOutputDir("cw-\(code)")
        let t = makeTake(in: o)
        let tr = loggingTranscriber("cw\(code)", "exit \(code)")
        _ = run(["--drain", o.path, "--transcriber", tr.path], home: home, env: ["MEETING_TRANSCRIBE_TEST_COOLDOWN_SECONDS": "0"])
        _ = run(["--drain", o.path, "--transcriber", tr.path], home: home, env: ["MEETING_TRANSCRIBE_TEST_COOLDOWN_SECONDS": "0"])
        check("c drain: exit \(code) writes \(marker), keeps the audio and is not retried",
              tr.calls() == 1 && exists(t.workDir, marker) && exists(t.workDir, "mic.wav"),
              breaksIf: "exit \(code) is treated as retryable")
    }

    let o6 = freshOutputDir("cw-6")
    let t6 = makeTake(in: o6)
    let six = loggingTranscriber("cw6", "exit 6")
    let r6 = run(["--drain", o6.path, "--transcriber", six.path], home: home, env: ["MEETING_TRANSCRIBE_TEST_COOLDOWN_SECONDS": "0"])
    check("c drain: exit 6 (held elsewhere) burns no attempt and keeps the take",
          r6.rc == 0 && six.calls() == 1 && attempts(t6) == nil && exists(t6.workDir, "mic.wav"),
          breaksIf: "a take another runner holds is counted as a failure")

    for (name, body) in [("exit 2", "exit 2"), ("a signal death", "kill -SEGV $$")] {
        let o = freshOutputDir("cw-unlisted")
        let t = makeTake(in: o)
        let tr = loggingTranscriber("cw-\(name.count)", body)
        _ = run(["--drain", o.path, "--transcriber", tr.path], home: home)
        check("c drain: an unlisted exit (\(name)) counts as an attempt and keeps the audio",
              attempts(t) == 1 && exists(t.workDir, "mic.wav"),
              breaksIf: "an unlisted exit is ignored or deletes the take")
    }

    let oBlock = freshOutputDir("cw-noblock")
    let bad = makeTake(in: oBlock, id: "2026-01-02T03-04-05Z-0bad")
    Thread.sleep(forTimeInterval: 1.1)
    let good = makeTake(in: oBlock, id: "2026-01-02T03-04-06Z-00ok")
    let mixed = stubTranscriber("cw-mixed", "case \"$1\" in *0bad*) exit 1;; esac\n" + writeProofShell + "\nexit 0")
    _ = run(["--drain", oBlock.path, "--transcriber", mixed], home: home)
    check("c drain: one failing take does not block the next",
          exists(bad.workDir, "mic.wav") && !exists(good.workDir),
          breaksIf: "the drain stops at the first failing take")
}

// ------------------------------------------------------------------ [w] worker extras
print("\n[w] CEILING, STATUS, REQUEUE, RESUME, KEEP-AUDIO")
do {
    stub.reset()
    let home = freshHome("w-ceiling")
    try! WorkerConfig(max_take_seconds: 0.5).save(home.path + "/.config/meeting-capture/config.json")
    let t = makeTake(in: freshOutputDir("w-ceiling"))
    let r = run([t.manifest.path], home: home)
    check("w a take longer than the ceiling exits 3 before any upload",
          r.rc == 3 && stub.uploads.isEmpty && exists(t.workDir, ".refused") && exists(t.workDir, "mic.wav"),
          breaksIf: "the per-take duration ceiling is not checked before upload")
    check("w the default ceiling is 4 hours", WorkerConfig.defaultMaxTakeSeconds == 4 * 3600,
          breaksIf: "the default ceiling moves")

    // A scripted mixed queue.
    let home2 = freshHome("w-status")
    let out = freshOutputDir("w-status")
    let pending = makeTake(in: out, id: "2026-01-02T03-04-01Z-0001")
    let cooling = makeTake(in: out, id: "2026-01-02T03-04-02Z-0002")
    try! "1 \(Int(Date().timeIntervalSince1970))\n".write(to: cooling.workDir.appendingPathComponent(".upload-attempts"), atomically: true, encoding: .utf8)
    let failed = makeTake(in: out, id: "2026-01-02T03-04-03Z-0003")
    try! "HTTP 500: synthetic\n".write(to: failed.workDir.appendingPathComponent(".upload-failed"), atomically: true, encoding: .utf8)
    let claimed = makeTake(in: out, id: "2026-01-02T03-04-04Z-0004")
    try! "12345 sometoken\n".write(to: claimed.workDir.appendingPathComponent(".claim"), atomically: true, encoding: .utf8)
    let silentT = makeTake(in: out, id: "2026-01-02T03-04-05Z-0005")
    try! "every track silent\n".write(to: silentT.workDir.appendingPathComponent(".silent-capture"), atomically: true, encoding: .utf8)
    let s1 = run(["--status", out.path], home: home2).out
    print("        --status on a scripted queue:")
    for l in s1.split(separator: "\n") { print("        | \(l)") }
    check("w --status names pending, cooling down, failed with reason and command, claimed, silent",
          s1.contains("\(pending.id)  pending") && s1.contains("\(cooling.id)  cooling down")
            && s1.contains("\(failed.id)  failed .upload-failed: HTTP 500: synthetic  -> meeting-transcribe --requeue \(failed.id)")
            && s1.contains("\(claimed.id)  claimed") && s1.contains("\(silentT.id)  failed .silent-capture"),
          breaksIf: "--status loses a state or its next command")
    try! fm.createDirectory(atPath: out.path + "/.transcribe-state", withIntermediateDirectories: true)
    try! "no consent\n".write(toFile: out.path + "/.transcribe-state/paused", atomically: true, encoding: .utf8)
    let s2 = run(["--status", out.path], home: home2).out
    check("w --status shows the pause and its reason first",
          s2.hasPrefix("PAUSED: no consent") && s2.contains("--resume"),
          breaksIf: "a paused worker is invisible in --status")
    let rq = run(["--requeue", failed.id, out.path], home: home2)
    let rs = run(["--resume", out.path], home: home2)
    let s3 = run(["--status", out.path], home: home2).out
    check("w --requeue clears the marker and --resume removes the pause",
          rq.rc == 0 && rs.rc == 0 && s3.contains("\(failed.id)  pending") && !s3.contains("PAUSED")
            && !exists(failed.workDir, ".upload-failed"),
          breaksIf: "a failed take or a paused queue has no way back")
    check("w --requeue refuses an id that is not a take",
          run(["--requeue", "../x", out.path], home: home2).rc == 2,
          breaksIf: "--requeue follows a path out of .work")

    // keep-audio: a proven transcript keeps the take, marks it done, and is never uploaded again.
    stub.reset()
    let home3 = freshHome("w-keep")
    let outK = freshOutputDir("w-keep")
    let tk = makeTake(in: outK)
    _ = run(["--drain", outK.path, "--keep-audio"], home: home3)
    _ = run(["--drain", outK.path, "--keep-audio"], home: home3)
    check("w keep-audio: transcript written, audio kept, marked done, not uploaded twice",
          transcriptOf(tk) != nil && exists(tk.workDir, "mic.wav") && exists(tk.workDir, ".transcribed")
            && stub.uploads(track: "mic") == 1,
          breaksIf: "keep-audio stops the delete but not the re-pick, so every drain pays again")
}

print("\n[args] A FLAG'S VALUE IS NEVER THE OUTPUT DIR")
do {
    let home = freshHome("args")
    let out = freshOutputDir("args")
    try! WorkerConfig(output_dir: out.path).save(home.path + "/.config/meeting-capture/config.json")
    let t = makeTake(in: out)
    let tr = loggingTranscriber("args", "exit 1")
    let r = run(["--drain", "--transcriber", tr.path], home: home)
    check("args: --drain --transcriber <path> drains the configured dir, not <path>/.work",
          tr.calls() == 1 && attempts(t) == 1,
          breaksIf: "a valued flag's argument is read as the positional output dir (rc \(r.rc), calls \(tr.calls()))")
    let st = run(["--status", "--transcriber", tr.path], home: home)
    check("args: --status with a valued flag still reports the configured dir",
          st.out.contains(t.id),
          breaksIf: "--status reads a flag's value as its dir")
}

print("\n[keep] THE TAKE CARRIES THE KEEP DECISION")
do {
    stub.reset()
    let home = freshHome("keep-manifest")
    let out = freshOutputDir("keep-manifest")
    let t = makeTake(in: out, keepAudio: true)
    _ = run(["--drain", out.path], home: home)           // the worker was NOT told --keep-audio
    check("keep: a take recorded with --keep-audio keeps its audio through the worker",
          transcriptOf(t) != nil && exists(t.workDir, "mic.wav") && exists(t.workDir, ".transcribed"),
          breaksIf: "the worker learns keep-audio only from its own flags, and deletes a recording the user asked to keep")
    let out2 = freshOutputDir("keep-manifest-handoff")
    let t2 = makeTake(in: out2, keepAudio: true)
    let proofWriter = stubTranscriber("keep-proof", writeProofShell + "\nexit 0")
    _ = runTranscriberHandoff(workDir: t2.workDir.path, manifestPath: t2.manifest.path, transcriber: proofWriter,
                              outputDir: out2.path, keepAudio: false, foreground: true)
    check("keep: the capture CLI's delete honours keep_audio in the manifest too",
          exists(t2.workDir, "mic.wav"),
          breaksIf: "the synchronous deleter ignores the take's own keep decision")
}

print("\n[del] A DELETER HOLDS THE CLAIM, AND A VANISHED TAKE IS SKIPPED")
do {
    let liveClaim = "\(getpid()) someone-elses-token\n"   // this check's PID: alive, fresh mtime
    let home = freshHome("del")

    let out = freshOutputDir("del-handoff")
    let t = makeTake(in: out)
    let proofThenClaimed = stubTranscriber("del-proof-claimed", writeProofShell + "\nprintf '\(liveClaim)' > \"$(dirname \"$1\")/.claim\"\nexit 0")
    _ = runTranscriberHandoff(workDir: t.workDir.path, manifestPath: t.manifest.path, transcriber: proofThenClaimed,
                              outputDir: out.path, keepAudio: false, foreground: true)
    check("del: the capture CLI does not delete a proven take while another live runner holds its claim",
          exists(t.workDir, "mic.wav"),
          breaksIf: "the capture CLI removes .work/<id> under a runner that is still working on it")

    let out2 = freshOutputDir("del-worker")
    let t2 = makeTake(in: out2)
    _ = run(["--drain", out2.path, "--transcriber", proofThenClaimed], home: home)
    check("del: the worker does not delete a proven take while another live runner holds its claim",
          exists(t2.workDir, "mic.wav"),
          breaksIf: "the worker removes .work/<id> under a runner that is still working on it")

    let out3 = freshOutputDir("del-vanished")
    let gone = makeTake(in: out3, id: "2026-01-02T03-04-05Z-0gon")
    let next = makeTake(in: out3, id: "2026-01-02T03-04-06Z-0nxt")
    let vanishes = stubTranscriber("del-vanish", "case \"$1\" in *0gon*) rm -rf \"$(dirname \"$1\")\"; exit 1;; esac\n" + writeProofShell + "\nexit 0")
    let r3 = run(["--drain", out3.path, "--transcriber", vanishes], home: home)
    check("del: a take whose dir vanished mid-drain is skipped and the drain carries on",
          r3.rc == 0 && !exists(gone.workDir) && transcriptOf(next) != nil && !exists(next.workDir),
          breaksIf: "a marker write into a removed take aborts the whole drain (rc \(r3.rc))")
}

// ------------------------------------------------------------------ [d] two runners
print("\n[d] TWO RUNNERS ON ONE TAKE UPLOAD IT ONCE")
do {
    stub.reset()
    let home = freshHome("d")
    let out = freshOutputDir("d")
    let t = makeTake(in: out)
    stub.enqueue("mic", [StubResponse(status: 200, body: scribeJSON(track: "mic", diarize: false), delay: 1.5)])
    let a = launch(["--drain", out.path], home: home)
    let b = launch(["--drain", out.path], home: home)
    let ra = a.wait(), rb = b.wait()
    let codes = [ra.rc, rb.rc].sorted()
    check("d two --drain runs started together upload the take once in total, and the loser exits 6",
          stub.uploads(track: "mic") == 1 && stub.uploads(track: "system") == 1 && codes == [0, 6],
          breaksIf: "the drain lock or the take claim lets both runners upload (codes \(codes), mic uploads \(stub.uploads(track: "mic")))")
    check("d the winner leaves a transcript and removes the take",
          transcriptOf(t) != nil && !exists(t.workDir),
          breaksIf: "the winning runner does not finish the take")

    // The synchronous capture path against a drain already holding the take.
    stub.reset()
    let out2 = freshOutputDir("d-sync")
    let t2 = makeTake(in: out2)
    stub.enqueue("mic", [StubResponse(status: 200, body: scribeJSON(track: "mic", diarize: false), delay: 2)])
    let drain = launch(["--drain", out2.path], home: home)
    let claimed = waitFor(5) { exists(t2.workDir, ".claim") }
    for (k, v) in toolEnv(home: home, [:]) { setenv(k, v, 1) }
    let syncRC = claimed ? runTranscriberHandoff(workDir: t2.workDir.path, manifestPath: t2.manifest.path,
                                                  transcriber: transcribeBin, outputDir: out2.path,
                                                  keepAudio: false, foreground: true) : -1
    let keptDuringDrain = exists(t2.workDir, "mic.wav")
    _ = drain.wait()
    check("d the capture CLI's own transcriber run on a claimed take exits 6 and keeps the audio",
          claimed && syncRC == 6 && keptDuringDrain,
          breaksIf: "the synchronous path does not see the claim, or deletes on a take someone else holds")
    check("d ...and the drain still finishes that take with exactly one upload per track",
          stub.uploads(track: "mic") == 1 && stub.uploads(track: "system") == 1 && transcriptOf(t2) != nil && !exists(t2.workDir),
          breaksIf: "the two runners both upload, or the holder is disturbed")
}

// ------------------------------------------------------------------ [e] diarization choice
print("\n[e] DIARIZATION FOLLOWS THE MANIFEST")
do {
    stub.reset()
    let home = freshHome("e")
    let t = makeTake(in: freshOutputDir("e"), schema: 1)
    _ = run([t.manifest.path], home: home)
    let sys = stub.uploads.first { $0.track == "system" }
    let mic = stub.uploads.first { $0.track == "mic" }
    check("e a manifest with no expected_speakers diarizes the remote track",
          sys?.fields["diarize"] == "true" && mic?.fields["diarize"] == "false",
          breaksIf: "an absent head count is read as one speaker")

    stub.reset()
    let t1 = makeTake(in: freshOutputDir("e1"), expectedSpeakers: 1)
    _ = run([t1.manifest.path], home: home)
    check("e1 one remote speaker is not diarized",
          stub.uploads.first { $0.track == "system" }?.fields["diarize"] == "false",
          breaksIf: "a one-voice remote track is diarized, which can only invent speakers")

    stub.reset()
    let tm = makeTake(in: freshOutputDir("e2"), source: "mic-multi", expectedSpeakers: 3, system: nil)
    _ = run([tm.manifest.path], home: home)
    let m = stub.uploads.first { $0.track == "mic" }
    check("e2 mic-multi diarizes the room mic, pinned to expected_speakers",
          m?.fields["diarize"] == "true" && m?.fields["num_speakers"] == "3",
          breaksIf: "the room mic is sent as one speaker")
}

// ------------------------------------------------------------------ [f] consent
print("\n[f] NO CONSENT, NO UPLOAD")
do {
    for (name, fixture) in [("no consent file", ConsentFixture.none), ("a consent to another disclosure", .mismatch)] {
        stub.reset()
        let home = freshHome("f-\(name.count)", consent: fixture)
        let t = makeTake(in: freshOutputDir("f"))
        let r = run([t.manifest.path], home: home)
        check("f \(name) means no upload (exit 5)",
              r.rc == 5 && stub.uploads.isEmpty && exists(t.workDir, "mic.wav"),
              breaksIf: "the transcriber uploads without a matching consent")
    }
    stub.reset()
    let home = freshHome("f-drain", consent: .none)
    let out = freshOutputDir("f-drain")
    let t = makeTake(in: out)
    _ = run(["--drain", out.path], home: home)
    let pause = (try? String(contentsOfFile: OutputLayout(root: out.path).pauseFile, encoding: .utf8)) ?? ""
    check("f the drain pauses on missing consent, uploads nothing, burns no attempt",
          stub.uploads.isEmpty && pause.contains("consent") && attempts(t) == nil,
          breaksIf: "missing consent is treated as a per-take failure")
}

// ------------------------------------------------------------------ [g3] frozen holder
print("\n[g3] A FROZEN HOLDER RESUMES INTO A LOST CLAIM")
do {
    // A claims, is frozen, and goes stale. B takes the claim over and is held right after
    // claiming, so the claim file carries B's token when A wakes. That is the moment the
    // token exists for: A must see a claim file that is not its own and stop. (If B were
    // allowed to finish first, the claim file would be gone and A would stop for a
    // different reason, which proves nothing about the token.)
    stub.reset()
    let home = freshHome("g3")
    let t = makeTake(in: freshOutputDir("g3"))
    let holdA = scratchRoot.appendingPathComponent("g3-hold-a").path
    let holdB = scratchRoot.appendingPathComponent("g3-hold-b").path
    let timing = ["MEETING_TRANSCRIBE_TEST_STALE_SECONDS": "2", "MEETING_TRANSCRIBE_TEST_HEARTBEAT_SECONDS": "0.5"]
    var envA = timing; envA["MEETING_TRANSCRIBE_TEST_HOLD_AFTER_CLAIM"] = holdA
    var envB = timing; envB["MEETING_TRANSCRIBE_TEST_HOLD_AFTER_CLAIM"] = holdB
    let a = launch([t.manifest.path], home: home, env: envA)
    let claimedA = waitFor(10) { fm.fileExists(atPath: holdA + ".claimed") }
    var ra: (rc: Int32, out: String) = (-1, "")
    var rb: (rc: Int32, out: String) = (-1, "")
    var claimedB = false, uploadsWhileAWoke = -1, transcriptBeforeB = true
    if claimedA {
        kill(a.proc.processIdentifier, SIGSTOP)
        fm.createFile(atPath: holdA + ".go", contents: nil)
        Thread.sleep(forTimeInterval: 3)   // past the 2 s stale age, A's heartbeat frozen
        let b = launch([t.manifest.path], home: home, env: envB)
        claimedB = waitFor(10) { fm.fileExists(atPath: holdB + ".claimed") }
        kill(a.proc.processIdentifier, SIGCONT)
        ra = a.wait()                        // A runs to its end while B still holds the claim
        uploadsWhileAWoke = stub.uploads.count
        transcriptBeforeB = transcriptOf(t) != nil
        fm.createFile(atPath: holdB + ".go", contents: nil)
        rb = b.wait()
    } else {
        a.proc.terminate(); _ = a.wait()
    }
    check("g3 a holder stopped past the stale age loses its claim: it exits 6, uploads nothing, writes nothing",
          claimedA && claimedB && ra.rc == 6 && uploadsWhileAWoke == 0 && !transcriptBeforeB,
          breaksIf: "the resumed holder does not compare its token before uploading (A \(ra.rc), uploads while A ran \(uploadsWhileAWoke))")
    check("g3 ...and the runner that took over finishes with exactly one upload per track",
          rb.rc == 0 && stub.uploads(track: "mic") == 1 && stub.uploads(track: "system") == 1 && transcriptOf(t) != nil,
          breaksIf: "a stale claim cannot be taken over, so a frozen holder blocks the take forever")
}

print("\n[claim] A DEAD HOLDER, AND TWO TAKERS OF ONE STALE CLAIM")
do {
    func deadPID() -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! p.run(); p.waitUntilExit(); return p.processIdentifier
    }
    stub.reset()
    let home = freshHome("claim-dead")
    let t = makeTake(in: freshOutputDir("claim-dead"))
    try! "\(deadPID()) leftover-token\n".write(to: t.workDir.appendingPathComponent(".claim"), atomically: true, encoding: .utf8)
    let r = run([t.manifest.path], home: home)
    check("claim: a fresh claim whose holder PID is dead is taken over at once",
          r.rc == 0 && stub.uploads(track: "mic") == 1 && transcriptOf(t) != nil,
          breaksIf: "a claim left by a killed process (a bootout, a crash) blocks the take for 30 minutes (rc \(r.rc))")

    stub.reset()
    let out = freshOutputDir("claim-dead-drain")
    let td = makeTake(in: out)
    try! fm.createDirectory(atPath: out.path + "/.transcribe-state", withIntermediateDirectories: true)
    try! "\(deadPID()) leftover-token\n".write(toFile: out.path + "/.transcribe-state/drain.lock", atomically: true, encoding: .utf8)
    let rd = run(["--drain", out.path], home: home)
    check("claim: a fresh drain.lock whose holder PID is dead does not block the next drain",
          rd.rc == 0 && transcriptOf(td) != nil && !exists(td.workDir),
          breaksIf: "a drain killed by bootout on reinstall blocks all transcription for 30 minutes (rc \(rd.rc))")

    // Two takers of one stale claim, interleaved exactly: the second arrives while the first
    // is about to replace the claim. Exactly one may come out holding it.
    let dir = freshOutputDir("claim-race")
    let path = dir.path + "/.claim"
    try! "\(getpid()) old-token\n".write(toFile: path, atomically: true, encoding: .utf8)
    utimes(path, [timeval(tv_sec: 1, tv_usec: 0), timeval(tv_sec: 1, tv_usec: 0)])
    var second: TakeClaim.Acquire?
    let first = TakeClaim.acquire(path: path, stale: 60, log: { _ in }, beforeReplace: {
        second = TakeClaim.acquire(path: path, stale: 60, log: { _ in })
    })
    // What acquire RETURNED. Re-reading the token afterwards would only measure the backstop
    // that catches a double holder later, not whether acquire handed the claim out twice.
    func holds(_ a: TakeClaim.Acquire?) -> Bool { if case .held = a { return true } else { return false } }
    check("claim: two takers of one stale claim, interleaved, leave exactly one holder",
          [holds(first), holds(second)].filter { $0 }.count == 1,
          breaksIf: "takeover is stat-unlink-create, so both takers believe they hold the claim (first \(holds(first)), second \(holds(second)))")

    stub.reset()
    let homeP = freshHome("claim-race-proc")
    let tp = makeTake(in: freshOutputDir("claim-race-proc"))
    try! "\(getpid()) old-token\n".write(to: tp.workDir.appendingPathComponent(".claim"), atomically: true, encoding: .utf8)
    utimes(tp.workDir.appendingPathComponent(".claim").path, [timeval(tv_sec: 1, tv_usec: 0), timeval(tv_sec: 1, tv_usec: 0)])
    stub.enqueue("mic", [StubResponse(status: 200, body: scribeJSON(track: "mic", diarize: false), delay: 1)])
    let p1 = launch([tp.manifest.path], home: homeP), p2 = launch([tp.manifest.path], home: homeP)
    let codes = [p1.wait().rc, p2.wait().rc].sorted()
    check("claim: two processes taking over one stale claim upload each track once",
          stub.uploads(track: "mic") == 1 && stub.uploads(track: "system") == 1 && codes == [0, 6],
          breaksIf: "both takers of a stale claim upload (codes \(codes), mic uploads \(stub.uploads(track: "mic")))")
}

// ------------------------------------------------------------------ [h] [i] refusals
print("\n[h] [i] TAKES THAT CAN NEVER SUCCEED")
do {
    stub.reset()
    let home = freshHome("h")
    let t = makeTake(in: freshOutputDir("h"), mic: Data("RIFFjunk".utf8))
    let r = run([t.manifest.path], home: home)
    check("h an unreadable WAV gives exit 3 and .unreadable, uploads nothing, keeps the audio",
          r.rc == 3 && exists(t.workDir, ".unreadable") && exists(t.workDir, "mic.wav") && stub.uploads.isEmpty,
          breaksIf: "an unreadable WAV is treated as non-silent and uploaded, or as silent and skipped")

    stub.reset()
    let t3 = makeTake(in: freshOutputDir("i"), schema: 3)
    let r3 = run([t3.manifest.path], home: home)
    check("i manifest schema 3 gives exit 3 and no upload",
          r3.rc == 3 && stub.uploads.isEmpty,
          breaksIf: "the transcriber reads a manifest schema it does not know")
}

print("\n[silent] EVERY TRACK SILENT")
do {
    stub.reset()
    let home = freshHome("silent")
    let t = makeTake(in: freshOutputDir("silent"), mic: wavData(seconds: 1, amplitude: 0), system: wavData(seconds: 1, amplitude: 0))
    let r = run([t.manifest.path], home: home)
    check("silent: every track digitally silent gives exit 4, no transcript, no upload, audio kept",
          r.rc == 4 && transcriptOf(t) == nil && stub.uploads.isEmpty && exists(t.workDir, "mic.wav"),
          breaksIf: "digital silence is uploaded, or rendered as an empty transcript that reads as a finished take")

    stub.reset()
    let t1 = makeTake(in: freshOutputDir("silent-one"), system: wavData(seconds: 1, amplitude: 0))
    _ = run([t1.manifest.path], home: home)
    check("silent: a silent system track is not uploaded and the mic still is",
          stub.uploads(track: "system") == 0 && stub.uploads(track: "mic") == 1,
          breaksIf: "the peak threshold is not applied per track")
    check("silent: a track just above the threshold is not silent, one just below is",
          !WavPeak.isSilent(6e-4) && WavPeak.isSilent(4e-4) && WavPeak.silenceThreshold == 5e-4,
          breaksIf: "the silence threshold moves off 5e-4 of full scale")
}

// ------------------------------------------------------------------ [j] consent needs a person
print("\n[j] CONSENT CANNOT BE GIVEN FROM A NON-INTERACTIVE SHELL")
do {
    let home = freshHome("j", consent: .none)
    let r = run(["--consent-upload"], home: home)
    check("j --consent-upload with stdin not a TTY exits 2 and writes no file",
          r.rc == 2 && !fm.fileExists(atPath: home.path + "/.config/meeting-capture/consent"),
          breaksIf: "an agent's shell can record consent on the human's behalf")
}

do {
    // The positive control: without it, "always refuse" passes j. `script` gives the
    // child a real pseudo-terminal, against a scratch HOME.
    let home = freshHome("j-tty", consent: .none)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    p.arguments = ["-q", "/dev/null", transcribeBin, "--consent-upload"]
    p.environment = toolEnv(home: home, [:])
    p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    let path = home.path + "/.config/meeting-capture/consent"
    let rec = Consent.read(path)
    check("j with a terminal, --consent-upload records the current disclosure hash, version and cost",
          p.terminationStatus == 0 && rec?.disclosure_sha256 == Consent.disclosureHash && rec?.version == Consent.version
            && rec?.cost_shown.contains("20.19") == true,
          breaksIf: "consent is refused even from a person's terminal, or records the wrong disclosure")
    let rv = run(["--revoke-consent"], home: home)
    check("j --revoke-consent deletes the consent file", rv.rc == 0 && !fm.fileExists(atPath: path),
          breaksIf: "consent cannot be withdrawn")
    check("j the disclosure names the US endpoint, retention, the DPA and the measured cost",
          Consent.disclosureText.contains("US endpoint") && Consent.disclosureText.contains("zero-retention")
            && Consent.disclosureText.contains("elevenlabs.io/dpa") && Consent.disclosureText.contains("20.19"),
          breaksIf: "the disclosure a person consents to loses one of the facts it exists to state")
}

print("\n[k] THE KEY SOURCE")
do {
    let found = stubTranscriber("fake-security", "echo stub-key-from-keychain; exit 0")
    let absent = stubTranscriber("fake-security-absent", "exit 44")
    check("k the key is read by exec'ing security",
          KeySource.resolve(environment: [:], interactive: false, securityPath: found) == .found("stub-key-from-keychain", from: "Keychain item meeting-capture-elevenlabs"),
          breaksIf: "the Keychain read stops going through the security binary")
    check("k ELEVENLABS_API_KEY is ignored when stdin is not a terminal",
          KeySource.resolve(environment: ["ELEVENLABS_API_KEY": "env-key"], interactive: false, securityPath: absent)
            == .missing("no key in the Keychain item meeting-capture-elevenlabs. Add it with: \(KeySource.addCommand)"),
          breaksIf: "an unattended worker picks up a key from its environment")
    check("k ELEVENLABS_API_KEY is the fallback for an interactive run",
          KeySource.resolve(environment: ["ELEVENLABS_API_KEY": "env-key"], interactive: true, securityPath: absent)
            == .found("env-key", from: "ELEVENLABS_API_KEY (interactive run)"),
          breaksIf: "the interactive fallback is dropped")
}

print("\n[install] THE WORKER INSTALL, WITHOUT LAUNCHD")
do {
    let out = freshOutputDir("install-out")
    let noLaunch = ["MEETING_TRANSCRIBE_TEST_NO_LAUNCHCTL": "1"]
    let homeNo = freshHome("install-noconsent", consent: .none)
    let dry = run(["--install-worker", "--output-dir", out.path], home: homeNo, env: noLaunch)
    let wrote = ["Library/LaunchAgents", "Library/Application Support/meeting-capture", ".config/meeting-capture"]
        .filter { fm.fileExists(atPath: homeNo.path + "/" + $0) }
    check("install: without consent it is a dry run that writes nothing and exits 5",
          dry.rc == 5 && wrote.isEmpty && dry.out.contains("DRY RUN") && dry.out.contains("US endpoint"),
          breaksIf: "installing the worker stops requiring a consent a person typed (wrote \(wrote))")

    let home = freshHome("install")
    let bin = home.path + "/Library/Application Support/meeting-capture/bin"
    // Fake an older install, so the rollback link has something to point at.
    try! fm.createDirectory(atPath: bin + "/0000000000000000", withIntermediateDirectories: true)
    try! fm.createSymbolicLink(atPath: bin + "/current", withDestinationPath: bin + "/0000000000000000")
    let ins = run(["--install-worker", "--output-dir", out.path], home: home, env: noLaunch)
    let current = try? fm.destinationOfSymbolicLink(atPath: bin + "/current")
    let previous = try? fm.destinationOfSymbolicLink(atPath: bin + "/previous")
    let sha = LaunchAgent.sha256(ofFile: transcribeBin) ?? "x"
    check("install: the binary is copied to bin/<sha>/, current points at it, previous at the old one",
          ins.rc == 0 && current == bin + "/" + String(sha.prefix(16))
            && LaunchAgent.sha256(ofFile: (current ?? "") + "/meeting-transcribe") == sha
            && previous == bin + "/0000000000000000",
          breaksIf: "the worker runs the clone's build, or an install loses the rollback target")
    let plistPath = home.path + "/Library/LaunchAgents/\(LaunchAgent.label).plist"
    let pl = (fm.contents(atPath: plistPath)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
    let progArgs = pl?["ProgramArguments"] as? [String] ?? []
    check("install: the plist watches .work, runs every 600 s, throttles 30 s, and runs the current link",
          (pl?["WatchPaths"] as? [String]) == [out.path + "/.work"] && pl?["StartInterval"] as? Int == 600
            && pl?["ThrottleInterval"] as? Int == 30 && progArgs.first == bin + "/current/meeting-transcribe"
            && progArgs.dropFirst().first == "--drain",
          breaksIf: "the plist drifts from the spec")
    let plText = String(decoding: fm.contents(atPath: plistPath) ?? Data(), as: UTF8.self)
    check("install: the plist carries no EnvironmentVariables and no key",
          pl?["EnvironmentVariables"] == nil && !plText.contains("test-key") && !plText.contains("ELEVENLABS")
            && !plText.lowercased().contains("api_key"),
          breaksIf: "a key or an environment block can reach the plist")
    check("install: the label has no personal or company identity in it",
          LaunchAgent.label == "io.github.meeting-capture.transcribe-worker",
          breaksIf: "the label changes")
    let un = run(["--uninstall-worker"], home: home, env: noLaunch)
    check("uninstall: removes the plist, keeps consent unless asked, and says so",
          un.rc == 0 && !fm.fileExists(atPath: plistPath) && fm.fileExists(atPath: home.path + "/.config/meeting-capture/consent")
            && un.out.contains("consent kept"),
          breaksIf: "uninstall silently revokes consent, or leaves the agent behind")
    let un2 = run(["--uninstall-worker", "--revoke-consent"], home: home, env: noLaunch)
    check("uninstall --revoke-consent also removes consent, and a second uninstall is harmless",
          un2.rc == 0 && !fm.fileExists(atPath: home.path + "/.config/meeting-capture/consent"),
          breaksIf: "uninstall is not idempotent or ignores --revoke-consent")
}

print("\n[doctor] DOCTOR, WITHOUT LAUNCHD OR A MICROPHONE")
do {
    let out = freshOutputDir("doctor-out")
    let quiet = ["MEETING_TRANSCRIBE_TEST_NO_LAUNCHCTL": "1"]
    let home = freshHome("doctor")
    stub.userResponse = StubResponse(status: 200, body: "{}")
    let ok = run(["--doctor", "--output-dir", out.path, "--no-capture-probe"], home: home, env: quiet)
    check("doctor: with consent, a key and a writable dir, every line is PASS or WARN and it exits 0",
          ok.rc == 0 && !ok.out.contains("FAIL  ") && ok.out.contains("PASS  key accepted: GET /v1/user 200")
            && ok.out.contains("WARN  capture: probe skipped"),
          breaksIf: "doctor fails a healthy setup, or reports a skipped probe as a pass")
    stub.userResponse = StubResponse(status: 401, body: #"{"detail":{"status":"missing_permissions","message":"needs user_read"}}"#)
    let restricted = run(["--doctor", "--output-dir", out.path, "--no-capture-probe"], home: home, env: quiet)
    check("doctor: a speech-to-text-only key refused by /v1/user is accepted-restricted, not a FAIL",
          restricted.rc == 0 && restricted.out.contains("PASS  key accepted-restricted"),
          breaksIf: "a least-privilege key fails doctor")
    stub.userResponse = StubResponse(status: 401, body: #"{"detail":{"status":"invalid_api_key"}}"#)
    let bad = run(["--doctor", "--output-dir", out.path, "--no-capture-probe"], home: home, env: quiet)
    check("doctor: a rejected key is a FAIL line and a non-zero exit",
          bad.rc != 0 && bad.out.contains("FAIL  key accepted: GET /v1/user HTTP 401"),
          breaksIf: "doctor passes a key the provider rejects")
    stub.userResponse = StubResponse(status: 200, body: "{}")
    let nocon = run(["--doctor", "--output-dir", out.path, "--no-capture-probe"], home: freshHome("doctor-nc", consent: .none), env: quiet)
    check("doctor: no consent is a FAIL that names the HUMAN step",
          nocon.rc != 0 && nocon.out.contains("FAIL  consent: none. HUMAN: run in a terminal: meeting-transcribe --consent-upload"),
          breaksIf: "doctor stops checking consent")
}

// ------------------------------------------------------------------ override refusal
print("\n[override] THE TEST BASE URL IS LOOPBACK ONLY")
do {
    stub.reset()
    let home = freshHome("override")
    let t = makeTake(in: freshOutputDir("override"))
    // 0.0.0.0 is NOT on the loopback list, yet a connection to it stays on this machine
    // and lands on the stub. So a missing refusal shows up as a counted upload, and no
    // run of this case can ever send a packet off the machine.
    let r = run([t.manifest.path], home: home, env: ["MEETING_TRANSCRIBE_API_BASE": "http://0.0.0.0:\(stub.port)"])
    check("override: a non-loopback API base is refused with exit 2 and nothing is sent",
          r.rc == 2 && stub.uploads.isEmpty,
          breaksIf: "the base-URL override accepts any host, which would send the key wherever it points")
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
