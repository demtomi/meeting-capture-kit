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
    // for the app's silence auto-stop. Default 0 (treated as silent) so a capturer
    // that doesn't implement it (the tap fallback) simply doesn't contribute audio
    // activity; detection then leans on the mic track alone.
    func takeLevelPeak() -> Float
}

extension SystemCapturer {
    func takeLevelPeak() -> Float { 0 }
}
