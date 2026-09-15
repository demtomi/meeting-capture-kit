// ScreenPreset — the decisions behind a screen recording, with no ScreenCaptureKit,
// no AVFoundation and no TCC anywhere in the file.
//
// Split out for the same reason as SilenceGate and SpeakerNaming: these are the parts
// that can be wrong in ways a compiler cannot see, and they need to be replayable by
// `swift run screen-record-check` without launching the app or granting a permission.
// The executable maps ScreenCaptureKit's types into the plain structs below and calls
// in; everything decided here is decided on data, not on live system state.
//
// Two of these functions exist because they were measured being wrong:
//   fitBox        — SCDisplay reports POINTS. Scaling from points recorded a retina
//                   panel at 1512x982 while claiming 1080p. It takes pixels now.
//   resolveDisplay— `auto` matched an ordinary always-open Slack window and picked the
//                   wrong screen for the whole meeting, measured 2026-08-03.
import Foundation

public struct Rect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { width * height }
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

public struct DisplayInfo: Equatable, Sendable {
    public let id: UInt32
    /// Backing PIXELS, not points. The caller is responsible for asking CoreGraphics
    /// rather than passing SCDisplay.width/height straight through.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frame: Rect
    public let isBuiltin: Bool
    public init(id: UInt32, pixelWidth: Int, pixelHeight: Int, frame: Rect, isBuiltin: Bool) {
        self.id = id; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.frame = frame; self.isBuiltin = isBuiltin
    }
}

public struct WindowInfo: Equatable, Sendable {
    public let bundleID: String?
    public let appName: String?
    public let title: String?
    public let frame: Rect
    public let isOnScreen: Bool
    public init(bundleID: String?, appName: String?, title: String?, frame: Rect, isOnScreen: Bool) {
        self.bundleID = bundleID; self.appName = appName; self.title = title
        self.frame = frame; self.isOnScreen = isOnScreen
    }
}

public enum DisplayChoice: Equatable, Sendable {
    case auto
    case builtin
    case explicit(UInt32)

    /// Parses the `--display` argument. Unknown text is `auto` rather than an error:
    /// a stale display id in a remembered setting must degrade to a sane recording,
    /// never abort one.
    public static func parse(_ s: String?) -> DisplayChoice {
        guard let s, !s.isEmpty else { return .auto }
        if s == "builtin" { return .builtin }
        if s == "auto" { return .auto }
        if let n = UInt32(s) { return .explicit(n) }
        return .auto
    }
}

public struct DisplayPick: Equatable, Sendable {
    public let display: DisplayInfo
    /// How the choice was reached, written verbatim into the sidecar and shown to the host
    /// while the call runs, so a wrong `auto` is visible during the meeting, not after it.
    public let how: String
}

public enum ScreenPreset {

    // MARK: - Conference detection

    /// An entry here asserts "ANY window of this app is a call", which is only true for
    /// apps that exist solely to hold meetings.
    ///
    /// Slack is deliberately ABSENT. It was here, and a real run resolved
    /// `auto:Slack` from an ordinary Slack window that happened to be open, which on a
    /// multi-display desk silently records the wrong screen for the entire meeting. The
    /// app is not the call; the window is. Slack huddles match by title below.
    public static let conferenceBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
    ]

    /// Matched case-insensitively ANYWHERE in the window title. Browser-hosted calls
    /// live here, and so does the Slack huddle window.
    ///
    /// Case-insensitive on BOTH sides since the matcher lowercases each pattern as well
    /// as the title. It used to lowercase only the title, so an entry with a capital
    /// letter silently never matched — the trap a consumer writing `"Zoom Meeting"` into
    /// the JSON file fell into. The entries below stay lowercase by convention anyway.
    ///
    /// "zoom meeting" rather than "zoom": the bare word matches a browser tab about
    /// Zoom's pricing page as readily as a call.
    ///
    /// `meet.google.com` is kept but is close to dead weight: it is a URL, and a browser
    /// window title carries the PAGE TITLE, not the address. It was the only Google Meet
    /// rule here, and it never matched a real call — see `conferenceTitlePrefixes`.
    public static let conferenceTitleNeedles = [
        "meet.google.com", "google meet", "zoom meeting",
        "microsoft teams", "whereby", "webex", "huddle",
    ]

    /// Matched case-insensitively against the START of the window title.
    ///
    /// Google Meet forces this. A live Meet call in Chrome is titled
    /// `Meet – Weekly project sync` (measured 2026-08-06, en dash), and neither
    /// needle above can see it: `meet.google.com` is a URL, and `google meet` is not the
    /// string Meet uses. So every Google Meet call went undetected — on a Workspace
    /// account, that is most calls.
    ///
    /// A PREFIX, and never a bare `meet` needle, because `contains("meet")` matches
    /// "Quarterly review | **Meet**ing Notes | Acme" — a real window that was
    /// open on this desk while the bug was being diagnosed. Classifying a notes document
    /// as the call would put the screen recording, and every panel placed against that call,
    /// on the wrong display for an entire meeting, which is worse than the miss it fixes.
    ///
    /// All three dashes: the observed title uses an EN dash, and neither the hyphen nor
    /// the em dash costs anything to accept.
    public static let conferenceTitlePrefixes = [
        "meet – ", "meet - ", "meet — ",
    ]

    /// Windows too small to be a call are ignored: a Zoom control strip or a huddle
    /// mini-window is not where the meeting is being shown.
    public static let minConferenceWindowSize = (width: 200.0, height: 150.0)

    /// Which apps and window titles count as a call.
    ///
    /// Every field is data, not code, because the set of conferencing tools is not
    /// knowable in advance and a consumer must be able to add their own without
    /// forking. `.default` is the set this package ships with, and every rule in it
    /// carries the reason it is shaped that way in the comments above.
    ///
    /// Supply your own with `ConferenceDetection(...)`, or load one from disk with
    /// `ConferenceDetection.load(fromJSONAt:)` so it can be changed without a rebuild.
    public struct ConferenceDetection: Sendable, Codable, Equatable {
        /// Bundle IDs where ANY window is a call. Only correct for apps that exist
        /// solely to hold meetings, which is why a chat app must never be added here.
        public var bundleIDs: Set<String>
        /// Matched case-insensitively ANYWHERE in the window title. Case is handled for
        /// you: the matcher lowercases the pattern as well as the title.
        public var titleNeedles: [String]
        /// Matched case-insensitively against the START of the window title.
        public var titlePrefixes: [String]
        /// Windows smaller than this in either dimension are control strips, not calls.
        /// A window exactly at the minimum is a call: the comparison is `>=`.
        public var minWidth: Double
        public var minHeight: Double

        public init(bundleIDs: Set<String>,
                    titleNeedles: [String],
                    titlePrefixes: [String],
                    minWidth: Double,
                    minHeight: Double) {
            self.bundleIDs = bundleIDs
            self.titleNeedles = titleNeedles
            self.titlePrefixes = titlePrefixes
            self.minWidth = minWidth
            self.minHeight = minHeight
        }

        public static let `default` = ConferenceDetection(
            bundleIDs: ScreenPreset.conferenceBundleIDs,
            titleNeedles: ScreenPreset.conferenceTitleNeedles,
            titlePrefixes: ScreenPreset.conferenceTitlePrefixes,
            minWidth: ScreenPreset.minConferenceWindowSize.width,
            minHeight: ScreenPreset.minConferenceWindowSize.height
        )

        /// Load a configuration from a JSON file. Any field the file omits keeps the
        /// shipped default, so a user's file can name one extra app and nothing else.
        /// Throws only on unreadable or malformed JSON: a file that parses but sets
        /// nothing is a valid way to say "use the defaults".
        public static func load(fromJSONAt path: String) throws -> ConferenceDetection {
            let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            let partial = try JSONDecoder().decode(Partial.self, from: data)
            var c = ConferenceDetection.default
            if let v = partial.bundleIDs { c.bundleIDs = v }
            if let v = partial.titleNeedles { c.titleNeedles = v }
            if let v = partial.titlePrefixes { c.titlePrefixes = v }
            if let v = partial.minWidth { c.minWidth = v }
            if let v = partial.minHeight { c.minHeight = v }
            return c
        }

        private struct Partial: Codable {
            var bundleIDs: Set<String>?
            var titleNeedles: [String]?
            var titlePrefixes: [String]?
            var minWidth: Double?
            var minHeight: Double?
        }
    }

    /// `using:` defaults to the shipped set, so every existing call site keeps its
    /// behaviour and a consumer opts in to their own configuration explicitly.
    public static func isConferenceWindow(_ w: WindowInfo,
                                          using config: ConferenceDetection = .default) -> Bool {
        // `>=`, so a window EXACTLY at the minimum counts as a call. The comparison was
        // `>`, which contradicted the field's own documentation ("windows smaller than
        // this are control strips") and rejected a window at exactly 200x150.
        guard w.isOnScreen,
              w.frame.width >= config.minWidth,
              w.frame.height >= config.minHeight else { return false }
        if let b = w.bundleID, config.bundleIDs.contains(b) { return true }
        // BOTH sides are lowercased. Only the title used to be, so a pattern carrying a
        // capital letter could never match and did so silently — and the JSON extension
        // point is exactly where a caller writes `"Zoom Meeting"` and gets a no-op that
        // costs them the right screen for a whole meeting.
        let t = (w.title ?? "").lowercased()
        if config.titlePrefixes.contains(where: { t.hasPrefix($0.lowercased()) }) { return true }
        return config.titleNeedles.contains { t.contains($0.lowercased()) }
    }

    // MARK: - Display resolution

    /// Never returns nil when at least one display exists. Every failure path degrades
    /// to a real display, because refusing to record is a worse outcome than recording
    /// a display whose name the host can read back from `DisplayPick.how` and correct next
    /// time.
    public static func resolveDisplay(choice: DisplayChoice,
                                      displays: [DisplayInfo],
                                      windows: [WindowInfo],
                                      detecting config: ConferenceDetection = .default) -> DisplayPick? {
        guard !displays.isEmpty else { return nil }

        func builtinOrFirst(_ reason: String) -> DisplayPick {
            if let b = displays.first(where: { $0.isBuiltin }) {
                return DisplayPick(display: b, how: reason)
            }
            return DisplayPick(display: displays[0], how: "fallback:first")
        }

        switch choice {
        case .builtin:
            return builtinOrFirst("builtin")

        case .explicit(let id):
            if let d = displays.first(where: { $0.id == id }) {
                return DisplayPick(display: d, how: "explicit")
            }
            // A remembered display that has since been unplugged.
            return builtinOrFirst("fallback:unplugged")

        case .auto:
            let candidates = windows.filter { isConferenceWindow($0, using: config) }
            if let best = candidates.max(by: { $0.frame.area < $1.frame.area }) {
                if let d = displays.first(where: { $0.frame.contains(x: best.frame.midX,
                                                                     y: best.frame.midY) }) {
                    return DisplayPick(display: d, how: "auto:\(best.appName ?? "window")")
                }
            }
            return builtinOrFirst("builtin")
        }
    }

    // MARK: - Geometry

    /// Fits native PIXELS inside a long-edge x short-edge box, preserving aspect ratio
    /// and never upscaling. Returns even dimensions, which the HEVC encoder requires.
    ///
    /// A box rather than a height cap, because display 2 on this desk is a rotated
    /// portrait panel (1080x1920): a 1080 height cap would squeeze it to 607x1080 and
    /// discard half the resolution that already fits inside the box.
    public static func fitBox(pixelWidth: Int, pixelHeight: Int,
                              maxLong: Int, maxShort: Int) -> (width: Int, height: Int) {
        guard pixelWidth > 0, pixelHeight > 0, maxLong > 0, maxShort > 0 else { return (2, 2) }
        let longEdge = Double(max(pixelWidth, pixelHeight))
        let shortEdge = Double(min(pixelWidth, pixelHeight))
        let scale = min(1.0, Double(maxLong) / longEdge, Double(maxShort) / shortEdge)
        func even(_ v: Double) -> Int {
            let n = Int(v.rounded())
            return max(2, n % 2 == 0 ? n : n - 1)
        }
        return (even(Double(pixelWidth) * scale), even(Double(pixelHeight) * scale))
    }

    // MARK: - Disk

    /// Bytes per second the preset is expected to produce, used only for the preflight
    /// estimate. Deliberately pessimistic against the measured range (172-500
    /// MB/hour on near-static content) because a real meeting moves far more.
    public static func estimatedBytesPerSecond(bitrate: Int) -> Int { bitrate / 8 }

    public enum SpaceVerdict: Equatable, Sendable {
        case ok
        case refuse(freeMB: Int, needMB: Int)
    }

    /// Preflight before a single frame is captured. Refusing the VIDEO is always
    /// acceptable; the caller must never let this refuse the audio recording.
    public static func checkSpace(freeBytes: Int, bitrate: Int,
                                  plannedSeconds: Int, floorBytes: Int) -> SpaceVerdict {
        let need = estimatedBytesPerSecond(bitrate: bitrate) * plannedSeconds + floorBytes
        if freeBytes >= need { return .ok }
        return .refuse(freeMB: freeBytes / 1_048_576, needMB: need / 1_048_576)
    }

    // MARK: - Sidecar

    /// Written LAST and atomically, so its presence is the "this video is complete and
    /// playable" sentinel, the same way `meeting-capture` writes manifest.json last and
    /// atomically to mark a finished audio take. A .mov with no sidecar beside it is an
    /// interrupted take.
    ///
    /// Deliberately NOT part of manifest.json: that file's `tracks` map is what the
    /// upload path iterates, and a video must never be reachable from there.
    public struct Sidecar: Codable, Equatable, Sendable {
        public var schema: Int = 1
        public var id: String
        public var label: String
        public var startedAt: String
        public var displayID: UInt32
        public var displayHow: String
        public var width: Int
        public var height: Int
        public var fps: Int
        public var codec: String
        public var durationSeconds: Double
        public var bytes: Int
        public var framesWritten: Int
        public var framesSkippedUnchanged: Int
        public var framesDropped: Int
        public var truncatedReason: String?

        public init(id: String, label: String, startedAt: String, displayID: UInt32,
                    displayHow: String, width: Int, height: Int, fps: Int, codec: String,
                    durationSeconds: Double, bytes: Int, framesWritten: Int,
                    framesSkippedUnchanged: Int, framesDropped: Int, truncatedReason: String?) {
            self.id = id; self.label = label; self.startedAt = startedAt
            self.displayID = displayID; self.displayHow = displayHow
            self.width = width; self.height = height; self.fps = fps; self.codec = codec
            self.durationSeconds = durationSeconds; self.bytes = bytes
            self.framesWritten = framesWritten
            self.framesSkippedUnchanged = framesSkippedUnchanged
            self.framesDropped = framesDropped
            self.truncatedReason = truncatedReason
        }

        public func encoded() throws -> Data {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try e.encode(self)
        }
    }
}
