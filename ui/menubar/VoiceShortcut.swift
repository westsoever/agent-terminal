// VoiceShortcut.swift - the global shortcut that wakes the voice dispatcher (dispatcher v2). Part of KachingBar.
//
// Right Control + Left Option pressed together: KachingBar plays a short cue (Tink), notes which Terminal tab the
// owner is looking at, and wakes the dispatcher session (dispatcher/launch.sh: claude --name dispatcher, cwd
// $AGENT_HOME/dispatcher, talking through VoiceMode's converse tool) so it listens and hands what it hears on.
//
// Layers, next to KachingBar.swift's (no drawing code here):
//   VoiceShortcut  the chord as a pure function of the raw modifier flags, the Accessibility check, the menu entry
//   VoiceWake      one wake: focus file, find the dispatcher, decide start | wake | cue, run it, log it; no UI code
//   VoiceKeys      the NSEvent monitors and the trust poll inside the running app (main thread)
//
// The chord: device-dependent bits of NSEvent.modifierFlags.rawValue, right control NX_DEVICERCTLKEYMASK 0x2000 and
// left option NX_DEVICELALTKEYMASK 0x20. It fires once, on the flagsChanged event that makes both held (an edge:
// further modifier changes while both stay down do not fire again), and never while command or shift is held.
// A global monitor sees it in other apps (needs Accessibility); a local one sees it while KachingBar's menu is open.
//
// Accessibility: checked at launch (AXIsProcessTrusted); when missing, macOS is asked once to show its prompt and the
// menu says "Voice shortcut off: allow KachingBar in Accessibility" (opens that Settings pane). Trust is checked
// again every KACHING_BAR_AX_POLL_SECS (5) and whenever the menu opens; the global monitor is installed as soon as
// it is granted, without a restart. When on, the menu says "Voice: Right Ctrl + Left Option".
//
// One wake (VoiceWake):
//   focus   Terminal (com.apple.Terminal) frontmost: the tty of its front window's selected tab (osascript), written
//           atomically to $AGENT_HOME/dispatcher/focus as one line `<tty> <epoch-seconds>`. Anything else in front:
//           nothing is written (an older file stays; its reader ignores stale ones).
//   find    $CLAUDE_DIR/sessions/*.json (CLAUDE_DIR default ~/.claude) with name "dispatcher" or cwd
//           $AGENT_HOME/dispatcher and a live pid (kill(pid, 0) == 0); its tty from `ps -o tty= -p <pid>`.
//   act     absent -> start: a new Terminal window runs $KACHING_DIR/dispatcher/launch.sh "[shortcut] listen"
//           idle   -> wake:  osascript -l JavaScript $KACHING_DIR/terminal/send.js text <tty> "[shortcut] listen"
//           busy (any status but idle: already listening or working), or no tty -> cue only, nothing typed
//   log     one line per chord in $AGENT_HOME/dispatcher/shortcut.log: `<ISO time> started|woke|busy|error <details>`
// Needs, besides Accessibility: Automation (KachingBar -> Terminal), asked by macOS the first time osascript runs.
//
// CLI: KachingBar --wake-once [--dry-run]   one wake now, printed as key=value lines (focus_tty, focus_line,
//                                           dispatcher=absent|idle|busy, action=start|wake|cue, command=..., result);
//                                           --dry-run runs nothing and writes nothing (no osascript, no files)
//      KachingBar --chord-test RAW PREV     fire=1|0 for the chord function (flags in decimal or 0x hex)
// Env: KACHING_BAR_FRONT_TTY   when set, the tab in front (instead of asking Terminal); empty = Terminal not in front
//      KACHING_BAR_DISPATCHER_TTY  when set, the dispatcher's tty (instead of ps); empty = none   (tests)
//      KACHING_BAR_AX_TRUSTED  1|0: report Accessibility as granted or not (tests)
//      KACHING_BAR_NO_CUE=1    no sound (tests)        KACHING_BAR_AX_POLL_SECS (5)
//      CLAUDE_DIR (~/.claude); AGENT_HOME, KACHING_DIR as in KachingBar.swift; CHING_* names still count.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Chord and permission

enum VoiceShortcut {
    static let rightControl: UInt = 0x0000_2000   // NX_DEVICERCTLKEYMASK
    static let leftOption: UInt = 0x0000_0020     // NX_DEVICELALTKEYMASK
    static let blockers: UInt = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue
    static let menuOn = "Voice: Right Ctrl + Left Option"
    static let menuOff = "Voice shortcut off: allow KachingBar in Accessibility"
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    static func bothHeld(_ raw: UInt) -> Bool { raw & rightControl != 0 && raw & leftOption != 0 }

    /// True on the transition into "both held", with neither command nor shift down.
    static func fires(raw: UInt, previous: UInt) -> Bool {
        bothHeld(raw) && !bothHeld(previous) && raw & blockers == 0
    }

    static let trustOverride: Bool? = {
        switch kachingEnvironment()["KACHING_BAR_AX_TRUSTED"] {
        case "1"?: return true
        case "0"?: return false
        default: return nil
        }
    }()

    static func trusted() -> Bool { trustOverride ?? AXIsProcessTrusted() }

    /// Asks macOS to show its Accessibility prompt (it shows it once per app, then only the Settings pane helps).
    static func prompt() {
        guard trustOverride == nil else { return }
        // the value of kAXTrustedCheckOptionPrompt (a C global Swift 6 will not read without isolation)
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var menuEntry: MenuEntry { trusted() ? .info(menuOn) : .action(menuOff, .openAccessibility) }

    @MainActor static func openSettings() {
        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
    }

    @MainActor static func cue() {
        guard kachingEnvironment()["KACHING_BAR_NO_CUE"] != "1" else { return }
        NSSound(named: "Tink")?.play()
    }

    static func parseFlags(_ s: String) -> UInt? {
        let t = s.lowercased()
        return t.hasPrefix("0x") ? UInt(t.dropFirst(2), radix: 16) : UInt(t)
    }

    /// The CLI flags of this file; nil when the arguments are not ours (KachingBar handles them).
    @MainActor static func cli(_ args: [String], env: [String: String]) -> Int32? {
        func usage(_ s: String) -> Int32 { FileHandle.standardError.write(Data("KachingBar: \(s)\n".utf8)); return 64 }
        switch args.first {
        case "--chord-test":
            guard args.count == 3, let raw = parseFlags(args[1]), let prev = parseFlags(args[2]) else {
                return usage("usage: --chord-test RAWFLAGS PREVFLAGS")
            }
            print("fire=\(fires(raw: raw, previous: prev) ? 1 : 0)")
            return 0
        case "--wake-once":
            let rest = args.dropFirst()
            guard rest.allSatisfy({ $0 == "--dry-run" }) else { return usage("usage: --wake-once [--dry-run]") }
            let dry = rest.contains("--dry-run")
            let front = env["KACHING_BAR_FRONT_TTY"] == nil ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
            if !dry { cue() }
            print(VoiceWake(env: env).run(frontBundle: front, dryRun: dry))
            if !dry && env["KACHING_BAR_NO_CUE"] != "1" { usleep(400_000) }   // let the cue finish before exit
            return 0
        default:
            return nil
        }
    }
}

// MARK: - Wake

enum DispatcherState: String, Sendable { case absent, idle, busy }
enum WakeAction: String, Sendable { case start, wake, cue }

struct DispatcherSession: Sendable, Equatable {
    let pid: Int32
    let status: String
    let tty: String?          // like ttys005; nil when it has none (not in a terminal)
}

struct WakePlan: Sendable {
    var focus: String          // the tty in front, "none" (Terminal not in front or unreadable), "unasked" (dry run)
    var focusLine: String?     // what the focus file gets; nil = left alone
    var dispatcher: DispatcherSession?
    var action: WakeAction
    var command: [String]      // argv; empty for a cue
    var reason: String         // why only a cue

    var state: DispatcherState {
        guard let d = dispatcher else { return .absent }
        return d.status == "idle" ? .idle : .busy
    }

    var report: String {
        var l = ["focus_tty=\(focus)"]
        if let f = focusLine { l.append("focus_line=\(f)") }
        l.append("dispatcher=\(state.rawValue)")
        if let d = dispatcher { l += ["dispatcher_pid=\(d.pid)", "dispatcher_tty=\(d.tty ?? "none")"] }
        l.append("action=\(action.rawValue)")
        l.append("command=\(command.isEmpty ? "none" : command.map(VoiceWake.shellWord).joined(separator: " "))")
        if !reason.isEmpty { l.append("reason=\(reason)") }
        return l.joined(separator: "\n")
    }
}

struct VoiceWake: Sendable {
    static let wakeText = "[shortcut] listen"
    static let terminalBundle = "com.apple.Terminal"

    let paths: KachingPaths
    let claudeDir: URL
    let env: [String: String]

    init(env: [String: String]) {
        self.env = env
        paths = .fromEnvironment(env)
        if let c = env["CLAUDE_DIR"], !c.isEmpty { claudeDir = URL(fileURLWithPath: c, isDirectory: true) }
        else { claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true) }
    }

    var dispatcherDir: URL { paths.agentHome.appendingPathComponent("dispatcher", isDirectory: true) }
    var focusFile: URL { dispatcherDir.appendingPathComponent("focus") }
    var logFile: URL { dispatcherDir.appendingPathComponent("shortcut.log") }
    var launchScript: URL { paths.kachingDir.appendingPathComponent("dispatcher/launch.sh") }
    var sendScript: URL { paths.kachingDir.appendingPathComponent("terminal/send.js") }

    /// One wake: plan, then (unless dryRun) write the focus file, run the command and log. Returns the report.
    func run(frontBundle: String?, dryRun: Bool, now: Date = Date()) -> String {
        let p = plan(frontBundle: frontBundle, dryRun: dryRun, now: now)
        guard !dryRun else { return p.report + "\ndry_run=yes" }
        let (word, detail) = perform(p)
        log(word, "dispatcher=\(p.state.rawValue)" + (p.dispatcher.map { " pid=\($0.pid) tty=\($0.tty ?? "none")" } ?? "")
                + " focus=\(p.focus)" + (detail.isEmpty ? "" : " \(detail)"), now: now)
        return p.report + "\ndry_run=no\nresult=\(word)" + (detail.isEmpty ? "" : " \(detail)")
    }

    func plan(frontBundle: String?, dryRun: Bool, now: Date) -> WakePlan {
        var focus = "none"
        var tty: String?
        if let forced = env["KACHING_BAR_FRONT_TTY"] {
            tty = forced.isEmpty ? nil : Self.stripDev(forced)
        } else if frontBundle == Self.terminalBundle {
            if dryRun { focus = "unasked" } else { tty = frontTerminalTTY() }
        }
        if let t = tty { focus = t }
        let line = tty.map { "\($0) \(Int(now.timeIntervalSince1970))" }

        let d = findDispatcher()
        var p = WakePlan(focus: focus, focusLine: line, dispatcher: d, action: .cue, command: [], reason: "")
        switch (d, p.state) {
        case (nil, _):
            let shell = "export AGENT_HOME=\(TerminalLauncher.quote(paths.agentHome.path)); "
                + "\(TerminalLauncher.quote(launchScript.path)) \(TerminalLauncher.quote(Self.wakeText))"
            p.action = .start
            p.command = ["/usr/bin/osascript", "-e", "tell application \"Terminal\" to do script \"\(Self.appleScriptEscape(shell))\""]
        case (let s?, .idle):
            if let t = s.tty {
                p.action = .wake
                p.command = ["/usr/bin/osascript", "-l", "JavaScript", sendScript.path, "text", t, Self.wakeText]
            } else {
                p.reason = "dispatcher has no tty"
            }
        default:
            p.reason = "dispatcher busy"
        }
        return p
    }

    /// Runs the plan. Returns the log word (started | woke | busy | error) and details.
    func perform(_ p: WakePlan) -> (String, String) {
        if let line = p.focusLine {
            do {
                try FileManager.default.createDirectory(at: dispatcherDir, withIntermediateDirectories: true)
                try Data((line + "\n").utf8).write(to: focusFile, options: .atomic)
            } catch {
                return ("error", "focus not written: \(error.localizedDescription)")
            }
        }
        switch p.action {
        case .cue:
            return p.state == .busy ? ("busy", "") : ("error", p.reason)
        case .start:
            guard FileManager.default.isExecutableFile(atPath: launchScript.path) else { return ("error", "no launch.sh at \(launchScript.path)") }
            guard let r = Self.exec(p.command, timeout: 60) else { return ("error", "osascript did not finish") }
            return r.status == 0 ? ("started", "") : ("error", "osascript exit \(r.status): \(r.out)")
        case .wake:
            guard FileManager.default.fileExists(atPath: sendScript.path) else { return ("error", "no send.js at \(sendScript.path)") }
            guard let r = Self.exec(p.command, timeout: 60) else { return ("error", "send.js did not finish") }
            return r.out == "ok" ? ("woke", "") : ("error", r.out.isEmpty ? "send.js exit \(r.status)" : r.out)
        }
    }

    /// The tty of Terminal's front window's selected tab, without /dev/; nil when Terminal cannot say.
    func frontTerminalTTY() -> String? {
        guard let r = Self.exec(["/usr/bin/osascript", "-e", "tell application \"Terminal\" to get tty of selected tab of front window"],
                                timeout: 30),
              r.status == 0, !r.out.isEmpty else { return nil }
        return Self.stripDev(r.out)
    }

    /// The live dispatcher session: name "dispatcher" (preferred) or cwd $AGENT_HOME/dispatcher; newest update wins.
    func findDispatcher() -> DispatcherSession? {
        let dir = claudeDir.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let want = Self.canonical(dispatcherDir.path)
        var best: (byName: Int, updated: Double, pid: Int32, status: String)?
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0 else { continue }
            let byName = (o["name"] as? String) == "dispatcher" ? 1 : 0
            let byCwd = (o["cwd"] as? String).map { Self.canonical($0) == want } ?? false
            guard byName == 1 || byCwd, kill(pid, 0) == 0 else { continue }
            let updated = (o["statusUpdatedAt"] as? NSNumber ?? o["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            if let b = best, (b.byName, b.updated) >= (byName, updated) { continue }
            best = (byName, updated, pid, (o["status"] as? String) ?? "")
        }
        guard let b = best else { return nil }
        return DispatcherSession(pid: b.pid, status: b.status, tty: tty(of: b.pid))
    }

    func tty(of pid: Int32) -> String? {
        if let forced = env["KACHING_BAR_DISPATCHER_TTY"] { return forced.isEmpty ? nil : Self.stripDev(forced) }
        guard let r = Self.exec(["/bin/ps", "-o", "tty=", "-p", String(pid)], timeout: 5), r.status == 0 else { return nil }
        let t = Self.stripDev(r.out)
        return t.isEmpty || t.hasPrefix("?") ? nil : t
    }

    func log(_ word: String, _ detail: String, now: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dispatcherDir, withIntermediateDirectories: true)
        let line = Data("\(ISO8601DateFormatter().string(from: now)) \(word) \(detail)\n".utf8)
        if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: logFile) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    }

    // MARK: helpers

    static func stripDev(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("/dev/") ? String(t.dropFirst(5)) : t
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// An argv word as a shell would need it (for the report only).
    static func shellWord(_ s: String) -> String {
        let plain = !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_./=:-+,@%".unicodeScalars.contains($0) }
        return plain ? s : TerminalLauncher.quote(s)
    }

    /// Runs argv with stdin closed; stdout and stderr together, trimmed. nil when it could not start or ran past timeout.
    static func exec(_ argv: [String], timeout: TimeInterval) -> (status: Int32, out: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); p.waitUntilExit(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Monitors (the running app)

@MainActor
final class VoiceKeys: NSObject {
    private static var shared: VoiceKeys?

    private let wake: VoiceWake
    private let pollSecs: TimeInterval
    private var global: Any?
    private var local: Any?
    private var timer: Timer?
    private var last: UInt = 0
    private var trusted = false
    private var inFlight = false

    private init(env: [String: String]) {
        wake = VoiceWake(env: env)
        pollSecs = TimeInterval(Int(env["KACHING_BAR_AX_POLL_SECS"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 5)
    }

    /// Called once from applicationDidFinishLaunching.
    static func start(env: [String: String]) {
        guard shared == nil else { return }
        let k = VoiceKeys(env: env)
        shared = k
        k.begin()
    }

    private func begin() {
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let raw = e.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.flags(raw) }
            return e
        }
        if !VoiceShortcut.trusted() { VoiceShortcut.prompt() }
        checkTrust()
        timer = Timer.scheduledTimer(withTimeInterval: pollSecs, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
        timer?.tolerance = 1
        NotificationCenter.default.addObserver(self, selector: #selector(menuOpened(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    /// Installs the global monitor once Accessibility is granted (again after a revoke and re-grant).
    private func checkTrust() {
        let now = VoiceShortcut.trusted()
        defer { trusted = now }
        guard now, !trusted else { return }
        if let g = global { NSEvent.removeMonitor(g) }
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let raw = e.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.flags(raw) }
        }
    }

    /// The menu is opening: re-check trust and set the voice line to match, in place.
    @objc private func menuOpened(_ n: Notification) {
        checkTrust()
        guard let menu = n.object as? NSMenu else { return }
        for mi in menu.items where mi.title == VoiceShortcut.menuOn || mi.title == VoiceShortcut.menuOff {
            mi.title = trusted ? VoiceShortcut.menuOn : VoiceShortcut.menuOff
            mi.isEnabled = !trusted
            mi.target = trusted ? nil : self
            mi.action = trusted ? nil : #selector(openSettings)
        }
    }

    @objc private func openSettings() { VoiceShortcut.openSettings() }

    private func flags(_ raw: UInt) {
        let prev = last
        last = raw
        guard VoiceShortcut.fires(raw: raw, previous: prev) else { return }
        VoiceShortcut.cue()
        guard !inFlight else { return }   // the previous wake is still running: the cue is enough
        inFlight = true
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let wake = self.wake
        Task.detached(priority: .userInitiated) {
            _ = wake.run(frontBundle: front, dryRun: false)
            await self.done()
        }
    }

    private func done() { inFlight = false }
}
