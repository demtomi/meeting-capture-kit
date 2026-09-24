// NAIVE STAGE (build step 5). Deliberately wrong: no claim, no cache, no consent, no
// status table, no proof before delete. It exists so the worker cases are watched to
// fail against something before the real client is written. Replaced in later steps.
import Foundation
import NotetakerCore

let args = CommandLine.arguments
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let base = ProcessInfo.processInfo.environment["MEETING_TRANSCRIBE_API_BASE"] ?? "https://api.elevenlabs.io"
let key = ProcessInfo.processInfo.environment["MEETING_TRANSCRIBE_TEST_KEY"]
    ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""

func upload(_ file: String, diarize: Bool) -> Int {
    var req = URLRequest(url: URL(string: base + "/v1/speech-to-text")!)
    req.httpMethod = "POST"
    req.setValue(key, forHTTPHeaderField: "xi-api-key")
    let b = "naive"
    req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
    var body = Data("--\(b)\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v2\r\n".utf8)
    body += Data("--\(b)\r\nContent-Disposition: form-data; name=\"diarize\"\r\n\r\n\(diarize)\r\n".utf8)
    body += Data("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\((file as NSString).lastPathComponent)\"\r\n\r\n".utf8)
    body += (FileManager.default.contents(atPath: file) ?? Data())
    body += Data("\r\n--\(b)--\r\n".utf8)
    req.httpBody = body
    let done = DispatchSemaphore(value: 0)
    var status = -1
    URLSession.shared.dataTask(with: req) { _, r, _ in
        status = (r as? HTTPURLResponse)?.statusCode ?? -1; done.signal()
    }.resume()
    done.wait()
    return status
}

if let i = args.firstIndex(of: "--drain"), i + 1 < args.count {
    let dir = args[i + 1]
    let transcriber = args.firstIndex(of: "--transcriber").map { args[$0 + 1] } ?? args[0]
    let work = dir + "/.work"
    let ids = ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []).sorted()
    for id in ids {
        let m = work + "/" + id + "/manifest.json"
        guard FileManager.default.fileExists(atPath: m) else { continue }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: transcriber)
        p.arguments = [m]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus == 0 { try? FileManager.default.removeItem(atPath: work + "/" + id) }
        else { exit(1) }
    }
    exit(0)
}

if args.contains("--consent-upload") {
    try? Consent.write(Consent.currentRecord())
    exit(0)
}

guard args.count == 2 else { err("usage: meeting-transcribe <manifest.json>"); exit(2) }
let manifestPath = args[1]
let takeDir = (manifestPath as NSString).deletingLastPathComponent
guard let d = FileManager.default.contents(atPath: manifestPath),
      let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
      let tracks = m["tracks"] as? [String: Any] else { exit(1) }
for name in ["mic", "system"] where tracks[name] != nil {
    let s = upload(takeDir + "/" + name + ".wav", diarize: name == "system")
    if s != 200 { exit(1) }
}
exit(0)
