// Where things live. Every path the transcriber, the worker and the installer touch is
// named here, so a reader can see the whole footprint in one place.
import Foundation

/// The file names a transcript produces, and that the proof rule re-reads.
public enum OutputNames {
    /// A label turned into a file-name-safe slug. Anything outside `[A-Za-z0-9._-]`
    /// becomes `-`, leading dots and dashes go (so `..` and hidden files cannot result),
    /// and the result is capped at 80 characters. An empty result is `meeting`.
    public static func slug(_ label: String) -> String {
        var out = ""
        var lastDash = false
        for u in label.unicodeScalars {
            let ok = u.isASCII && (CharacterSet.alphanumerics.contains(u) || u == "." || u == "_" || u == "-")
            if ok { out.unicodeScalars.append(u); lastDash = (u == "-") }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let strip = CharacterSet(charactersIn: ".-")
        var s = out.trimmingCharacters(in: strip)
        if s.count > 80 { s = String(s.prefix(80)).trimmingCharacters(in: strip) }
        return s.isEmpty ? "meeting" : s
    }

    public static func base(label: String, meetingID: String) -> String { "\(slug(label))_\(meetingID)" }

    public static func transcriptPath(outputDir: String, label: String, meetingID: String) -> String {
        (outputDir as NSString).appendingPathComponent(base(label: label, meetingID: meetingID) + ".md")
    }

    public static func rawPath(outputDir: String, label: String, meetingID: String) -> String {
        (outputDir as NSString).appendingPathComponent(".raw/" + base(label: label, meetingID: meetingID) + ".json")
    }
}

/// The per-user locations. `HOME` is read from the environment first so a check can run
/// the whole thing against a scratch home and leave the real one untouched.
public enum UserPaths {
    public static var home: String {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }
    public static var configDir: String { home + "/.config/meeting-capture" }
    public static var consentFile: String { configDir + "/consent" }
    public static var configFile: String { configDir + "/config.json" }
    public static var supportDir: String { home + "/Library/Application Support/meeting-capture" }
    public static var binDir: String { supportDir + "/bin" }
    public static var logFile: String { home + "/Library/Logs/meeting-capture-transcribe.log" }
    public static var launchAgentsDir: String { home + "/Library/LaunchAgents" }
}

/// Paths inside one output dir.
public struct OutputLayout {
    public let root: String
    public init(root: String) { self.root = root }
    public var workDir: String { root + "/.work" }
    public var rawDir: String { root + "/.raw" }
    /// Worker state lives OUTSIDE `.work`, because the LaunchAgent watches `.work` and a
    /// lock created and removed inside it would re-trigger the agent after every drain.
    public var stateDir: String { root + "/.transcribe-state" }
    public var pauseFile: String { stateDir + "/paused" }
    public var drainLock: String { stateDir + "/drain.lock" }
    public func take(_ id: String) -> String { workDir + "/" + id }
}
