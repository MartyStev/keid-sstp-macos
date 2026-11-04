import Foundation
import Observation
import ServiceManagement
import SSTPCore

/// App state: helper status, connect/disconnect, automatic reconnection and
/// the settings shown in the Settings window.
@MainActor
@Observable
final class ConnectionModel {
    enum Setup: Equatable {
        /// No helper or no server yet — the user has to open Settings.
        case needsSettings
        /// The installed helper is older than the one in this app.
        case needsUpdate
        case ready
    }

    private(set) var status = HelperStatus()
    private(set) var isBusy = false
    private(set) var setup: Setup = .needsSettings
    var lastError = ""
    var log = ""

    // The settings the helper has (the password is never stored by the app).
    // They change only when saving through the administrator prompt worked;
    // the Settings window edits a draft.
    private(set) var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    private(set) var login: String { didSet { defaults.set(login, forKey: Keys.login) } }
    private(set) var verifyCertificate: Bool { didSet { defaults.set(verifyCertificate, forKey: Keys.verify) } }
    private(set) var blockIPv6: Bool { didSet { defaults.set(blockIPv6, forKey: Keys.block6) } }
    /// App-only, apply at once.
    var autoReconnect: Bool {
        didSet {
            defaults.set(autoReconnect, forKey: Keys.reconnect)
            // a retry already scheduled must not happen after all
            if !autoReconnect { cancelReconnect() }
        }
    }
    var showNotifications: Bool { didSet { defaults.set(showNotifications, forKey: Keys.notify) } }
    private(set) var hasSavedServer: Bool { didSet { defaults.set(hasSavedServer, forKey: Keys.saved) } }
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Bytes through the tunnel interface while connected.
    private(set) var traffic: TrafficCounters?
    /// The panel is open: poll often so it stays current.
    var isPanelVisible = false {
        didSet { if isPanelVisible != oldValue { pokePolling() } }
    }

    /// The user asked to be connected; drives automatic reconnection.
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    /// Bumped by every helper command, so a status read before or during a
    /// command (a slow poll) cannot overwrite what the command did.
    private var commandGeneration = 0
    private var hasStatus = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// The tunnel dropped and is being brought back (for the "restored" notice).
    private var isRecovering = false
    private var isNetworkAvailable = true
    private let systemEvents = SystemEvents()
    private let policy = ReconnectPolicy()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let host = "host", login = "login", verify = "verifyCertificate"
        static let block6 = "blockIPv6", reconnect = "autoReconnect", saved = "hasSavedServer"
        static let notify = "showNotifications"
    }

    init() {
        host = defaults.string(forKey: Keys.host) ?? ""
        login = defaults.string(forKey: Keys.login) ?? ""
        verifyCertificate = defaults.object(forKey: Keys.verify) as? Bool ?? true
        blockIPv6 = defaults.object(forKey: Keys.block6) as? Bool ?? true
        autoReconnect = defaults.object(forKey: Keys.reconnect) as? Bool ?? true
        hasSavedServer = defaults.bool(forKey: Keys.saved)
        showNotifications = defaults.object(forKey: Keys.notify) as? Bool ?? true
        startPolling()
        systemEvents.start(
            onNetworkChange: { [weak self] isAvailable in self?.networkChanged(isAvailable) },
            onWake: { [weak self] in Task { await self?.reconnectNow() } }
        )
    }

    var canConnect: Bool { setup == .ready && !isBusy }

    /// The helper command in flight, if any.
    private(set) var runningCommand: HelperClient.Command?
    private(set) var isCancelling = false

    /// A connect is in progress and can still be stopped.
    var canCancel: Bool { runningCommand == .up && !isCancelling }

    /// The helper's firewall blocks all traffic outside the tunnel, and no
    /// tunnel is up (a drop, a failed connect). Only Disconnect unblocks.
    var isBlocked: Bool { status.state == .dropped }

    /// Blocked, and the app is bringing the tunnel back (only with automatic
    /// reconnection on; otherwise it waits for Connect or Disconnect).
    var isReconnecting: Bool { isBlocked && wantsConnection && autoReconnect }

    // MARK: - Status

    /// Polls at the pace PollingPolicy picks for the current situation.
    /// - Parameter pollFirst: false when the status was just read.
    private func startPolling(pollFirst: Bool = true) {
        pollTask = Task { [weak self] in
            var shouldPoll = pollFirst
            while !Task.isCancelled {
                if shouldPoll { await self?.refresh() }
                shouldPoll = true
                guard let interval = self?.pollInterval else { return }
                // cancelled by pokePolling: the loop restarts with a fresh poll
                try? await Task.sleep(for: interval)
            }
        }
    }

    private var pollInterval: Duration {
        PollingPolicy.interval(
            state: status.state, isBusy: isBusy,
            isReconnecting: isReconnecting || reconnectTask != nil,
            isPanelVisible: isPanelVisible
        )
    }

    /// Something changed (the panel opened, the network, a command ended):
    /// poll now and pick the pace again, instead of finishing a long sleep.
    private func pokePolling(pollNow: Bool = true) {
        pollTask?.cancel()
        startPolling(pollFirst: pollNow)
    }

    /// One status read at a time: a second caller (the panel opened while the
    /// poll was reading) waits for the read in flight instead of starting
    /// another sudo.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await readStatus() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func readStatus() async {
        guard !isBusy else { return }
        let generation = commandGeneration
        // nil: not readable this time; keep what is known
        guard let next = await HelperClient.status() else { return }
        // a command started while the status was being read: it is stale
        guard !isBusy, generation == commandGeneration else { return }
        apply(next)
        await updateTraffic()
    }

    private func updateTraffic() async {
        guard status.state == .connected, !status.interface.isEmpty else {
            traffic = nil
            return
        }
        traffic = await InterfaceStats.read(status.interface)
    }

    // MARK: - Network and wake

    private func networkChanged(_ isAvailable: Bool) {
        let cameBack = isAvailable && !isNetworkAvailable
        isNetworkAvailable = isAvailable
        if cameBack {
            Task { await reconnectNow() }
        } else {
            // a lost network or a new interface: a drop shows at once even
            // while polling is slow
            pokePolling()
        }
    }

    /// The network came back or the Mac woke up: a dropped tunnel is tried
    /// now, not after the back-off (traffic is blocked meanwhile).
    func reconnectNow() async {
        // after sleep the last status may still say "connected"
        await refresh()
        guard isNetworkAvailable, !isBusy,
              StatusPolicy.reconnectsNow(state: status.state, wantsConnection: wantsConnection, autoReconnect: autoReconnect)
        else { return }
        cancelReconnect()
        reconnectAttempt = 0
        await connect()
    }

    private func apply(_ next: HelperStatus) {
        let notice = NoticePolicy.notice(
            previous: status.state, next: next.state,
            wantsConnection: wantsConnection, recovering: isRecovering
        )
        let reaction = StatusPolicy.reaction(
            previous: status.state, next: next.state, isFirstStatus: !hasStatus,
            wantsConnection: wantsConnection, autoReconnect: autoReconnect,
            helperVersion: next.helperVersion
        )
        hasStatus = true
        status = next
        setup = Self.setup(for: next, hasSavedServer: hasSavedServer)

        if notice == .lost { isRecovering = true }
        if next.state == .connected || !wantsConnection { isRecovering = false }
        if let notice, showNotifications { Notifier.post(notice) }

        switch reaction {
        case .connected(let adopt):
            reconnectAttempt = 0
            // a tunnel found at launch: keep it up
            if adopt { wantsConnection = true }
        case .reconnect:
            // a dropped session keeps its kill-switch until `up` succeeds
            scheduleReconnect()
        case .cleanUp:
            Task { await self.cleanUpDroppedSession() }
        case .cleanUpAndReconnect:
            Task {
                await self.cleanUpDroppedSession()
                self.scheduleReconnect()
            }
        case .none:
            break
        }
    }

    private static func setup(for status: HelperStatus, hasSavedServer: Bool) -> Setup {
        guard HelperClient.isInstalled, hasSavedServer, status.state != .unavailable else { return .needsSettings }
        if let installed = status.helperVersion, let bundled = HelperPaths.bundledHelperVersion, installed < bundled {
            return .needsUpdate
        }
        return .ready
    }

    // MARK: - Connect / disconnect

    func toggleConnection() async {
        switch status.state {
        case .connected, .connecting:
            wantsConnection = false
            cancelReconnect()
            await perform(.down)
        case .dropped where isReconnecting:
            // reconnecting behind the kill-switch: stop and unblock traffic
            await unblock()
        default:
            wantsConnection = true
            reconnectAttempt = 0
            cancelReconnect()
            await connect()
        }
    }

    /// Disconnect: ends any session and turns the firewall off.
    func unblock() async {
        wantsConnection = false
        cancelReconnect()
        await perform(.down)
    }

    /// Stops a connect in progress. The helper's `down` ends the running `up`
    /// and turns the firewall off; `up` then returns and the status is read.
    func cancelConnect() async {
        guard canCancel else { return }
        isCancelling = true
        wantsConnection = false
        cancelReconnect()
        let result = await HelperClient.run(.down)
        if !result.succeeded { lastError = HelperClient.explain(result.output) }
    }

    private func connect() async {
        // One `up` at a time (the helper also refuses a second one).
        guard !isBusy else { return }
        let result = await perform(.up)
        guard !result.succeeded else { return }
        if HelperClient.isAuthenticationFailure(result.output) {
            // Retrying a wrong password only risks locking the account.
            wantsConnection = false
            isRecovering = false
            cancelReconnect()
            if showNotifications { Notifier.post(.loginRejected) }
        } else if wantsConnection, autoReconnect {
            scheduleReconnect()
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    @discardableResult
    private func perform(_ command: HelperClient.Command) async -> CommandResult {
        beginCommand()
        runningCommand = command
        lastError = ""
        if command == .up { status.state = .connecting }
        let result = await HelperClient.run(command)
        // a cancelled connect fails on purpose: no error to show
        if !result.succeeded && !isCancelling {
            lastError = HelperClient.explain(result.output)
        }
        runningCommand = nil
        isCancelling = false
        isBusy = false
        let generation = commandGeneration
        let next = await HelperClient.status()
        // a newer command (a click, the reconnect timer) owns the state now
        if let next, generation == commandGeneration { apply(next) }
        // the status was just read: only pick the pace again
        pokePolling(pollNow: false)
        return result
    }

    private func beginCommand() {
        isBusy = true
        commandGeneration += 1
    }

    private func cleanUpDroppedSession() async {
        guard !isBusy else { return }
        await perform(.down)
    }

    private func scheduleReconnect() {
        guard autoReconnect, wantsConnection, reconnectTask == nil else { return }
        let delay = policy.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.wantsConnection, self.autoReconnect,
                  self.status.state != .connected, self.status.state != .connecting else { return }
            // another command is running, or there is no network yet (its
            // return reconnects at once): try again later instead of giving up
            guard !self.isBusy, self.isNetworkAvailable else { return self.scheduleReconnect() }
            await self.connect()
        }
    }

    func loadLog() async {
        log = await HelperClient.run(.log).output
    }

    // MARK: - Settings

    /// The settings as saved, for the Settings window to start its draft from.
    var savedSettings: ServerSettings {
        ServerSettings(host: host, login: login, password: "", verifyCertificate: verifyCertificate, blockIPv6: blockIPv6)
    }

    /// Saves the server through the administrator prompt (also installs or
    /// updates the helper). Returns an error message, or nil on success.
    func saveSettings(_ draft: ServerSettings) async -> String? {
        let settings = draft.normalized
        let canKeepPassword = hasSavedServer && HelperClient.isInstalled
        if let problem = settings.problems(hasSavedPassword: canKeepPassword).first {
            return Self.describe(problem)
        }
        guard !isBusy else { return String(localized: "Wait until the current operation finishes.") }
        // the installer stops the tunnel; a cancelled or failed prompt leaves
        // it as it was, so the wish to be connected comes back too
        let wanted = wantsConnection
        wantsConnection = false
        cancelReconnect()
        beginCommand()
        defer { isBusy = false }
        do {
            try await PrivilegedInstaller.install(settings, hasSavedPassword: canKeepPassword)
        } catch {
            wantsConnection = wanted
            return error.localizedDescription
        }
        host = settings.host
        login = settings.login
        verifyCertificate = settings.verifyCertificate
        blockIPv6 = settings.blockIPv6
        hasSavedServer = true
        if let next = await HelperClient.status() { apply(next) }
        return nil
    }

    func uninstallHelper() async -> String? {
        guard !isBusy else { return String(localized: "Wait until the current operation finishes.") }
        let wanted = wantsConnection
        wantsConnection = false
        cancelReconnect()
        beginCommand()
        defer { isBusy = false }
        do {
            try await PrivilegedInstaller.uninstall()
        } catch {
            wantsConnection = wanted
            return error.localizedDescription
        }
        hasSavedServer = false
        if let next = await HelperClient.status() { apply(next) }
        return nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = String(localized: "Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func describe(_ problem: ServerSettings.Problem) -> String {
        switch problem {
        case .hostEmpty: String(localized: "Enter the server address.")
        case .hostInvalidCharacters: String(localized: "The server address may contain only letters, digits, dots, dashes and :port, and must start with a letter or a digit.")
        case .portInvalid: String(localized: "The port must be a number from 1 to 65535.")
        case .loginEmpty: String(localized: "Enter the login.")
        case .passwordEmpty: String(localized: "Enter the password.")
        case .passwordTooLong: String(localized: "The password is too long: at most 128 bytes (64 Cyrillic letters).")
        case .passwordHasUnsupportedCharacter: String(localized: "The password cannot contain a double quote (\") or a backslash (\\).")
        case .containsNewline: String(localized: "Fields cannot contain line breaks.")
        }
    }
}
