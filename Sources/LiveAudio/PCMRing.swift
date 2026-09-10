// PCMRing — the bounded buffer between the audio callback and the stdout writer.
//
// The contract, in one sentence: it never blocks and never writes disk. The audio callback
// appends to a bounded ring and returns. On overflow it drops the OLDEST frame and increments
// a counter, and it does not wait on the writer.
//
// Both halves of that sentence are load-bearing and neither is checkable by a compiler:
//
//   never blocks. A live-tap audio callback that waits on a stalled network write is exactly
//   the backpressure condition this ring absorbs. A blocking stall in the tap process was
//   measured not to cost `meeting-capture` any samples, but that is the safety net, not the
//   design: the archival take is the artifact that cannot be re-recorded.
//
//   drops the OLDEST — drop-newest would silently hold a stale window while live speech is
//   thrown away, and the consumer would see a contiguous `seq` run with no gap to detect.
//   Dropping the oldest leaves a `seq` discontinuity, which is the ONLY signal the consumer
//   uses to mark the ring stale. Correctness never rides a parsed status line.
import Foundation

/// One 250 ms unit of 16 kHz mono PCM16, as it will go on the wire.
///
/// `seq` is assigned by the tap at capture time and travels with the frame, so a frame the
/// ring drops leaves a hole the consumer can see. It is deliberately NOT reassigned on the
/// way out: renumbering at the writer would paper over exactly the loss this design exposes.
public struct PCMFrame: Equatable, Sendable {
    public let seq: UInt64
    /// Capture-clock nanoseconds (mach absolute time converted to ns), not wall clock.
    public let hostTimeNs: UInt64
    public let pcm: [Int16]

    public init(seq: UInt64, hostTimeNs: UInt64, pcm: [Int16]) {
        self.seq = seq
        self.hostTimeNs = hostTimeNs
        self.pcm = pcm
    }
}

/// Fixed-capacity FIFO. `@unchecked Sendable` because the lock is the safety argument:
/// every stored property is touched only inside `lock`.
public final class PCMRing: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var storage: [PCMFrame] = []
    private var head = 0
    private var count = 0
    private var _droppedFrames = 0
    private var _lastDroppedSeq: UInt64?

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    /// Frames evicted because the writer fell behind. Reported on stderr as telemetry; the
    /// consumer never reads this number, it reads the `seq` gap.
    public var droppedFrames: Int { lock.withLock { _droppedFrames } }
    public var lastDroppedSeq: UInt64? { lock.withLock { _lastDroppedSeq } }
    public var pending: Int { lock.withLock { count } }

    /// Append and return immediately, always. `true` means the frame went in with room to
    /// spare; `false` means it went in and the oldest was evicted to make space.
    ///
    /// There is no path here that waits, sleeps, or retries. The lock is held for a bounded
    /// number of instructions over an array slot — it is not a queue the writer can hold.
    @discardableResult
    public func append(_ frame: PCMFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var evicted = false
        if count == capacity {
            _lastDroppedSeq = storage[head].seq
            _droppedFrames += 1
            head = (head + 1) % capacity
            count -= 1
            evicted = true
        }
        let slot = (head + count) % capacity
        if storage.count < capacity {
            storage.append(frame)
        } else {
            storage[slot] = frame
        }
        count += 1
        return !evicted
    }

    /// Take everything pending, oldest first, and leave the ring empty.
    public func drain() -> [PCMFrame] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        var out: [PCMFrame] = []
        out.reserveCapacity(count)
        for i in 0..<count { out.append(storage[(head + i) % capacity]) }
        head = 0
        count = 0
        storage.removeAll(keepingCapacity: true)
        return out
    }
}

// NSLock.withLock exists on macOS 13+, but spelling it out keeps this file free of any
// availability question in a target the audio callback runs inside.
private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
