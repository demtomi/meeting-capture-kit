// Installing and removing the background worker.
//
// The worker runs a COPY of the binary under ~/Library/Application Support, never the one
// in the clone's .build, so a later `swift build` or `swift package clean` cannot break it.
// Each copy lives in a directory named by its SHA-256. `current` points at the live one,
// `previous` at the one before. Rollback is re-pointing `current`.
import Foundation
import CryptoKit

public enum LaunchAgent {
    public static let label = "io.github.meeting-capture.transcribe-worker"
    public static let startInterval = 600
    public static let throttleInterval = 30

    public static var plistPath: String { UserPaths.launchAgentsDir + "/\(label).plist" }
    public static var currentLink: String { UserPaths.binDir + "/current" }
    public static var previousLink: String { UserPaths.binDir + "/previous" }
    public static var installedBinary: String { currentLink + "/meeting-transcribe" }

    /// The plist. No EnvironmentVariables, so no key can ever be written into it.
    public static func plist(outputDir: String, program: String = installedBinary) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [program, "--drain", outputDir],
            "WatchPaths": [outputDir + "/.work"],
            "StartInterval": startInterval,
            "ThrottleInterval": throttleInterval,
            "StandardOutPath": UserPaths.logFile,
            "StandardErrorPath": UserPaths.logFile,
            "ProcessType": "Background",
        ]
    }

    public static func sha256(ofFile path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try? fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func uid() -> String { String(getuid()) }

    @discardableResult
    static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (127, "\(error)") }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Waits until `isLoaded` says the job is gone. Returns false on timeout.
    public static func waitUntilUnloaded(isLoaded: () -> Bool, timeout: Double = 10, poll: Double = 0.2,
                                         sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        for _ in 0..<max(1, Int((timeout / poll).rounded())) {
            if !isLoaded() { return true }
            sleep(poll)
        }
        return false
    }

    /// `launchctl print` exits 0 while the job is still known to launchd.
    public static func isLoaded(_ label: String) -> Bool {
        launchctl(["print", "gui/\(uid())/\(label)"]).0 == 0
    }

    /// Points `link` at `target` atomically: a temp symlink renamed over the old one.
    static func repoint(_ link: String, to target: String) throws {
        let tmp = link + ".tmp-\(getpid())"
        try? FileManager.default.removeItem(atPath: tmp)
        try FileManager.default.createSymbolicLink(atPath: tmp, withDestinationPath: target)
        guard rename(tmp, link) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    public struct Result {
        public var lines: [String] = []
        public var code: Int32 = ExitCode.ok
    }

    /// Copies `binary`, repoints the links, writes config and plist, and (unless told not
    /// to) loads the agent. Consent is checked by the caller.
    public static func install(binary: String, outputDir: String, loadAgent: Bool) -> Result {
        var r = Result()
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: outputDir + "/.work", withIntermediateDirectories: true)
            guard let sha = sha256(ofFile: binary) else {
                r.lines.append("cannot read \(binary)"); r.code = ExitCode.badArguments; return r
            }
            let dir = UserPaths.binDir + "/" + String(sha.prefix(16))
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let dest = dir + "/meeting-transcribe"
            if sha256(ofFile: dest) != sha {
                try? fm.removeItem(atPath: dest)
                try fm.copyItem(atPath: binary, toPath: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
                r.lines.append("copied the binary to \(dest)")
            } else {
                r.lines.append("the binary is already installed at \(dest)")
            }
            let old = try? fm.destinationOfSymbolicLink(atPath: currentLink)
            if let old, old != dir {
                try repoint(previousLink, to: old)
                r.lines.append("previous -> \(old)")
            }
            try repoint(currentLink, to: dir)
            r.lines.append("current -> \(dir)")

            var cfg = WorkerConfig.load()
            cfg.output_dir = outputDir
            try cfg.save()
            r.lines.append("wrote \(UserPaths.configFile) (output_dir \(outputDir))")

            try fm.createDirectory(atPath: UserPaths.launchAgentsDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: (UserPaths.logFile as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist(outputDir: outputDir),
                                                          format: .xml, options: 0)
            try writeAtomically(data, to: plistPath)
            r.lines.append("wrote \(plistPath)")
        } catch {
            r.lines.append("install failed: \(error)"); r.code = ExitCode.transient; return r
        }
        guard loadAgent else {
            r.lines.append("not loaded (test mode)")
            return r
        }
        // bootout first so a second install replaces the loaded job. Not loaded is fine.
        // bootout returns before launchd has torn the job down, and a bootstrap in that
        // window fails, so wait (up to 10 s) until launchd no longer knows the label.
        launchctl(["bootout", "gui/\(uid())/\(label)"])
        guard waitUntilUnloaded(isLoaded: { isLoaded(label) }) else {
            r.lines.append("the previous worker is still unloading after 10 s. Nothing was loaded. Retry: meeting-transcribe --install-worker --output-dir \(outputDir)")
            r.code = ExitCode.transient
            return r
        }
        let (rc, out) = launchctl(["bootstrap", "gui/\(uid())", plistPath])
        if rc != 0 {
            r.lines.append("launchctl bootstrap failed (\(rc)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            r.lines.append("the worker is NOT loaded. Retry: launchctl bootstrap gui/\(uid()) '\(plistPath)'")
            r.code = ExitCode.transient
        } else {
            r.lines.append("loaded gui/\(uid())/\(label). Check with: launchctl print gui/\(uid())/\(label)")
        }
        return r
    }

    public static func uninstall(revokeConsent: Bool, unloadAgent: Bool) -> Result {
        var r = Result()
        let fm = FileManager.default
        if unloadAgent {
            let (rc, _) = launchctl(["bootout", "gui/\(uid())/\(label)"])
            r.lines.append(rc == 0 ? "unloaded gui/\(uid())/\(label)" : "gui/\(uid())/\(label) was not loaded")
        }
        if fm.fileExists(atPath: plistPath) {
            try? fm.removeItem(atPath: plistPath)
            r.lines.append("removed \(plistPath)")
        } else {
            r.lines.append("no plist at \(plistPath)")
        }
        if revokeConsent {
            if fm.fileExists(atPath: UserPaths.consentFile) { try? fm.removeItem(atPath: UserPaths.consentFile) }
            r.lines.append("consent revoked: removed \(UserPaths.consentFile)")
        } else {
            r.lines.append("consent kept at \(UserPaths.consentFile). Pass --revoke-consent to remove it too.")
        }
        r.lines.append("installed binaries kept in \(UserPaths.binDir) for rollback. Remove that folder to delete them.")
        return r
    }

    /// What `--install-worker` would do, with no consent in place. Writes nothing.
    public static func dryRun(outputDir: String) -> [String] {
        [Consent.disclosureText, "",
         "DRY RUN. Nothing was installed and nothing was written.",
         "Installing needs consent, and consent must be typed by a person in a terminal:",
         "  meeting-transcribe --consent-upload",
         "Then run --install-worker again. It would:",
         "  copy this binary to \(UserPaths.binDir)/<sha>/ and point \(currentLink) at it",
         "  write \(UserPaths.configFile) with output_dir \(outputDir)",
         "  write \(plistPath) watching \(outputDir)/.work, every \(startInterval) s, throttled to \(throttleInterval) s",
         "  load it with launchctl bootstrap gui/\(uid())"]
    }
}
