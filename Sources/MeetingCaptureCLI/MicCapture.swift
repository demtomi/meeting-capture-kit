// Microphone capture (the host track) via AVCaptureSession.
//
// Why AVCaptureSession and not AVAudioEngine: we want the BUILT-IN mic for the
// host while AirPods stay the OUTPUT device. AVAudioEngine uses one I/O unit and
// stalls its input a second or two after start when the forced input device
// differs from the output device. AVCaptureSession captures a *named* device
// continuously, independent of the output route — so built-in-mic-in +
// AirPods-out works, and AirPods stay in high-quality A2DP (no HFP, no bleed).
//
// Accumulates mono Float at the device native rate; resampled to 16 kHz on write.
import Foundation
import CaptureIO
import AVFoundation
import CoreMedia
import AudioToolbox

final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "mck.mic.audio")
    private let lock = NSLock()
    /// Samples go here, and this writes them to disk. See `SampleSink`.
    var sink: SampleSink?

    private(set) var nativeRate: Double = 48000
    private(set) var firstBufferNs: UInt64 = 0

    struct MicError: Error { let msg: String }

    /// Explicit TCC microphone gate. A valid device that delivers 0 frames almost
    /// always means permission is denied: capture "starts" and macOS feeds silence.
    private func ensureMicPermission() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let names = ["notDetermined", "restricted", "denied", "authorized"]
        let idx = Int(status.rawValue)
        FileHandle.standardError.write("[meeting-capture] mic permission: \((idx >= 0 && idx < names.count) ? names[idx] : "\(status.rawValue)")\n".data(using: .utf8)!)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            AVCaptureDevice.requestAccess(for: .audio) { granted in ok = granted; sem.signal() }
            sem.wait()
            FileHandle.standardError.write("[meeting-capture] mic permission prompt result: \(ok ? "granted" : "denied")\n".data(using: .utf8)!)
            if !ok { throw MicError(msg: "microphone permission denied at prompt.") }
        default:
            throw MicError(msg: "microphone permission is DENIED/restricted for this terminal. Enable it in System Settings > Privacy & Security > Microphone > (your terminal), then restart the terminal.")
        }
    }

    /// A case-insensitive substring of the microphone to use. When nil, the built-in
    /// microphone is preferred so that AirPods stay output-only, which is the whole
    /// reason this is not simply `AVCaptureDevice.default(for:)`.
    var deviceHint: String? = nil

    /// Selection order: an explicit `--mic-device` substring, then the built-in
    /// microphone, then whatever the system offers.
    ///
    /// The built-in test IS a name match, and AVFoundation gives no better one: there
    /// is no "is this the built-in microphone" flag on a macOS `AVCaptureDevice`. So
    /// this matches Mac product names, which is English-biased and will miss on a
    /// localized system or an unlisted model. When it misses it falls through to the
    /// system default input rather than to an arbitrary device, and `--mic-device` is
    /// the way to name one explicitly.
    private func pickMic() -> AVCaptureDevice? {
        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified)

        if let hint = deviceHint?.lowercased(), !hint.isEmpty {
            if let m = ds.devices.first(where: { $0.localizedName.lowercased().contains(hint) }) {
                return m
            }
            let names = ds.devices.map(\.localizedName).joined(separator: ", ")
            FileHandle.standardError.write("[meeting-capture] no microphone matches \"\(hint)\". Available: \(names)\n".data(using: .utf8)!)
            return nil
        }
        // A HEURISTIC, and named as one. AVFoundation exposes no "is this the built-in
        // microphone" flag on macOS, so this matches the localized device name against
        // the Mac product names. It is English-biased and it will miss on a localized
        // system or an unlisted model, which is exactly why `--mic-device` exists and
        // why the fallback below is the system default rather than an arbitrary device.
        let builtInNeedles = ["macbook", "built-in", "built in", "internal",
                              "imac", "mac mini", "mac studio", "mac pro"]
        if let builtIn = ds.devices.first(where: { d in
            let n = d.localizedName.lowercased()
            return builtInNeedles.contains { n.contains($0) }
        }) {
            return builtIn
        }
        return AVCaptureDevice.default(for: .audio) ?? ds.devices.first
    }

    func start() throws {
        try ensureMicPermission()

        guard let device = pickMic() else { throw MicError(msg: "no microphone device found") }
        FileHandle.standardError.write("[meeting-capture] mic device: \(device.localizedName)\n".data(using: .utf8)!)

        let deviceInput: AVCaptureDeviceInput
        do { deviceInput = try AVCaptureDeviceInput(device: device) }
        catch { throw MicError(msg: "cannot open mic device: \(error.localizedDescription)") }

        session.beginConfiguration()
        guard session.canAddInput(deviceInput) else { session.commitConfiguration(); throw MicError(msg: "cannot add mic input") }
        session.addInput(deviceInput)

        // Ask for mono 32-bit float PCM at 48 kHz so the callback buffers are
        // simple to accumulate; the engine resamples to 16 kHz on write.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); throw MicError(msg: "cannot add mic output") }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Track the true device rate from the buffer's format (in case the request
        // wasn't honored exactly).
        if let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            let sr = asbd.pointee.mSampleRate
            if sr > 0 { lock.lock(); if firstBufferNs == 0 { nativeRate = sr }; lock.unlock() }
        }

        var ablSize = 0
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard st == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let first = buffers.first, let mData = first.mData else { return }
        let chans = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / chans
        let ptr = mData.assumingMemoryBound(to: Float.self)

        lock.lock()
        if firstBufferNs == 0 { firstBufferNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
        lock.unlock()
        sink?.append(ptr, count: frames, stride: chans, channels: chans)
    }



    func takeLevelPeak() -> Float { sink?.takeLevelPeak() ?? 0 }
}
