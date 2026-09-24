// Is a track digital silence? Read in chunks, so a ten-hour track never sits in memory.
//
// A file that cannot be read is an ERROR, never "not silent" and never "silent". Treating
// it as not silent would upload a damaged file and pay for it. Treating it as silent would
// skip a real recording without a word. The caller keeps the audio and marks the take.
import Foundation

public enum WavError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self { case .unreadable(let s): return s }
    }
}

public struct WavInfo: Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let dataOffset: UInt64
    public let dataBytes: UInt64
    public var durationSeconds: Double {
        Double(dataBytes) / Double(max(1, sampleRate * channels * 2))
    }
}

public enum WavPeak {
    /// A track whose peak absolute sample is below this share of full scale is silent.
    /// A real microphone or system tap always carries a noise floor well above it.
    public static let silenceThreshold = 5e-4

    static func le16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    static func le32(_ d: Data, _ o: Int) -> UInt64 {
        (0..<4).reduce(UInt64(0)) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * UInt64($1)) }
    }

    /// The format and data chunk of a 16-bit PCM WAV, or `.unreadable`.
    public static func info(path: String) throws -> WavInfo {
        guard let fh = FileHandle(forReadingAtPath: path) else { throw WavError.unreadable("cannot open \((path as NSString).lastPathComponent)") }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: 0)
        guard let head = try? fh.read(upToCount: 12), head.count == 12,
              head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("WAVE".utf8) else {
            throw WavError.unreadable("\((path as NSString).lastPathComponent) has no RIFF/WAVE header")
        }
        var offset: UInt64 = 12
        var fmt: (rate: Int, channels: Int, bits: Int, format: Int)?
        while offset + 8 <= fileSize {
            try? fh.seek(toOffset: offset)
            guard let ch = try? fh.read(upToCount: 8), ch.count == 8 else { break }
            let id = String(decoding: ch.prefix(4), as: UTF8.self)
            let size = le32(ch, 4)
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, let f = try? fh.read(upToCount: 16), f.count == 16 else {
                    throw WavError.unreadable("fmt chunk truncated")
                }
                fmt = (Int(le32(f, 4)), le16(f, 2), le16(f, 14), le16(f, 0))
            } else if id == "data" {
                guard let fmt else { throw WavError.unreadable("data chunk before fmt chunk") }
                guard fmt.format == 1 || fmt.format == 0xFFFE, fmt.bits == 16, fmt.channels >= 1, fmt.rate > 0 else {
                    throw WavError.unreadable("not 16-bit PCM (format \(fmt.format), \(fmt.bits) bits)")
                }
                // A capture that died mid-write can leave a placeholder size. Read what is there.
                let available = fileSize - body
                let bytes = (size == 0 || size == 0xFFFF_FFFF || size > available) ? available : size
                return WavInfo(sampleRate: fmt.rate, channels: fmt.channels, dataOffset: body,
                               dataBytes: bytes - bytes % 2)
            }
            offset = body + size + (size % 2)
        }
        throw WavError.unreadable("no data chunk in \((path as NSString).lastPathComponent)")
    }

    /// Peak absolute sample over the whole data chunk, as a share of full scale.
    public static func peak(path: String) throws -> Double {
        let i = try info(path: path)
        guard let fh = FileHandle(forReadingAtPath: path) else { throw WavError.unreadable("cannot reopen") }
        defer { try? fh.close() }
        try? fh.seek(toOffset: i.dataOffset)
        var remaining = i.dataBytes
        var peak: Int32 = 0
        while remaining > 0 {
            let n = Int(min(remaining, 1 << 20))
            guard let chunk = try? fh.read(upToCount: n), !chunk.isEmpty else {
                throw WavError.unreadable("read ended \(remaining) bytes early")
            }
            chunk.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for v in s {
                    let a = abs(Int32(Int16(littleEndian: v)))
                    if a > peak { peak = a }
                }
            }
            remaining -= UInt64(chunk.count)
        }
        return Double(peak) / 32768.0
    }

    public static func isSilent(_ peak: Double) -> Bool { peak < silenceThreshold }
}
