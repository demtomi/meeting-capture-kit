// Where the API key comes from.
//
// The Keychain is read by running /usr/bin/security, NOT through SecItemCopyMatching in
// this binary. Every ad-hoc-signed rebuild changes this binary's code identity, so an item
// that trusted the last build would pop a GUI access prompt at an unattended worker. The
// item's access list trusts /usr/bin/security, which does not change.
//
// ELEVENLABS_API_KEY from the environment is a fallback for interactive runs only, when
// stdin is a terminal. The worker never has one, and its plist never carries a key.
import Foundation

public enum KeySource {
    public static let service = "meeting-capture-elevenlabs"
    public static let addCommand = "security add-generic-password -s \(service) -a \"$USER\" -w"

    public enum Result: Equatable {
        case found(String, from: String)
        case missing(String)
    }

    /// Runs `security find-generic-password -s <service> -w`. nil when absent or refused.
    public static func keychain(securityPath: String = "/usr/bin/security") -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: securityPath)
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let k = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    public static var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               interactive: Bool = stdinIsTerminal,
                               securityPath: String = "/usr/bin/security") -> Result {
        if let k = keychain(securityPath: securityPath) { return .found(k, from: "Keychain item \(service)") }
        if interactive, let k = environment["ELEVENLABS_API_KEY"], !k.isEmpty {
            return .found(k, from: "ELEVENLABS_API_KEY (interactive run)")
        }
        return .missing("no key in the Keychain item \(service). Add it with: \(addCommand)")
    }
}
