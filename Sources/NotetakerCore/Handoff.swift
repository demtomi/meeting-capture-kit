// The capture CLI's post-transcriber step, lifted out of `main.swift` so a check can
// drive it. The real `meeting-capture` needs audio devices and grants, so without this
// seam the one line that deletes a recording could never be exercised offline.
import Foundation

/// Efficiency-core count (Apple Silicon perflevel1). Used to cap the child's intra-op
/// threads when it runs under background QoS. Falls back to half the logical cores on
/// hardware without perf levels.
public func efficiencyCoreCount() -> Int {
    var n: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0, n > 0 {
        return Int(n)
    }
    return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
}

private func err(_ s: String) {
    FileHandle.standardError.write(s.data(using: .utf8)!)
}

/// Run `transcriber` on `manifestPath` and return the status the CLI should exit with.
///
/// Nothing here knows what a transcript is. It runs the executable, passing the manifest
/// path, and reports its exit status as its own.
public func runTranscriberHandoff(workDir: String, manifestPath: String, transcriber: String,
                                  outputDir: String, keepAudio: Bool, foreground: Bool) -> Int32 {
    guard FileManager.default.isExecutableFile(atPath: transcriber) else {
        err("--transcriber is not an executable file: \(transcriber)\n")
        return 1
    }
    let proc = Process()
    proc.currentDirectoryURL = URL(fileURLWithPath: outputDir)
    // A transcription tool commonly shells out to `ffmpeg`. When this CLI is launched
    // from a GUI app the inherited PATH is minimal and Homebrew is not on it, so the
    // child fails to find its own dependencies. Prepend the common prefixes so the
    // handoff behaves the same from a terminal and from an app bundle.
    var childEnv = ProcessInfo.processInfo.environment
    let basePath = childEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    childEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePath

    // Transcription can be CPU-heavy and, unthrottled, pins one worker per performance
    // core, so it fights whatever is in the foreground. Two throttles, both opt-out:
    //   1. Background QoS via `taskpolicy -b` (PRIO_DARWIN_BG, inherited by every
    //      child thread), so the OS schedules it on efficiency cores and lets
    //      foreground work preempt it.
    //   2. OMP_NUM_THREADS capped to the efficiency-core count, so it does not
    //      oversubscribe the cores it has been confined to.
    // `--foreground` opts out of both, for an unattended machine.
    let taskpolicy = "/usr/sbin/taskpolicy"
    let throttle = !foreground && FileManager.default.isExecutableFile(atPath: taskpolicy)
    if throttle {
        let threads = efficiencyCoreCount()
        childEnv["OMP_NUM_THREADS"] = String(threads)
        proc.executableURL = URL(fileURLWithPath: taskpolicy)
        proc.arguments = ["-b", transcriber, manifestPath]
        err("[meeting-capture] running \(transcriber) under background QoS (taskpolicy -b, \(threads) threads) ...\n")
    } else {
        proc.executableURL = URL(fileURLWithPath: transcriber)
        proc.arguments = [manifestPath]
        err("[meeting-capture] running \(transcriber) ...\n")
    }
    proc.environment = childEnv
    do {
        try proc.run()
        proc.waitUntilExit()
        let status = proc.terminationStatus
        // Data minimisation: once the transcriber has succeeded, the raw capture audio
        // is no longer needed, so the workdir (both WAVs plus the manifest) is deleted.
        // On failure it is kept so the step can be retried against the same audio.
        // `--keep-audio`, or MEETING_CAPTURE_KEEP_AUDIO in the environment, opts out.
        if status == 0 && !keepAudio {
            try? FileManager.default.removeItem(atPath: workDir)
        }
        return status
    } catch {
        err("transcriber launch failed: \(error)\n")
        return 1
    }
}
