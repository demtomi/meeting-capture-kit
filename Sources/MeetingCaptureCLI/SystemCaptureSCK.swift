// System-audio capture via ScreenCaptureKit (the remote-side track).
// SCK taps app/display audio BEFORE it is rendered to an output device, so it
// captures the same audio whether output is Mac speakers, wired, or Bluetooth
// (AirPods) — unlike a Core Audio process tap, which returns silence off a
// Bluetooth route. Needs Screen Recording permission (TCC), granted once.
import Foundation
import CaptureIO
import ScreenCaptureKit
import CoreMedia
import AudioToolbox

final class SystemCaptureSCK: NSObject, SCStreamOutput, SystemCapturer {
    private var stream: SCStream?
    private let lock = NSLock()
    var sink: SampleSink?
    private let queue = DispatchQueue(label: "mck.sck.audio")

    private(set) var nativeRate: Double = 48000   // requested; replaced by the rate that actually arrives
    private(set) var firstBufferNs: UInt64 = 0

    struct SCKError: Error { let msg: String }

    func start() throws {
        let sem = DispatchSemaphore(value: 0)
        var startErr: Error?
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw SCKError(msg: "no display available for SCK") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(self.nativeRate)
                config.channelCount = 1
                // Minimal video: SCK requires a video config even for audio-only work.
                config.width = 100
                config.height = 100
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 6

                let s = SCStream(filter: filter, configuration: config, delegate: nil)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                self.stream = s
            } catch { startErr = error }
            sem.signal()
        }
        sem.wait()
        if let e = startErr {
            throw SCKError(msg: "ScreenCaptureKit start failed: \(e.localizedDescription) — grant Screen Recording to your terminal in System Settings > Privacy & Security > Screen Recording, then restart the terminal.")
        }
    }

    func stop() {
        guard let s = stream else { return }
        let sem = DispatchSemaphore(value: 0)
        Task { try? await s.stopCapture(); sem.signal() }
        sem.wait()
        stream = nil
    }

    // SCStreamOutput: audio arrives as CMSampleBuffers of mono Float32.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        // READ the rate that arrived, never assume the one we requested. `config.sampleRate`
        // is a request, and a request the system declines is the failure that produces a
        // WAV whose header disagrees with its samples. MicCapture already reads its real
        // rate off the format description, and these two capturers must not differ on it.
        if let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
           asbd.mSampleRate > 0 {
            lock.lock()
            if abs(asbd.mSampleRate - nativeRate) > 1 {
                FileHandle.standardError.write("[meeting-capture] system capture rate is \(asbd.mSampleRate) Hz, not the requested \(nativeRate) Hz. Using the actual rate.\n".data(using: .utf8)!)
                nativeRate = asbd.mSampleRate
            }
            lock.unlock()
        }
        var ablSize = 0
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let first = buffers.first, let mData = first.mData else { return }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let ptr = mData.assumingMemoryBound(to: Float.self)
        lock.lock()
        if firstBufferNs == 0 { firstBufferNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
        lock.unlock()
        sink?.append(ptr, count: frames)
    }

    func takeLevelPeak() -> Float { sink?.takeLevelPeak() ?? 0 }
}
