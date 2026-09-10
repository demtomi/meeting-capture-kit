// swift-tools-version: 6.0
import PackageDescription

// MeetingCaptureKit — dual-track meeting audio capture on macOS.
//
// Six library/CLI targets and five runnable verification executables. Every check
// runs with no microphone grant, no screen-recording grant, no display and no
// network, which is what lets the whole suite run on a CI runner.
let package = Package(
    name: "MeetingCaptureKit",
    // 14.2 is the floor set by `AudioHardwareCreateProcessTap`, which the system-audio
    // path needs. It was 26.0, which was the development machine's version rather than a
    // measured requirement, and it locked out every Mac more than two releases old.
    //
    // VERIFIED: the package builds clean and all five verification executables exit 0 at
    // this deployment target. NOT VERIFIED: that the process tap behaves correctly at
    // RUNTIME on 14.2. That was compiled on macOS 26 and never run on 14.x. The pure
    // logic targets carry no such doubt, since they touch no system audio at all.
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "LiveAudio", targets: ["LiveAudio"]),
        .library(name: "SilenceGate", targets: ["SilenceGate"]),
        .library(name: "ScreenPreset", targets: ["ScreenPreset"]),
        .library(name: "SpeakerNaming", targets: ["SpeakerNaming"]),
        .library(name: "MeetingPresence", targets: ["MeetingPresence"]),
        .library(name: "CaptureIO", targets: ["CaptureIO"]),
        .executable(name: "meeting-capture", targets: ["MeetingCaptureCLI"]),
    ],
    targets: [
        // Dual-track capture CLI: Core Audio process tap (system audio) plus
        // AVCaptureSession (microphone), written as separate 16 kHz mono PCM WAVs
        // with a manifest. No bot joins the call and nothing leaves the machine.
        //
        // Swift 5 language mode: this CLI bridges async ScreenCaptureKit and
        // AVFoundation calls to a synchronous main via semaphores. Swift 6
        // strict-concurrency flags those safe patterns as data races.
        // The audio pipeline is its own target so it can be verified without a device.
        // It lived inside the CLI executable, where no check could import it, which is
        // why the one path every user runs was the only path with no coverage.
        .target(name: "CaptureIO", path: "Sources/CaptureIO"),
        .executableTarget(
            name: "MeetingCaptureCLI",
            dependencies: ["CaptureIO", "SilenceGate"],
            path: "Sources/MeetingCaptureCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure transcript speaker-relabeling. Its own library so it is verifiable
        // without launching anything or touching a TCC-gated capture path.
        .target(name: "SpeakerNaming", path: "Sources/SpeakerNaming"),
        // The "should this recording still be running?" decision, replayable against
        // a real level trace with no app launch and no TCC grant. It guards billed
        // transcription minutes and the meeting record, on invariants no compiler
        // can check.
        .target(name: "SilenceGate", path: "Sources/SilenceGate"),
        // The decisions behind a screen recording: display resolution, geometry,
        // disk preflight, sidecar shape. No ScreenCaptureKit and no TCC, because
        // these are wrong in ways a compiler cannot see and must be replayable.
        .target(name: "ScreenPreset", path: "Sources/ScreenPreset"),
        // The live path's audio arithmetic: streaming resampler, mixer, bounded PCM
        // ring, drop accounting. A resampler that drifts over an hour, a ring that
        // blocks the audio callback and a mixer that wraps a loud passage are all
        // invisible to the compiler and all replayable with nothing plugged in.
        .target(name: "LiveAudio", path: "Sources/LiveAudio"),
        // Call-presence and panel-anchoring rules over window geometry.
        .target(name: "MeetingPresence", dependencies: ["ScreenPreset"], path: "Sources/MeetingPresence"),

        // ---- runnable verification -------------------------------------------
        // Plain executables rather than test targets: a machine with only the
        // Command Line Tools has no XCTest to link against, and these must run
        // there and on a CI runner unchanged.
        .executableTarget(
            name: "silence-gate-check",
            dependencies: ["SilenceGate"],
            path: "Sources/silence-gate-check"
        ),
        .executableTarget(
            name: "speaker-naming-check",
            dependencies: ["SpeakerNaming"],
            path: "Sources/speaker-naming-check"
        ),
        .executableTarget(
            name: "screen-record-check",
            dependencies: ["ScreenPreset"],
            path: "Sources/screen-record-check"
        ),
        .executableTarget(
            name: "meeting-presence-check",
            dependencies: ["MeetingPresence", "ScreenPreset"],
            path: "Sources/meeting-presence-check"
        ),
        .executableTarget(
            name: "audio-pipeline-check",
            dependencies: ["CaptureIO"],
            path: "Sources/audio-pipeline-check",
            // Same reason as the capture CLI: straight-line top-level script code that
            // Swift 6 strict concurrency reads as actor-isolated mutation.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "live-audio-check",
            dependencies: ["LiveAudio"],
            path: "Sources/live-audio-check"
        ),
    ]
)
