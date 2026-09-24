// Who is working on this take. Both entry points take it before any upload: the capture
// CLI's own transcriber run and the queue worker. Without it, a worker woken by the
// manifest write and a synchronous run would upload the same audio twice.
//
// `.work/<id>/.claim` is created with O_EXCL and holds the holder's PID and a random
// token. The holder refreshes its mtime every 30 s. A claim whose mtime is more than
// 30 minutes old is stale and may be taken over.
//
// Sleep and SIGSTOP freeze the heartbeat, so a frozen holder can lose its claim to a new
// one. It finds out on waking: before every upload and every write it re-reads the file,
// and if the token is not its own it writes nothing and exits 6.
import Foundation

public final class TakeClaim {
    public static let fileName = ".claim"
    public static let heartbeatSeconds: Double = 30
    public static let staleSeconds: Double = 30 * 60

    public let path: String
    public let token: String
    private var timer: DispatchSourceTimer?

    public enum Acquire {
        case held(TakeClaim)
        case heldElsewhere(String)
        case failed(String)
    }

    init(path: String, token: String) { self.path = path; self.token = token }

    static func create(_ path: String, token: String) -> Int32 {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return errno }
        let line = "\(getpid()) \(token)\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        return 0
    }

    public static func acquire(takeDir: String, stale: Double = staleSeconds, log: (String) -> Void) -> Acquire {
        let path = takeDir + "/" + fileName
        let token = UUID().uuidString
        var e = create(path, token: token)
        if e == EEXIST {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
            let age = Date().timeIntervalSince(mtime)
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: " ").first.map(String.init) ?? "?"
            guard age > stale else {
                return .heldElsewhere("claimed by pid \(holder), heartbeat \(Int(age)) s ago")
            }
            log("[transcribe] taking over a stale claim (pid \(holder), heartbeat \(Int(age)) s ago)")
            unlink(path)
            e = create(path, token: token)
            if e == EEXIST { return .heldElsewhere("another runner took the stale claim first") }
        }
        guard e == 0 else { return .failed("cannot create \(path): \(String(cString: strerror(e)))") }
        let c = TakeClaim(path: path, token: token)
        // Two takers of one stale claim can both believe they won. The re-read settles it.
        guard c.stillMine() else { return .heldElsewhere("lost the claim to another runner at takeover") }
        return .held(c)
    }

    /// Re-read from disk. The only answer that counts.
    public func stillMine() -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return s.split(separator: " ").dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } == token
    }

    public func startHeartbeat(every seconds: Double = heartbeatSeconds) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler { [weak self] in
            guard let self, self.stillMine() else { return }
            utimes(self.path, nil)
        }
        t.resume()
        timer = t
    }

    /// Removes the claim only if it is still ours.
    public func release() {
        timer?.cancel(); timer = nil
        if stillMine() { unlink(path) }
    }
}
