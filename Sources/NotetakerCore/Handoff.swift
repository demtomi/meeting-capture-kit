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

/// Kept on purpose and proven done: mark it `.transcribed` so the queue worker never
/// transcribes it again. Written while HOLDING the take's claim, so it cannot race a runner
/// that holds it, and a write that fails is said out loud.
func markKeptTake(_ workDir: String) {
    switch TakeClaim.acquire(takeDir: workDir, log: { _ in }) {
    case .held(let claim):
        defer { claim.release() }
        let wrote = FileManager.default.createFile(atPath: workDir + "/" + Marker.transcribed,
                                                   contents: Data("done by the capture CLI, audio kept by keep-audio\n".utf8))
        if !wrote { err("[meeting-capture] could not mark \(workDir) as transcribed, so the queue worker may transcribe it again\n") }
    case .heldElsewhere(let why):
        err("[meeting-capture] the transcript is written and the audio kept, but another runner holds this take (\(why)), so that runner marks it\n")
    case .failed(let why):
        err("[meeting-capture] could not claim \(workDir) to mark it transcribed: \(why)\n")
    }
}

/// Run `transcriber` on `manifestPath` and return the status the CLI should exit with.
///
/// Nothing here knows what a transcript is. It runs the executable, passing the manifest
/// path, and reports its exit status as its own.
public func runTranscriberHandoff(workDir: String, manifestPath: String, transcriber: String,
                                  outputDir: String, keepAudio: Bool, foreground: Bool) -> Int32 {
    // Absolute before anything else. The child runs with outputDir as its cwd, so a relative
    // manifest path would be resolved a second time from inside it and never be found.
    func absolute(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
    let workDir = absolute(workDir), manifestPath = absolute(manifestPath), outputDir = absolute(outputDir)
    // The transcriber too: taskpolicy spawns it from inside outputDir.
    let transcriber = absolute(transcriber)
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
        // Data minimisation: once a transcript is PROVEN on disk, the raw capture audio
        // is no longer needed, so the workdir (both WAVs plus the manifest) is deleted.
        // Exit 0 alone is not proof. A transcriber that exits 0 and wrote nothing, or
        // wrote it somewhere else, keeps the audio, and so does every non-zero exit.
        // `--keep-audio`, or MEETING_CAPTURE_KEEP_AUDIO in the environment, opts out.
        // The take's own manifest can also say keep, whoever launched this.
        let keepAudio = keepAudio || ((try? Manifest.load(path: manifestPath))?.keepAudio ?? false)
        // The proof, re-read from disk once.
        let proof: ProofFailure? = status == 0 ? proveTake(manifestPath: manifestPath, outputDir: outputDir) : nil
        let proofPasses = status == 0 && proof == nil
        if status == 0 && !keepAudio && proofPasses {
            if case .heldElsewhere(let why) = removeTakeHoldingClaim(workDir) {
                err("[meeting-capture] the transcript is written, but another runner holds this take (\(why)), so it is left for that runner to finish\n")
            }
        } else if let proof {
            err("[meeting-capture] the transcriber exited 0 but \(proof), so the audio is kept in \(workDir)\n")
        } else if proofPasses && keepAudio {
            markKeptTake(workDir)
        }
        return status
    } catch {
        err("transcriber launch failed: \(error)\n")
        return 1
    }
}
