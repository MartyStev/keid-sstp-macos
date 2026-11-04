import AppKit
import Foundation
import os
import SSTPCore

/// Paths shared with helper/install-helper.sh.
enum HelperPaths {
    static let helper = "/Library/PrivilegedHelperTools/sstp-mac-client/sstp-helper"

    static var resources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: "/") }
    static var bundledHelper: URL { resources.appendingPathComponent("sstp-helper") }
    static var installer: URL { resources.appendingPathComponent("install-helper.sh") }

    /// Read once: the bundle does not change while the app runs, and the
    /// status poll asks for it every few seconds.
    static let bundledHelperVersion: Int? =
        (try? String(contentsOf: bundledHelper, encoding: .utf8)).flatMap(HelperScript.version(inScript:))
}

struct CommandResult: Sendable {
    let succeeded: Bool
    let output: String
}

/// Runs a process and collects stdout + stderr. The blocking wait happens on
/// a dispatch queue, not on Swift's cooperative pool, and a process that
/// does not finish in `timeout` seconds is terminated, so a hung sudo or
/// helper cannot leave the app busy forever.
enum ProcessRunner {
    /// Helper error key (translated in Localizable.strings).
    static let timeoutError = "the helper did not answer in time"

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(succeeded: false, output: "error=\(error.localizedDescription)")
        }
        // sudo passes SIGTERM on to the helper
        let pid = process.processIdentifier
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            kill(pid, SIGTERM)
        }
        // still there 3 s after SIGTERM: it is not coming back on its own
        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 3, execute: killer)
        // Output is collected as it comes and the wait is on the process, not
        // on the end of the pipe: a killed sudo leaves its root child (which
        // a user process cannot kill) holding the pipe open.
        let handle = pipe.fileHandleForReading
        let buffer = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                buffer.withLock { $0.append(chunk) }
            }
        }
        process.waitUntilExit()
        watchdog.cancel()
        killer.cancel()
        // the end of the output follows the exit at once, unless something
        // still holds the pipe
        if drained.wait(timeout: .now() + 2) == .timedOut { handle.readabilityHandler = nil }
        let data = buffer.withLock { $0 }
        let output = String(decoding: data, as: UTF8.self)
        if timedOut.withLock({ $0 }) {
            return CommandResult(succeeded: false, output: "error=\(timeoutError)\n" + output)
        }
        return CommandResult(succeeded: process.terminationStatus == 0, output: output)
    }
}

/// Byte counters of an interface (`netstat` needs no privileges).
enum InterfaceStats {
    static func read(_ interface: String) async -> TrafficCounters? {
        let result = await ProcessRunner.run("/usr/sbin/netstat", ["-ibn", "-I", interface], timeout: 5)
        return result.succeeded ? TrafficCounters.parse(netstat: result.output) : nil
    }
}

/// The unprivileged side: `sudo -n sstp-helper <command>`. sudoers allows
/// exactly up/down/status/log without a password.
enum HelperClient {
    enum Command: String {
        case up, down, status, log

        /// Seconds before the command counts as hung. `up` waits up to 30 s
        /// for the tunnel (UP_TIMEOUT in the helper) plus cleanup.
        var timeout: TimeInterval {
            switch self {
            case .up: 75
            case .down: 30
            case .status, .log: 15
            }
        }
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: HelperPaths.helper) }

    static func run(_ command: Command) async -> CommandResult {
        await ProcessRunner.run("/usr/bin/sudo", ["-n", HelperPaths.helper, command.rawValue], timeout: command.timeout)
    }

    /// The helper's status, or nil when it could not be read this time (a
    /// timeout, sudo busy right after wake): the caller keeps the last one
    /// instead of showing "not set up" while the firewall may be on.
    static func status() async -> HelperStatus? {
        guard isInstalled else { return HelperStatus(state: .unavailable) }
        let result = await run(.status)
        var status = HelperStatus.parse(result.output)
        guard !result.succeeded, status.state == .unavailable else { return status }
        // the sudo rule is missing: really not set up for this user
        guard result.output.contains("a password is required") else { return nil }
        status.error = explain(result.output)
        return status
    }

    /// Turns sudo/helper output into something a user can act on.
    static func isAuthenticationFailure(_ raw: String) -> Bool {
        HelperStatus.parse(raw).isAuthenticationFailure
    }

    static func explain(_ raw: String) -> String {
        if raw.contains("a password is required") {
            return String(localized: "The helper is not set up for this user. Open Settings and save.")
        }
        if isAuthenticationFailure(raw) {
            return String(localized: "The server rejected the login or password. Check them in Settings.")
        }
        let status = HelperStatus.parse(raw)
        // the helper speaks English; known messages have translations
        if !status.error.isEmpty { return Bundle.main.localizedString(forKey: status.error, value: nil, table: nil) }
        // not from the helper (sudo, the system): its own words, in a
        // sentence in the app's language
        let last = raw.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return last.isEmpty ? String(localized: "Unknown error") : String(localized: "Unexpected error: \(last)")
    }
}

/// The privileged side: install-helper.sh through the standard administrator
/// prompt. Used for installing, updating, changing settings and uninstalling.
enum PrivilegedInstaller {
    enum Failure: Error, LocalizedError {
        case cancelled
        case invalidSettings
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: String(localized: "Cancelled.")
            case .invalidSettings: String(localized: "Check the server settings.")
            case .failed(let message): message
            }
        }
    }

    static func install(_ settings: ServerSettings, hasSavedPassword: Bool) async throws(Failure) {
        guard let contents = settings.settingsFileContents(hasSavedPassword: hasSavedPassword) else {
            throw .invalidSettings
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sstp-settings-\(UUID().uuidString)")
        // 0600 before any secret is written
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file) else {
            throw .failed(String(localized: "Could not create a temporary file."))
        }
        handle.write(Data(contents.utf8))
        try? handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        try await runAsAdmin(["install", HelperPaths.resources.path, file.path, NSUserName()])
    }

    static func uninstall() async throws(Failure) {
        try await runAsAdmin(["uninstall"])
    }

    private static func runAsAdmin(_ arguments: [String]) async throws(Failure) {
        let source = AdminScript.source(
            executable: "/bin/sh",
            arguments: [HelperPaths.installer.path] + arguments,
            prompt: String(localized: "Keid needs administrator rights to set up its network helper.")
        )
        // NSAppleScript belongs on the main thread, so the UI waits while the
        // prompt is open (the install itself takes under a second). Running
        // /usr/bin/osascript instead would free the UI, but the prompt would
        // then name "osascript" instead of this app — worse for a password
        // prompt that users should be able to trust.
        let outcome: Result<String, Failure> = await MainActor.run {
            var errorInfo: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                // -128: the user pressed Cancel in the password prompt
                if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return .failure(.cancelled) }
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? String(localized: "The administrator prompt failed.")
                return .failure(.failed(HelperClient.explain(message)))
            }
            return .success(output?.stringValue ?? "")
        }
        switch outcome {
        case .success(let text) where AdminScript.succeeded(output: text):
            return
        case .success(let text):
            throw .failed(HelperClient.explain(text))
        case .failure(let failure):
            throw failure
        }
    }
}
