// Who is working on this take. Both entry points take it before any upload: the capture
// CLI's own transcriber run and the queue worker. Without it, a worker woken by the
// manifest write and a synchronous run would upload the same audio twice.
//
// `.work/<id>/.claim` is created with O_EXCL and holds the holder's PID and a random
// token. The holder refreshes its mtime every 30 s. A claim is stale, and may be taken
// over, when its mtime is more than 30 minutes old or when its holder PID no longer exists
// (a bootout or a crash). Takeover is serialised by an flock() on `<claim>.takeover` and
// finishes with a rename, so exactly one taker comes out holding the claim.
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
        acquire(path: takeDir + "/" + fileName, stale: stale, log: log)
    }

    /// Is the process that wrote this claim gone? Only ESRCH counts: EPERM means it exists.
    static func holderIsDead(_ content: String) -> Bool {
        guard let pid = content.split(separator: " ").first.flatMap({ Int32($0) }), pid > 0 else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    /// The same protocol on any path. The queue worker uses it for its drain lock.
    /// `beforeReplace` is a test seam: it runs at the moment this taker is about to replace
    /// a stale claim, so a check can put a second taker exactly there.
    public static func acquire(path: String, stale: Double = staleSeconds, log: (String) -> Void,
                               beforeReplace: (() -> Void)? = nil,
                               beforeTakingLock: (() -> Void)? = nil) -> Acquire {
        let token = UUID().uuidString
        var e = create(path, token: token)
        if e == EEXIST {
            guard let seen = try? String(contentsOfFile: path, encoding: .utf8) else {
                // Released between our create and our read. Try once more.
                e = create(path, token: token)
                if e == EEXIST { return .heldElsewhere("another runner claimed it first") }
                return finish(path: path, token: token, e: e)
            }
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? Date()
            let age = Date().timeIntervalSince(mtime)
            let holder = seen.split(separator: " ").first.map(String.init) ?? "?"
            let dead = holderIsDead(seen)
            guard age > stale || dead else {
                return .heldElsewhere("claimed by pid \(holder), heartbeat \(Int(age)) s ago")
            }
            // One taker at a time. Without this, stat-unlink-create lets two takers of one
            // stale claim both come out holding it. The takeover lock is an flock() on
            // <claim>.takeover: only the process holding the open file holds it, the kernel
            // drops it when that process dies (so there is no stale lock to recover, and no
            // unlink-then-create to race), and closing our file cannot release anyone else's.
            // O_CLOEXEC: a child spawned while the lock is held must not inherit the descriptor,
            // or the flock outlives this takeover. The file is deliberately never unlinked:
            // unlinking a file others may flock breaks the exclusion (a holder keeps a lock on
            // the unlinked inode while a newcomer creates and locks a fresh file). It lives in
            // the take folder, which goes with the take, or as one empty file beside drain.lock.
            beforeTakingLock?()
            let lockFD = open(path + ".takeover", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard lockFD >= 0 else { return .failed("cannot open \(path).takeover: \(String(cString: strerror(errno)))") }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                let e = errno
                // Only EWOULDBLOCK means someone else holds it. Anything else is a real error.
                if e == EWOULDBLOCK { return .heldElsewhere("another runner is taking over this claim") }
                return .failed("cannot lock \(path).takeover: \(String(cString: strerror(e)))")
            }
            // Still the claim we judged stale? Someone may have finished a takeover already.
            guard (try? String(contentsOfFile: path, encoding: .utf8)) == seen else {
                return .heldElsewhere("the claim changed while this runner was taking it over")
            }
            log("[transcribe] taking over a \(dead ? "dead holder's" : "stale") claim (pid \(holder), heartbeat \(Int(age)) s ago)")
            beforeReplace?()
            let tmp = path + ".new-\(getpid())"
            unlink(tmp)
            e = create(tmp, token: token)
            if e == 0, rename(tmp, path) != 0 { e = errno; unlink(tmp) }
        }
        return finish(path: path, token: token, e: e)
    }

    static func finish(path: String, token: String, e: Int32) -> Acquire {
        guard e == 0 else { return .failed("cannot create \(path): \(String(cString: strerror(e)))") }
        let c = TakeClaim(path: path, token: token)
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

/// Tombstones of takes being deleted, by name prefix. Never a take.
public let tombstonePrefix = ".deleting-"

public enum TakeRemoval: Equatable {
    case removed
    case alreadyGone
    case heldElsewhere(String)
    /// We held the claim and still could not remove it (for example a read-only folder).
    case failed(String)
}

/// Removes a take's folder only while holding its claim, so no deleter can pull a take out
/// from under a runner that is still working on it. A folder already gone is success.
/// `beforeRecursiveDelete` is a test seam: it runs just before the non-atomic recursive delete.
public func removeTakeHoldingClaim(_ takeDir: String, log: (String) -> Void = { _ in },
                                   beforeRecursiveDelete: (() -> Void)? = nil) -> TakeRemoval {
    guard FileManager.default.fileExists(atPath: takeDir) else { return .alreadyGone }
    switch TakeClaim.acquire(takeDir: takeDir, log: log) {
    case .held(let claim):
        // Out of the queue in ONE step, while the claim is held: a rename to a tombstone.
        // A recursive delete in place removes .claim before the folder, and another runner
        // could claim the half-deleted folder in that gap. The tombstone's dot-name keeps
        // every scan off it, and the next drain clears one a crash left behind.
        let tomb = ((takeDir as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("\(tombstonePrefix)\((takeDir as NSString).lastPathComponent)-\(claim.token)")
        guard rename(takeDir, tomb) == 0 else {
            let e = errno                       // read now: release() may overwrite it
            claim.release()
            return .failed("could not move it out of the queue: \(String(cString: strerror(e)))")
        }
        beforeRecursiveDelete?()
        try? FileManager.default.removeItem(atPath: tomb)
        return .removed
    case .heldElsewhere(let why):
        return .heldElsewhere(why)
    case .failed(let why):
        return FileManager.default.fileExists(atPath: takeDir) ? .heldElsewhere(why) : .alreadyGone
    }
}
