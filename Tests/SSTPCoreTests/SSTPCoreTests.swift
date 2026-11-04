import Foundation
import Testing
@testable import SSTPCore

@Suite("HelperStatus")
struct HelperStatusTests {
    @Test("parses a connected status")
    func parsesConnected() {
        let status = HelperStatus.parse("""
        state=connected
        if=ppp0
        addr=172.16.3.33
        peer=192.168.1.1
        since=1793745613
        version=1
        """)
        #expect(status.state == .connected)
        #expect(status.interface == "ppp0")
        #expect(status.address == "172.16.3.33")
        #expect(status.peer == "192.168.1.1")
        #expect(status.connectedSince == Date(timeIntervalSince1970: 1_793_745_613))
        #expect(status.helperVersion == 1)
    }

    @Test("an unknown or missing state means the helper is unavailable")
    func unknownState() {
        #expect(HelperStatus.parse("").state == .unavailable)
        #expect(HelperStatus.parse("state=weird").state == .unavailable)
        #expect(HelperStatus.parse("sudo: a password is required").state == .unavailable)
    }

    @Test("keeps the first value of a repeated key and reads errors")
    func firstValueWins() {
        let status = HelperStatus.parse("error=could not connect\nstate=disconnected\nstate=connected")
        #expect(status.state == .disconnected)
        #expect(status.error == "could not connect")
    }

    @Test("a rejected login is recognised by its code, and by the old message")
    func authenticationFailure() {
        let coded = HelperStatus.parse("error_code=auth\nerror=whatever the wording is now")
        #expect(coded.errorCode == "auth")
        #expect(coded.isAuthenticationFailure)
        // helpers older than version 5 only print the message
        #expect(HelperStatus.parse("error=authentication failed").isAuthenticationFailure)
        #expect(!HelperStatus.parse("error=could not connect — see the log").isAuthenticationFailure)
        #expect(!HelperStatus.parse("state=disconnected").isAuthenticationFailure)
    }

    @Test("zero or garbage 'since' is no date")
    func since() {
        #expect(HelperStatus.parse("state=connected\nsince=0").connectedSince == nil)
        #expect(HelperStatus.parse("state=connected\nsince=abc").connectedSince == nil)
    }

    @Test("reads HELPER_VERSION from the helper script")
    func scriptVersion() {
        #expect(HelperScript.version(inScript: "#!/bin/sh\nset -eu\nHELPER_VERSION=3\nBASE=/x") == 3)
        #expect(HelperScript.version(inScript: "#!/bin/sh\n") == nil)
    }
}

@Suite("ServerSettings")
struct ServerSettingsTests {
    private func settings(host: String = "vpn.example.com", login: String = "alex", password: String = "secret") -> ServerSettings {
        ServerSettings(host: host, login: login, password: password)
    }

    @Test("valid settings have no problems")
    func valid() {
        #expect(settings().problems(hasSavedPassword: false).isEmpty)
        #expect(settings(host: "203.0.113.7:4443").problems(hasSavedPassword: false).isEmpty)
    }

    @Test("host is validated", arguments: [
        ("", ServerSettings.Problem.hostEmpty),
        ("   ", .hostEmpty),
        ("vpn example.com", .hostInvalidCharacters),
        ("vpn.example.com;rm", .hostInvalidCharacters),
        ("https://vpn.example.com", .hostInvalidCharacters),
        ("vpn.example.com:0", .portInvalid),
        ("vpn.example.com:70000", .portInvalid),
        ("vpn.example.com:", .portInvalid),
        // sstpc would read these as command line options
        ("-vpn.example.com", .hostInvalidCharacters),
        ("--help", .hostInvalidCharacters),
        (".example.com", .hostInvalidCharacters),
    ])
    func hostProblems(host: String, expected: ServerSettings.Problem) {
        #expect(settings(host: host).problems(hasSavedPassword: false).contains(expected))
    }

    @Test("an empty password is fine only when one is saved")
    func emptyPassword() {
        #expect(settings(password: "").problems(hasSavedPassword: false) == [.passwordEmpty])
        #expect(settings(password: "").problems(hasSavedPassword: true).isEmpty)
    }

    @Test("rejects double quotes and backslashes in the password and newlines anywhere")
    func passwordCharacters() {
        #expect(settings(password: "a\"b").problems(hasSavedPassword: false) == [.passwordHasUnsupportedCharacter])
        #expect(settings(password: "a\\b").problems(hasSavedPassword: false) == [.passwordHasUnsupportedCharacter])
        #expect(settings(login: "a\nb").problems(hasSavedPassword: false) == [.containsNewline])
        #expect(settings(password: "a\nb").problems(hasSavedPassword: false) == [.containsNewline])
    }

    @Test("limits the password to what sstpc's buffer holds")
    func passwordLength() {
        let longest = String(repeating: "a", count: ServerSettings.maxPasswordBytes)
        #expect(settings(password: longest).problems(hasSavedPassword: false).isEmpty)
        #expect(settings(password: longest + "a").problems(hasSavedPassword: false) == [.passwordTooLong])
        // bytes, not characters: "ж" is two bytes in UTF-8
        let cyrillic = String(repeating: "ж", count: ServerSettings.maxPasswordBytes / 2 + 1)
        #expect(settings(password: cyrillic).problems(hasSavedPassword: false) == [.passwordTooLong])
    }

    @Test("allows the special characters sstpc can handle")
    func specialPassword() {
        #expect(settings(password: #"p'a ss&$x ;|%"#).problems(hasSavedPassword: false).isEmpty)
        #expect(settings(login: #"DOMAIN\user"#).problems(hasSavedPassword: false).isEmpty)
    }

    @Test("renders the installer file with trimmed host and login")
    func fileContents() {
        let file = ServerSettings(host: " vpn.example.com ", login: " alex ", password: " pw ", verifyCertificate: false, blockIPv6: true)
            .settingsFileContents(hasSavedPassword: false)
        #expect(file == "SSTP_HOST=vpn.example.com\nSSTP_USER=alex\nSSTP_PASS= pw \nVERIFY_CERT=0\nBLOCK_IPV6=1\n")
    }

    @Test("invalid settings render no file")
    func noFileWhenInvalid() {
        #expect(settings(host: "").settingsFileContents(hasSavedPassword: false) == nil)
    }
}

@Suite("AdminScript")
struct AdminScriptTests {
    @Test("shell quoting survives single quotes")
    func shellQuote() {
        #expect(AdminScript.shellQuote("a'b") == #"'a'\''b'"#)
        #expect(AdminScript.shellQuote("/Applications/My Apps/Keid.app") == "'/Applications/My Apps/Keid.app'")
    }

    @Test("AppleScript literal escapes quotes and backslashes")
    func literal() {
        #expect(AdminScript.appleScriptLiteral(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }

    @Test("builds the administrator prompt script")
    func source() {
        let script = AdminScript.source(executable: "/bin/sh", arguments: ["/A B/install.sh", "install"], prompt: "Need rights")
        #expect(script == #"do shell script "'/bin/sh' '/A B/install.sh' 'install'" with prompt "Need rights" with administrator privileges"#)
    }

    @Test("success is an 'ok' last line, not any 'ok' inside the output", arguments: [
        ("ok", true),
        ("ok\n", true),
        ("installing\rok\r", true),
        ("  ok  ", true),
        ("broken", false),
        ("token expired", false),
        ("ok\nerror=sudoers rule failed validation", false),
        ("", false),
    ])
    func succeeded(output: String, expected: Bool) {
        #expect(AdminScript.succeeded(output: output) == expected)
    }
}

@Suite("StatusPolicy")
struct StatusPolicyTests {
    private func reaction(
        from previous: ConnectionState = .disconnected, to next: ConnectionState,
        first: Bool = false, wants: Bool = true, auto: Bool = true
    ) -> StatusReaction {
        StatusPolicy.reaction(
            previous: previous, next: next, isFirstStatus: first,
            wantsConnection: wants, autoReconnect: auto
        )
    }

    @Test("a tunnel found at launch is adopted, a later one is not")
    func adoptsOnlyAtLaunch() {
        #expect(reaction(to: .connected, first: true, wants: false) == .connected(adopt: true))
        // a stale poll after Disconnect must not turn reconnection back on
        #expect(reaction(to: .connected, first: false, wants: false) == .connected(adopt: false))
    }

    @Test("a dropped session is reconnected while wanted, otherwise it stays blocked")
    func dropped() {
        #expect(reaction(from: .connected, to: .dropped) == .reconnect)
        #expect(reaction(from: .dropped, to: .dropped) == .reconnect)
        // only Disconnect unblocks: no automatic cleanup
        #expect(reaction(to: .dropped, wants: false) == .none)
        #expect(reaction(to: .dropped, auto: false) == .none)
        #expect(reaction(to: .dropped, first: true, wants: false) == .none)
    }

    @Test("a helper without the kill-switch is cleaned up before reconnecting")
    func oldHelper() {
        let old = StatusPolicy.reaction(
            previous: .connected, next: .dropped, isFirstStatus: false,
            wantsConnection: true, autoReconnect: true, helperVersion: 3
        )
        #expect(old == .cleanUpAndReconnect)
        let unknown = StatusPolicy.reaction(
            previous: .connected, next: .dropped, isFirstStatus: false,
            wantsConnection: true, autoReconnect: true, helperVersion: nil
        )
        #expect(unknown == .cleanUpAndReconnect)
        let oldIdle = StatusPolicy.reaction(
            previous: .connected, next: .dropped, isFirstStatus: false,
            wantsConnection: false, autoReconnect: true, helperVersion: 3
        )
        #expect(oldIdle == .cleanUp)
    }

    @Test("a lost tunnel without leftovers is reconnected only when wanted")
    func disconnected() {
        #expect(reaction(from: .connected, to: .disconnected) == .reconnect)
        #expect(reaction(from: .connected, to: .disconnected, wants: false) == .none)
        #expect(reaction(from: .connected, to: .disconnected, auto: false) == .none)
        #expect(reaction(from: .disconnected, to: .disconnected) == .none)
        #expect(reaction(from: .connecting, to: .unavailable) == .none)
    }
}

@Suite("ReconnectPolicy")
struct ReconnectPolicyTests {
    @Test("backs off and then repeats the last delay")
    func delays() {
        let policy = ReconnectPolicy(delays: [.seconds(1), .seconds(5)])
        #expect(policy.delay(forAttempt: 0) == .seconds(1))
        #expect(policy.delay(forAttempt: 1) == .seconds(5))
        #expect(policy.delay(forAttempt: 9) == .seconds(5))
        #expect(policy.delay(forAttempt: -1) == .seconds(1))
    }
}

@Suite("AppLanguage")
struct AppLanguageTests {
    @Test("system removes the override, a language pins it")
    func appleLanguages() {
        #expect(AppLanguage.system.appleLanguages == nil)
        #expect(AppLanguage.english.appleLanguages == ["en"])
        #expect(AppLanguage.russian.appleLanguages == ["ru"])
    }

    @Test("reads the stored override back, anything else is system")
    func readBack() {
        #expect(AppLanguage(appleLanguages: ["ru"]) == .russian)
        #expect(AppLanguage(appleLanguages: ["en"]) == .english)
        #expect(AppLanguage(appleLanguages: nil) == .system)
        #expect(AppLanguage(appleLanguages: ["ru-RU", "en"]) == .system)
        #expect(AppLanguage(appleLanguages: ["de"]) == .system)
        #expect(AppLanguage(appleLanguages: ["system"]) == .system)
    }
}

@Suite("ConnectionNotice")
struct ConnectionNoticeTests {
    @Test("a tunnel lost while wanted is announced, a disconnect is not")
    func lost() {
        #expect(NoticePolicy.notice(previous: .connected, next: .dropped, wantsConnection: true, recovering: false) == .lost)
        #expect(NoticePolicy.notice(previous: .connected, next: .disconnected, wantsConnection: true, recovering: false) == .lost)
        #expect(NoticePolicy.notice(previous: .connected, next: .disconnected, wantsConnection: false, recovering: false) == nil)
        #expect(NoticePolicy.notice(previous: .dropped, next: .dropped, wantsConnection: true, recovering: true) == nil)
    }

    @Test("a tunnel back after a drop is announced, a first connect is not")
    func restored() {
        #expect(NoticePolicy.notice(previous: .connecting, next: .connected, wantsConnection: true, recovering: true) == .restored)
        #expect(NoticePolicy.notice(previous: .connecting, next: .connected, wantsConnection: true, recovering: false) == nil)
        #expect(NoticePolicy.notice(previous: .connected, next: .connected, wantsConnection: true, recovering: true) == nil)
    }
}

@Suite("Reconnect now")
struct ReconnectNowTests {
    @Test("the network coming back or a wake reconnects at once only when it is wanted and not up")
    func reconnectNow() {
        #expect(StatusPolicy.reconnectsNow(state: .dropped, wantsConnection: true, autoReconnect: true))
        #expect(StatusPolicy.reconnectsNow(state: .disconnected, wantsConnection: true, autoReconnect: true))
        #expect(!StatusPolicy.reconnectsNow(state: .connected, wantsConnection: true, autoReconnect: true))
        #expect(!StatusPolicy.reconnectsNow(state: .connecting, wantsConnection: true, autoReconnect: true))
        #expect(!StatusPolicy.reconnectsNow(state: .dropped, wantsConnection: false, autoReconnect: true))
        #expect(!StatusPolicy.reconnectsNow(state: .dropped, wantsConnection: true, autoReconnect: false))
    }
}

@Suite("TrafficCounters")
struct TrafficCountersTests {
    @Test("reads the byte counters of the link line, with or without a hardware address")
    func parse() {
        let ppp = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        ppp0       1500  <Link#21>                          1234     0     567890     2345     0     123456     0
        ppp0       1500  172.16.3/24   172.16.3.33          1234     -     567890     2345     -     123456     -
        """
        #expect(TrafficCounters.parse(netstat: ppp) == TrafficCounters(received: 567_890, sent: 123_456))
        let en0 = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        en0        1500  <Link#15>   66:9f:5d:7e:a1:41 83251829     0 97177721294 40869030     0 21193582889     0
        """
        #expect(TrafficCounters.parse(netstat: en0) == TrafficCounters(received: 97_177_721_294, sent: 21_193_582_889))
        #expect(TrafficCounters.parse(netstat: "netstat: interface ppp0 does not exist") == nil)
    }
}

@Suite("PollingPolicy")
struct PollingPolicyTests {
    private func interval(
        _ state: ConnectionState, busy: Bool = false, reconnecting: Bool = false, panel: Bool = false
    ) -> Duration {
        PollingPolicy.interval(state: state, isBusy: busy, isReconnecting: reconnecting, isPanelVisible: panel)
    }

    @Test("polls fast while something is changing or someone is looking")
    func fast() {
        #expect(interval(.connecting) == PollingPolicy.fast)
        #expect(interval(.dropped) == PollingPolicy.fast)
        #expect(interval(.disconnected, busy: true) == PollingPolicy.fast)
        #expect(interval(.disconnected, reconnecting: true) == PollingPolicy.fast)
        #expect(interval(.connected, panel: true) == PollingPolicy.fast)
    }

    @Test("polls rarely while nothing happens")
    func slow() {
        #expect(interval(.connected) == PollingPolicy.connected)
        #expect(interval(.disconnected) == PollingPolicy.idle)
        #expect(interval(.unavailable) == PollingPolicy.idle)
        #expect(PollingPolicy.fast < PollingPolicy.connected && PollingPolicy.connected < PollingPolicy.idle)
    }
}
