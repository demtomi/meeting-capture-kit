// A capture buffer that does not grow without limit.
//
// Both capturers used to append every sample to a `[Float]` that lived until the
// recording ended. At 48 kHz that is 192 KB per second per track, so a two-hour
// dual-track meeting held about 2.7 GB before finalizing even started, and finalizing
// then copied it several times over. The recorder ran out of memory on exactly the
// long meetings it exists to record.
//
// So samples go to disk as they arrive. A capture callback appends to a small staging
// array, a background thread swaps that array out and writes it, and resident memory
// stays at roughly one flush interval of audio no matter how long the meeting runs.
//
// The staging swap is what keeps the audio callback cheap: it holds the lock only long
// enough to hand over a reference, never for the duration of a write. Disk I/O never
// happens on the callback's thread.
import Foundation

public final class SampleSink {
    private let lock = NSLock()
    private var staging: [Float] = []
    private var handle: FileHandle?
    public private(set) var url: URL
    private var flusher: Thread?
    private var running = false
    private var writeError: Error?
    public private(set) var totalFrames: Int = 0

    /// Peak |sample| since the last `takeLevelPeak()`.
    private var levelPeak: Float = 0

    /// 200 ms at 48 kHz is 9,600 frames, so the staging array stays around 38 KB.
    /// Short enough that memory is flat, long enough that the writer is not woken
    /// constantly during a meeting that may run for hours.
    private let flushInterval: TimeInterval = 0.2

    public init(directory: String, name: String) throws {
        url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).f32")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SinkError(message: "could not create capture scratch file at \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        // Same reason as the reader in `Audio.streamResampleToWav`: this file is
        // write-once, read-once, and delete. Caching its pages charges the whole
        // recording to this process for no benefit.
        _ = fcntl(handle!.fileDescriptor, F_NOCACHE, 1)
    }

    public struct SinkError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public func start() {
        lock.lock(); running = true; lock.unlock()
        // The flusher owns nothing the caller mutates, and every field it reads is
        // guarded by `lock`. Captured strongly on purpose: a sink whose owner is
        // released mid-recording must still flush what it already holds rather than
        // dropping the tail of the take.
        nonisolated(unsafe) let me = self
        let t = Thread { me.flushLoop() }
        t.name = "meeting-capture.sink"
        t.qualityOfService = .utility
        flusher = t
        t.start()
    }

    /// Called from an audio callback. Appends and tracks the peak, nothing else.
    public func append(_ ptr: UnsafePointer<Float>, count: Int, stride: Int = 1, channels: Int = 1) {
        guard count > 0 else { return }
        lock.lock()
        staging.reserveCapacity(staging.count + count)
        var peak = levelPeak
        var i = 0
        while i < count {
            var acc: Float = 0
            for c in 0..<channels { acc += ptr[i * stride + c] }
            let mono = acc / Float(channels)
            staging.append(mono)
            let a = abs(mono)
            if a > peak { peak = a }
            i += 1
        }
        levelPeak = peak
        lock.unlock()
    }

    public func takeLevelPeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = levelPeak; levelPeak = 0; return p
    }

    private func flushLoop() {
        while true {
            Thread.sleep(forTimeInterval: flushInterval)
            lock.lock()
            let stillRunning = running
            let chunk = staging
            staging.removeAll(keepingCapacity: true)
            lock.unlock()
            writeChunk(chunk)
            if !stillRunning { return }
        }
    }

    private func writeChunk(_ chunk: [Float]) {
        guard !chunk.isEmpty, let h = handle else { return }
        do {
            try chunk.withUnsafeBytes { try h.write(contentsOf: Data($0)) }
            lock.lock(); totalFrames += chunk.count; lock.unlock()
        } catch {
            lock.lock(); if writeError == nil { writeError = error }; lock.unlock()
        }
    }

    /// Stops the flusher, writes whatever is left, and closes the file.
    ///
    /// THROWS any write error the background thread hit. A capture whose samples
    /// failed to reach the disk must not be reported as a successful recording.
    public func finish() throws {
        lock.lock(); running = false; lock.unlock()
        // The flusher checks `running` only after its own write, so one interval is
        // the longest it can still be working.
        Thread.sleep(forTimeInterval: flushInterval + 0.05)
        lock.lock()
        let remainder = staging
        staging.removeAll()
        lock.unlock()
        writeChunk(remainder)
        try handle?.close()
        handle = nil
        lock.lock(); let e = writeError; lock.unlock()
        if let e { throw e }
    }

    public func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
