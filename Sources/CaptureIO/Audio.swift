// Resample captured Float samples to 16 kHz mono and write a 16-bit PCM WAV —
// exactly the format the engine ingests (the manifest format: 16 kHz / mono / PCM16 LE),
// so the Python side never resamples. Leading silence is prepended per track to
// align both tracks to the shared-start zero before resampling.
import Foundation
import AVFoundation

public enum Audio {
    public static let targetRate = 16000.0

    /// Prepend `leadNs` of silence (at `nativeRate`) so the track starts at the shared zero.
    public static func padLead(_ samples: [Float], leadNs: UInt64, nativeRate: Double) -> [Float] {
        guard leadNs > 0 else { return samples }
        let leadFrames = Int((Double(leadNs) / 1_000_000_000.0) * nativeRate)
        guard leadFrames > 0 else { return samples }
        return [Float](repeating: 0, count: leadFrames) + samples
    }

    public struct ResampleError: Error, CustomStringConvertible {
        public let stage: String
        public let underlying: String?
        public var description: String {
            "resample failed at \(stage)" + (underlying.map { ": \($0)" } ?? "")
        }
    }

    /// High-quality resample nativeRate -> 16 kHz using AVAudioConverter.
    ///
    /// THROWS ON EVERY FAILURE PATH, and that is the whole point of this signature.
    /// Each of these `guard`s used to `return samples`, handing back the UNRESAMPLED
    /// 48 kHz array. `writeWav16` then stamped a 16 kHz header on it and
    /// `finalizeTrack` reported `count / 16000` as the duration. The result was a
    /// file that plays 3x too fast, with a duration 3x too long, written by a
    /// process that exited 0 and said nothing. A recorder that silently corrupts
    /// the recording is worse than one that refuses to write it.
    ///
    /// `StreamingResampler` in the LiveAudio library already threw on the identical
    /// conditions. This is the archival path catching up with it.
    public static func resampleTo16k(_ samples: [Float], nativeRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        if abs(nativeRate - targetRate) < 1 { return samples }
        guard
            let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false),
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
            let conv = AVAudioConverter(from: inFmt, to: outFmt)
        else { throw ResampleError(stage: "converter setup (nativeRate \(nativeRate))", underlying: nil) }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw ResampleError(stage: "input buffer allocation (\(samples.count) frames)", underlying: nil) }

        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBytes { raw in
            inBuf.floatChannelData![0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: samples.count)
        }

        let outCap = AVAudioFrameCount(Double(samples.count) * targetRate / nativeRate + 8192)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)
        else { throw ResampleError(stage: "output buffer allocation (\(outCap) frames)", underlying: nil) }

        // `nonisolated(unsafe)` is an ASSERTION, not a fix, and here is what makes it
        // true: `AVAudioConverter.convert(to:error:withInputFrom:)` calls this block
        // SYNCHRONOUSLY on the calling thread, before it returns. Nothing else ever
        // touches `fed` or `input`, and no concurrency is involved despite the block
        // being typed `@Sendable`. `@preconcurrency import AVFoundation` was rejected
        // because it would silence every future AVFAudio Sendable diagnostic in this
        // file, including one that turns out to be real.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = inBuf
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw ResampleError(stage: "conversion", underlying: err?.localizedDescription ?? "unknown")
        }
        let n = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
    }

    /// Write mono 16 kHz Float samples as a 16-bit PCM WAV.
    ///
    /// THROWS. It used to swallow the write with `try?`, which meant an unwritable
    /// `--output-dir` produced a clean run that reported the duration of a recording
    /// that was never saved.
    public static func writeWav16(_ samples: [Float], to path: String) throws {
        let sampleRate = UInt32(targetRate)
        var pcm = [Int16](); pcm.reserveCapacity(samples.count)
        // ROUNDED, not truncated. `Int16(x)` truncates toward zero, which biases every
        // sample and disagrees with the Mixer's PCM16 encoder in the LiveAudio library.
        // Two encoders in one package must not round differently.
        for f in samples { pcm.append(Int16((max(-1, min(1, f)) * 32767).rounded())) }
        let dataBytes = pcm.count * 2
        var out = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        out.append("RIFF".data(using: .ascii)!); out.append(le32(UInt32(36 + dataBytes))); out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!); out.append(le32(16)); out.append(le16(1)); out.append(le16(1))
        out.append(le32(sampleRate)); out.append(le32(sampleRate * 2)); out.append(le16(2)); out.append(le16(16))
        out.append("data".data(using: .ascii)!); out.append(le32(UInt32(dataBytes)))
        pcm.withUnsafeBytes { out.append(contentsOf: $0) }
        try out.write(to: URL(fileURLWithPath: path))
    }

    /// Full track pipeline: pad to shared zero -> resample -> write WAV. Returns duration seconds.
    @discardableResult
    public static func finalizeTrack(_ raw: [Float], firstBufferNs: UInt64, sharedStartNs: UInt64, nativeRate: Double, to path: String) throws -> Double {
        let leadNs = firstBufferNs > sharedStartNs ? firstBufferNs - sharedStartNs : 0
        let padded = padLead(raw, leadNs: leadNs, nativeRate: nativeRate)
        let resampled = try resampleTo16k(padded, nativeRate: nativeRate)
        try writeWav16(resampled, to: path)
        return Double(resampled.count) / targetRate
    }

    // MARK: - Streaming finalize

    /// A WAV file written incrementally, so no full copy of the track is ever resident.
    ///
    /// The RIFF and data sizes are not known until the last sample is written, so the
    /// header goes down as a placeholder and is patched on `finish()`. The file is
    /// therefore INVALID until `finish()` returns, which is why the caller writes to a
    /// temporary path and moves it into place only on success.
    public final class WavWriter {
        private let handle: FileHandle
        private let path: String
        public private(set) var framesWritten: Int = 0

        public init(path: String) throws {
            self.path = path
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw ResampleError(stage: "creating \(path)", underlying: nil)
            }
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.write(contentsOf: Data(count: 44))   // placeholder header
        }

        public func append(_ samples: UnsafeBufferPointer<Float>) throws {
            guard !samples.isEmpty else { return }
            var pcm = [Int16](); pcm.reserveCapacity(samples.count)
            // ROUNDED, matching the Mixer's PCM16 encoder in the LiveAudio library.
            // Truncation biases every sample toward zero.
            for f in samples { pcm.append(Int16((max(-1, min(1, f)) * 32767).rounded())) }
            try pcm.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
            framesWritten += samples.count
        }

        public func finish() throws {
            let sampleRate = UInt32(targetRate)
            let dataBytes = UInt32(framesWritten * 2)
            func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            var h = Data()
            h.append("RIFF".data(using: .ascii)!); h.append(le32(36 + dataBytes)); h.append("WAVE".data(using: .ascii)!)
            h.append("fmt ".data(using: .ascii)!); h.append(le32(16)); h.append(le16(1)); h.append(le16(1))
            h.append(le32(sampleRate)); h.append(le32(sampleRate * 2)); h.append(le16(2)); h.append(le16(16))
            h.append("data".data(using: .ascii)!); h.append(le32(dataBytes))
            precondition(h.count == 44, "WAV header must be exactly 44 bytes")
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: h)
            try handle.close()
        }
    }

    /// Read raw Float32 from `rawURL`, resample to 16 kHz, and write a PCM16 WAV,
    /// holding only one chunk at a time. Returns the duration in seconds.
    ///
    /// ONE converter instance is fed successive chunks, which is what makes this
    /// equivalent to the one-shot path rather than an approximation of it. Resampling
    /// each chunk with its own converter would ring at every boundary.
    ///
    /// `leadFrames` of silence at the NATIVE rate are pushed through the same converter
    /// ahead of the audio, so the alignment padding is resampled identically to
    /// everything after it.
    public static func streamResampleToWav(rawURL: URL,
                                    nativeRate: Double,
                                    leadFrames: Int,
                                    to path: String) throws -> Double {
        let chunkFrames = 1 << 16       // 65,536 frames, about 1.4 s at 48 kHz

        let writer = try WavWriter(path: path)
        let passthrough = abs(nativeRate - targetRate) < 1

        var conv: AVAudioConverter?
        var inFmt: AVAudioFormat?
        var outFmt: AVAudioFormat?
        if !passthrough {
            guard
                let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false),
                let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
                let c = AVAudioConverter(from: i, to: o)
            else { throw ResampleError(stage: "converter setup (nativeRate \(nativeRate))", underlying: nil) }
            inFmt = i; outFmt = o; conv = c
        }

        /// Feed one chunk through the converter and write whatever comes out.
        func push(_ samples: [Float]) throws {
            guard !samples.isEmpty else { return }
            guard let conv, let inFmt, let outFmt else {
                try samples.withUnsafeBufferPointer { try writer.append($0) }
                return
            }
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
            else { throw ResampleError(stage: "input buffer allocation (\(samples.count) frames)", underlying: nil) }
            inBuf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            let outCap = AVAudioFrameCount(Double(samples.count) * targetRate / nativeRate + 8192)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)
            else { throw ResampleError(stage: "output buffer allocation (\(outCap) frames)", underlying: nil) }

            // `nonisolated(unsafe)` is an ASSERTION, not a fix, and here is what makes it
        // true: `AVAudioConverter.convert(to:error:withInputFrom:)` calls this block
        // SYNCHRONOUSLY on the calling thread, before it returns. Nothing else ever
        // touches `fed` or `input`, and no concurrency is involved despite the block
        // being typed `@Sendable`. `@preconcurrency import AVFoundation` was rejected
        // because it would silence every future AVFAudio Sendable diagnostic in this
        // file, including one that turns out to be real.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = inBuf
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error {
                throw ResampleError(stage: "conversion", underlying: err?.localizedDescription ?? "unknown")
            }
            let n = Int(outBuf.frameLength)
            if n > 0 {
                try writer.append(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
            }
        }

        // Alignment padding first, through the same converter.
        var remainingLead = max(0, leadFrames)
        while remainingLead > 0 {
            let n = min(remainingLead, chunkFrames)
            try push([Float](repeating: 0, count: n))
            remainingLead -= n
        }

        let reader = try FileHandle(forReadingFrom: rawURL)
        defer { try? reader.close() }
        // Do not let the scratch file into the unified buffer cache. It is read once,
        // sequentially, and never again, so caching its pages evicts something the
        // user actually wanted during a meeting that may run for hours.
        //
        // HONEST LIMIT: this did NOT measurably change this process's peak resident
        // size, which was the reason it was tried. Sampling the live process showed
        // memory already flat at about 21 MB across a three-minute recording. It is
        // kept because it is the right access-pattern hint for a write-once,
        // read-once, delete file, not because it was observed to fix anything.
        _ = fcntl(reader.fileDescriptor, F_NOCACHE, 1)
        _ = fcntl(reader.fileDescriptor, F_RDAHEAD, 0)
        let chunkBytes = chunkFrames * MemoryLayout<Float>.size
        while true {
            let data = try reader.read(upToCount: chunkBytes) ?? Data()
            if data.isEmpty { break }
            let count = data.count / MemoryLayout<Float>.size
            guard count > 0 else { break }
            let chunk = data.withUnsafeBytes { raw -> [Float] in
                Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress!, count: count))
            }
            try push(chunk)
        }

        // FLUSH THE CONVERTER. It holds a few frames internally to satisfy its filter,
        // and they only come out when it is told the stream has ended. Feeding chunks
        // with `.noDataNow` and then simply stopping left 6 frames of every recording
        // behind, which the equivalence check caught as 47,994 frames against the
        // one-shot path's 48,000. Silent, tiny, and wrong on every single file.
        if let conv, let outFmt {
            let outCap = AVAudioFrameCount(8192)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)
            else { throw ResampleError(stage: "flush buffer allocation", underlying: nil) }
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                throw ResampleError(stage: "flush", underlying: err?.localizedDescription ?? "unknown")
            }
            let n = Int(outBuf.frameLength)
            if n > 0 {
                try writer.append(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
            }
        }

        try writer.finish()
        return Double(writer.framesWritten) / targetRate
    }
}
