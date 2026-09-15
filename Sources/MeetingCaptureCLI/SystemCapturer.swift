// Common interface for a system-audio (remote-side) capturer, so main.swift can
// swap between the ScreenCaptureKit path (default; Bluetooth-safe) and the Core
// Audio process tap (fallback; speakers/wired only). Both accumulate mono Float
// at a native rate and stamp their first-buffer wall-clock for shared-start align.
import Foundation
import CaptureIO

protocol SystemCapturer: AnyObject {
    var nativeRate: Double { get }
    var firstBufferNs: UInt64 { get }
    func start() throws
    func stop()
    /// Where captured samples are written. Set before `start()`.
    ///
    /// It used to be `drain() -> [Float]`, which meant the whole meeting was resident
    /// until the recording ended. Samples now go to disk as they arrive.
    var sink: SampleSink? { get set }
    // Peak |sample| since the last call, then reset — a cheap live-activity probe
    // for the app's silence auto-stop. The protocol default is 0, so a capturer that
    // does not implement it contributes no audio activity and detection leans on the
    // mic track alone.
    //
    // BOTH capturers here implement it. This comment used to name the tap as the one
    // that does not, which stopped being true when `SystemTap.takeLevelPeak()` was
    // added; a tap-mode run reports a real `sys=` level.
    func takeLevelPeak() -> Float
}

extension SystemCapturer {
    func takeLevelPeak() -> Float { 0 }
}
