// System-audio capture via a Core Audio process tap (the "everyone else" track).
// Grown out of a standalone spike into a start/stop
// capturer that writes mono Float samples at the tap's native rate to disk and
// stamps the wall-clock of its first buffer for shared-start alignment.
import Foundation
import CaptureIO
import CoreAudio
import AudioToolbox

final class SystemTap: SystemCapturer {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    var sink: SampleSink?
    /// Peak |sample| since the last `takeLevelPeak()`.
    ///
    /// This used to be absent, so `SystemCapturer`'s protocol default of 0 applied and
    /// the stderr level line read `sys=0.0000` for every tap-mode run no matter how
    /// loud the far side was. That reads as a broken tap when the tap is fine.


    /// Tap native sample rate (48 kHz on M3 Pro / macOS 26); resampled to 16 kHz on write.
    private(set) var nativeRate: Double = 48000
    /// CLOCK_MONOTONIC_RAW ns of the first delivered buffer (0 until audio flows).
    private(set) var firstBufferNs: UInt64 = 0

    struct TapError: Error { let msg: String; let status: OSStatus }

    /// The current default output device (id, uid, name). The aggregate that wraps
    /// the tap MUST be pinned to this device — otherwise a global tap captures
    /// silence whenever audio plays to a non-default route (headphones/AirPods).
    private func defaultOutputDevice() -> (id: AudioObjectID, uid: String, name: String)? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != kAudioObjectUnknown else { return nil }

        func stringProp(_ selector: AudioObjectPropertySelector) -> String? {
            var str: CFString = "" as CFString
            var sz = UInt32(MemoryLayout<CFString>.size)
            var a = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let ok = withUnsafeMutablePointer(to: &str) {
                AudioObjectGetPropertyData(devID, &a, 0, nil, &sz, $0)
            }
            return ok == noErr ? (str as String) : nil
        }
        guard let uid = stringProp(kAudioDevicePropertyDeviceUID) else { return nil }
        return (devID, uid, stringProp(kAudioObjectPropertyName) ?? "unknown")
    }

    func start() throws {
        // 1) Global system-audio tap: capture everything, mute nothing.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "meeting-capture"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw TapError(msg: "AudioHardwareCreateProcessTap", status: st) }

        // 2) Wrap the tap in a private aggregate device, PINNED to the current
        //    default output device (main sub-device + sub-device list). Without
        //    this pin the tap captures silence off any non-default output route.
        let tapUID = desc.uuid.uuidString
        var aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "meeting-capture-agg",
            // UNIQUE PER RUN. A fixed literal here is a system-wide identifier, so two
            // copies of this tool (or two forks of this package) running at once
            // contend for the same aggregate device.
            kAudioAggregateDeviceUIDKey as String: "com.meetingcapturekit.agg.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapUID,
                 kAudioSubTapDriftCompensationKey as String: 1]
            ]
        ]
        if let out = defaultOutputDevice() {
            aggDict[kAudioAggregateDeviceMainSubDeviceKey as String] = out.uid
            aggDict[kAudioAggregateDeviceSubDeviceListKey as String] = [
                [kAudioSubDeviceUIDKey as String: out.uid]
            ]
            FileHandle.standardError.write("[meeting-capture] system tap bound to output: \(out.name)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("[meeting-capture] WARNING: could not resolve default output device — tap may capture silence.\n".data(using: .utf8)!)
        }
        st = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
        guard st == noErr else { throw TapError(msg: "AudioHardwareCreateAggregateDevice", status: st) }

        // 3) Read the tap format (sample rate / channel count).
        var fmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &fmt)
        guard st == noErr else { throw TapError(msg: "get tap format", status: st) }
        nativeRate = fmt.mSampleRate

        // 4) IOProc: downmix to mono Float, accumulate, stamp first-buffer time.
        let queue = DispatchQueue(label: "mck.systemtap.io")
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] (_, inInputData, _, _, _) in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, let mData = first.mData else { return }
            let chans = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / chans
            let ptr = mData.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            if self.firstBufferNs == 0 { self.firstBufferNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
            self.lock.unlock()
            self.sink?.append(ptr, count: frames, stride: chans, channels: chans)
        }
        guard st == noErr else { throw TapError(msg: "AudioDeviceCreateIOProcIDWithBlock", status: st) }

        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else { throw TapError(msg: "AudioDeviceStart", status: st) }
        SystemTap.live.append(self)
    }

    /// Every live tap, so an `exit()` from anywhere still tears down the private
    /// aggregate device it created. Without this an early exit leaves an orphan audio
    /// device in the user's system configuration, which they then have to find and
    /// remove by hand.
    nonisolated(unsafe) static var live: [SystemTap] = []

    static func cleanupAll() {
        for t in live { t.stop() }
        live.removeAll()
    }

    func stop() {
        if aggID != kAudioObjectUnknown, let p = procID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
        }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
    }

    func takeLevelPeak() -> Float { sink?.takeLevelPeak() ?? 0 }
}
