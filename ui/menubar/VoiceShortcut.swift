// VoiceShortcut.swift - the global shortcut that wakes the voice dispatcher (dispatcher v2). Part of AgentTerminalBar.
//
// Right Control + Left Option tapped together (pressed and let go, no other key): AgentTerminalBar plays a short cue (Tink), notes which Terminal tab the
// owner is looking at, and wakes the dispatcher session (dispatcher/launch.sh: claude --name dispatcher, cwd
// $AGENT_HOME/dispatcher, talking through VoiceMode's converse tool) so it listens and hands what it hears on.
//
// Layers, next to AgentTerminalBar.swift's (no drawing code here):
//   ChordTap       the chord as a pure state machine over flagsChanged and keyDown events (testable, no AppKit state)
//   VoiceShortcut  the Accessibility check, the menu entry, the CLI flags
//   VoiceWake      one wake: focus file, find the dispatcher, decide start | wake | cue, run it, log it; no UI code
//   VoiceKeys      the NSEvent monitors and the trust poll inside the running app (main thread)
//
// The chord is a tap, so Ctrl+Option+letter hotkeys (Carbon, in AgentTerminalBar) can share the two keys. Read from the
// device-dependent bits of NSEvent.modifierFlags.rawValue: right control NX_DEVICERCTLKEYMASK 0x2000, left option
// NX_DEVICELALTKEYMASK 0x20.
//   arm     on the flagsChanged event that makes both held, when no other modifier is down (shift, command, left
//           control, right option; caps lock and fn do not count)
//   disarm  any keyDown while armed (Ctrl+Option+N is a hotkey, not the chord), another modifier joining, or a
//           Carbon hotkey firing (VoiceKeys.cancelChord(): a registered hotkey's keyDown never reaches the monitors)
//   fire    when both are released and it is still armed, at most ChordTap.maxHold (1.5 s) after arming
// Monitors for flagsChanged and keyDown: a global one for other apps (needs Accessibility, keyDown included) and a
// local one for while AgentTerminalBar's menu is open.
//
// Accessibility: checked at launch (AXIsProcessTrusted); when missing, macOS is asked once to show its prompt and the
// menu says "Voice shortcut off: re-add AgentTerminalBar in Accessibility (needed after each rebuild)" (opens that Settings
// pane). The app is ad-hoc signed, so every rebuild (build.sh, install.sh after a source change) gives it a new
// signature and macOS drops the grant: remove AgentTerminalBar from the Accessibility list and add it again. Trust is checked
// again every AGENT_TERMINAL_BAR_AX_POLL_SECS (5) and whenever the menu opens; the global monitor is installed as soon as
// it is granted, without a restart. When on, the menu says "Voice: Right Ctrl + Left Option".
//
// One wake (VoiceWake):
//   focus   Terminal (com.apple.Terminal) frontmost: the tty of its front window's selected tab (osascript), written
//           atomically to $AGENT_HOME/dispatcher/focus as one line `<tty> <epoch-seconds>`. Anything else in front:
//           nothing is written (an older file stays; its reader ignores stale ones).
//   find    $CLAUDE_DIR/sessions/*.json (CLAUDE_DIR default ~/.claude) with name "dispatcher" or cwd
//           $AGENT_HOME/dispatcher and a live pid (kill(pid, 0) == 0); its tty from `ps -o tty= -p <pid>`.
//   act     absent -> start: a new Terminal window runs $AGENT_TERMINAL_DIR/dispatcher/launch.sh "[shortcut] listen" and
//                    Terminal comes to the front; $AGENT_HOME/dispatcher/starting gets the time. Logged "started
//                    start requested": do script cannot tell whether launch.sh got claude going.
//           starting -> cue only (logged "starting"): no session yet, but a start was requested under 20 s ago or a
//                    launch.sh / `claude --name dispatcher` process is running (pgrep -f), so no second window opens
//           idle   -> wake:  osascript -l JavaScript $AGENT_TERMINAL_DIR/terminal/send.js text <tty> "[shortcut] listen"
//           busy (any status but idle: already listening or working), or no tty -> cue only, nothing typed
//   log     one line per chord in $AGENT_HOME/dispatcher/shortcut.log:
//           `<ISO time> started|starting|woke|busy|error <details>`; a focus file that cannot be written is noted, the
//           wake goes on
// Needs, besides Accessibility: Automation (AgentTerminalBar -> Terminal), asked by macOS the first time osascript runs.
//
// CLI: AgentTerminalBar --wake-once [--dry-run]   one wake now, printed as key=value lines (focus_tty, focus_line,
//                                           dispatcher=absent|starting|idle|busy, action=start|wake|cue,
//                                           command=..., result);
//                                           --dry-run runs nothing and writes nothing (no osascript, no files)
//      AgentTerminalBar --chord-test EVENT...     fire=<times the chord fired> over a sequence of events: FLAGS (raw
//                                           modifier flags, decimal or 0x hex) or `key` (a keyDown), each with an
//                                           optional @SECONDS time stamp (default: the previous event's)
// Env: AGENT_TERMINAL_BAR_FRONT_TTY   when set, the tab in front (instead of asking Terminal); empty = Terminal not in front
//      AGENT_TERMINAL_BAR_DISPATCHER_TTY  when set, the dispatcher's tty (instead of ps); empty = none   (tests)
//      AGENT_TERMINAL_BAR_AX_TRUSTED  1|0: report Accessibility as granted or not (tests)
//      AGENT_TERMINAL_BAR_PGREP       pgrep to look for a dispatcher being started (default /usr/bin/pgrep; tests)
//      AGENT_TERMINAL_BAR_NO_CUE=1    no sound (tests)        AGENT_TERMINAL_BAR_AX_POLL_SECS (5)
//      CLAUDE_DIR (~/.claude); AGENT_HOME, AGENT_TERMINAL_DIR as in AgentTerminalBar.swift; KACHING_* and CHING_* names still count.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Chord

/// The tap of Right Control + Left Option, as a state machine over the events the monitors see. step() says when to fire.
struct ChordTap: Sendable, Equatable {
    static let rightControl: UInt = 0x0000_2000   // NX_DEVICERCTLKEYMASK
    static let leftOption: UInt = 0x0000_0020     // NX_DEVICELALTKEYMASK
    static let maxHold: Double = 1.5              // seconds from arming to release; longer is not a tap
    /// The modifiers that count: shift, control, option, command and their device bits (left/right of each).
    static let modifiers: UInt = NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.command.rawValue | 0x0000_207F
    /// What the chord itself sets: the two device bits and their device-independent control and option.
    static let chord: UInt = rightControl | leftOption | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.option.rawValue

    enum Event: Sendable { case flags(UInt, at: Double), keyDown(at: Double) }

    private(set) var armed = false
    private var armedAt = 0.0
    private var previous: UInt = 0

    static func bothHeld(_ raw: UInt) -> Bool { raw & rightControl != 0 && raw & leftOption != 0 }
    static func neitherHeld(_ raw: UInt) -> Bool { raw & (rightControl | leftOption) == 0 }
    static func others(_ raw: UInt) -> Bool { raw & modifiers & ~chord != 0 }

    /// Feeds one event; true when the chord fires (both let go after a clean tap).
    mutating func step(_ e: Event) -> Bool {
        switch e {
        case .keyDown:
            armed = false
            return false
        case .flags(let raw, let at):
            defer { previous = raw }
            if Self.bothHeld(raw) && !Self.bothHeld(previous) && !armed {
                armed = !Self.others(raw)
                armedAt = at
                return false
            }
            guard armed else { return false }
            if Self.others(raw) { armed = false; return false }
            guard Self.neitherHeld(raw) else { return false }   // one still down: wait for the other
            armed = false
            return at - armedAt <= Self.maxHold
        }
    }

    /// A hotkey went off with these modifiers: whatever was armed is not a tap.
    mutating func cancel() { armed = false }
}

// MARK: - Permission and CLI

enum VoiceShortcut {
    static let menuOn = "Voice: Right Ctrl + Left Option"
    static let menuOff = "Voice shortcut off: re-add AgentTerminalBar in Accessibility (needed after each rebuild)"
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    static let trustOverride: Bool? = {
        switch agentTerminalEnvironment()["AGENT_TERMINAL_BAR_AX_TRUSTED"] {
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
        guard agentTerminalEnvironment()["AGENT_TERMINAL_BAR_NO_CUE"] != "1" else { return }
        NSSound(named: "Tink")?.play()
    }

    static func parseFlags(_ s: String) -> UInt? {
        let t = s.lowercased()
        return t.hasPrefix("0x") ? UInt(t.dropFirst(2), radix: 16) : UInt(t)
    }

    /// The CLI flags of this file; nil when the arguments are not ours (AgentTerminalBar handles them).
    @MainActor static func cli(_ args: [String], env: [String: String]) -> Int32? {
        func usage(_ s: String) -> Int32 { FileHandle.standardError.write(Data("AgentTerminalBar: \(s)\n".utf8)); return 64 }
        switch args.first {
        case "--chord-test":
            var tap = ChordTap(), at = 0.0, fired = 0
            for word in args.dropFirst() {
                let parts = word.split(separator: "@", maxSplits: 1).map(String.init)
                if parts.count == 2 { guard let t = Double(parts[1]) else { return usage("bad time in \(word)") }; at = t }
                if parts.first == "key" { if tap.step(.keyDown(at: at)) { fired += 1 }; continue }
                guard let raw = parts.first.flatMap(parseFlags) else { return usage("usage: --chord-test (FLAGS|key)[@SECONDS]...") }
                if tap.step(.flags(raw, at: at)) { fired += 1 }
            }
            guard args.count > 1 else { return usage("usage: --chord-test (FLAGS|key)[@SECONDS]...") }
            print("fire=\(fired)")
            return 0
        case "--wake-once":
            let rest = args.dropFirst()
            guard rest.allSatisfy({ $0 == "--dry-run" }) else { return usage("usage: --wake-once [--dry-run]") }
            let dry = rest.contains("--dry-run")
            let front = env["AGENT_TERMINAL_BAR_FRONT_TTY"] == nil ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
            if !dry { cue() }
            print(VoiceWake(env: env).run(frontBundle: front, dryRun: dry))
            if !dry && env["AGENT_TERMINAL_BAR_NO_CUE"] != "1" { usleep(400_000) }   // let the cue finish before exit
            return 0
        default:
            return nil
        }
    }
}

// MARK: - Wake

enum DispatcherState: String, Sendable { case absent, starting, idle, busy }
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
    var starting = false       // no session yet, but a start is under way (cooldown or a launch process)

    var state: DispatcherState {
        guard let d = dispatcher else { return starting ? .starting : .absent }
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

    let paths: AgentTerminalPaths
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
    var launchScript: URL { paths.agentTerminalDir.appendingPathComponent("dispatcher/launch.sh") }
    var sendScript: URL { paths.agentTerminalDir.appendingPathComponent("terminal/send.js") }
    var startMarker: URL { dispatcherDir.appendingPathComponent("starting") }   // epoch of the last start request
    static let startCooldown = 20                                                // seconds a start counts as under way

    /// One wake: plan, then (unless dryRun) write the focus file, run the command and log. Returns the report.
    func run(frontBundle: String?, dryRun: Bool, now: Date = Date()) -> String {
        let p = plan(frontBundle: frontBundle, dryRun: dryRun, now: now)
        guard !dryRun else { return p.report + "\ndry_run=yes" }
        let (word, detail) = perform(p, now: now)
        log(word, "dispatcher=\(p.state.rawValue)" + (p.dispatcher.map { " pid=\($0.pid) tty=\($0.tty ?? "none")" } ?? "")
                + " focus=\(p.focus)" + (detail.isEmpty ? "" : " \(detail)"), now: now)
        return p.report + "\ndry_run=no\nresult=\(word)" + (detail.isEmpty ? "" : " \(detail)")
    }

    func plan(frontBundle: String?, dryRun: Bool, now: Date) -> WakePlan {
        var focus = "none"
        var tty: String?
        if let forced = env["AGENT_TERMINAL_BAR_FRONT_TTY"] {
            tty = forced.isEmpty ? nil : Self.stripDev(forced)
        } else if frontBundle == Self.terminalBundle {
            if dryRun { focus = "unasked" } else { tty = frontTerminalTTY() }
        }
        if let t = tty { focus = t }
        let line = tty.map { "\($0) \(Int(now.timeIntervalSince1970))" }

        let d = findDispatcher()
        var p = WakePlan(focus: focus, focusLine: line, dispatcher: d, action: .cue, command: [], reason: "")
        if d == nil, let why = startUnderWay(now: now) { p.starting = true; p.reason = why }
        switch (d, p.state) {
        case (nil, .starting):
            break
        case (nil, _):
            let shell = "export AGENT_HOME=\(TerminalLauncher.quote(paths.agentHome.path)); "
                + "\(TerminalLauncher.quote(launchScript.path)) \(TerminalLauncher.quote(Self.wakeText))"
            p.action = .start
            p.command = ["/usr/bin/osascript", "-e", "tell application \"Terminal\" to do script \"\(Self.appleScriptEscape(shell))\"",
                         "-e", "tell application \"Terminal\" to activate"]
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

    /// Runs the plan. Returns the log word (started | starting | woke | busy | error) and details. A focus file that
    /// cannot be written is noted in the details; the wake goes on.
    func perform(_ p: WakePlan, now: Date = Date()) -> (String, String) {
        var note = ""
        if let line = p.focusLine {
            do {
                try FileManager.default.createDirectory(at: dispatcherDir, withIntermediateDirectories: true)
                try Data((line + "\n").utf8).write(to: focusFile, options: .atomic)
            } catch {
                note = "(focus not written: \(error.localizedDescription))"
            }
        }
        let (word, detail) = act(p, now: now)
        return (word, [detail, note].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private func act(_ p: WakePlan, now: Date) -> (String, String) {
        switch p.action {
        case .cue:
            switch p.state {
            case .busy: return ("busy", "")
            case .starting: return ("starting", p.reason)
            default: return ("error", p.reason)
            }
        case .start:
            guard FileManager.default.isExecutableFile(atPath: launchScript.path) else { return ("error", "no launch.sh at \(launchScript.path)") }
            try? FileManager.default.createDirectory(at: dispatcherDir, withIntermediateDirectories: true)
            try? Data("\(Int(now.timeIntervalSince1970))\n".utf8).write(to: startMarker, options: .atomic)
            guard let r = Self.exec(p.command, timeout: 60) else { return ("error", "osascript did not finish") }
            // do script only opens the window: whether launch.sh got claude going is not known here
            return r.status == 0 ? ("started", "start requested") : ("error", "osascript exit \(r.status): \(r.out)")
        case .wake:
            guard FileManager.default.fileExists(atPath: sendScript.path) else { return ("error", "no send.js at \(sendScript.path)") }
            guard let r = Self.exec(p.command, timeout: 60) else { return ("error", "send.js did not finish") }
            return r.out == "ok" ? ("woke", "") : ("error", r.out.isEmpty ? "send.js exit \(r.status)" : r.out)
        }
    }

    /// Why a start is already under way, so a second chord must not open a second window: a start requested less
    /// than startCooldown seconds ago, or a launch.sh / `claude --name dispatcher` process that has no session file
    /// yet (pgrep -f; AGENT_TERMINAL_BAR_PGREP replaces /usr/bin/pgrep in tests). nil when none.
    func startUnderWay(now: Date) -> String? {
        if let s = try? String(contentsOf: startMarker, encoding: .utf8),
           let t = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let age = Int(now.timeIntervalSince1970) - t
            if age >= 0 && age < Self.startCooldown { return "start requested \(age)s ago" }
        }
        let pgrep = env["AGENT_TERMINAL_BAR_PGREP"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin/pgrep"
        if let r = Self.exec([pgrep, "-f", "dispatcher/launch\\.sh|claude.* --name dispatcher( |$)"], timeout: 5), r.status == 0 {
            return "a dispatcher process is starting"
        }
        return nil
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
        if let forced = env["AGENT_TERMINAL_BAR_DISPATCHER_TTY"] { return forced.isEmpty ? nil : Self.stripDev(forced) }
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
    /// The output is read while it runs (on another thread), so a chatty command cannot fill the pipe and hang.
    static func exec(_ argv: [String], timeout: TimeInterval) -> (status: Int32, out: String)? {
        final class Sink: @unchecked Sendable { var data = Data(); let done = DispatchSemaphore(value: 0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let sink = Sink(), reader = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { sink.data = reader.readDataToEndOfFile(); sink.done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); p.waitUntilExit(); return nil }
        // a grandchild still holding the pipe open must not hang us: give the reader 2 s
        guard sink.done.wait(timeout: .now() + 2) == .success else { return (p.terminationStatus, "") }
        return (p.terminationStatus, String(decoding: sink.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
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
    private var tap = ChordTap()
    private var trusted = false
    private var inFlight = false

    private init(env: [String: String]) {
        wake = VoiceWake(env: env)
        pollSecs = TimeInterval(Int(env["AGENT_TERMINAL_BAR_AX_POLL_SECS"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 5)
    }

    /// Call from a Carbon hotkey handler (Ctrl+Option+letter): its keyDown never reaches the monitors, so without
    /// this letting go of the two keys afterwards would count as a tap.
    static func cancelChord() { shared?.tap.cancel() }

    /// Called once from applicationDidFinishLaunching.
    static func start(env: [String: String]) {
        guard shared == nil else { return }
        let k = VoiceKeys(env: env)
        shared = k
        k.begin()
    }

    private func begin() {
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            let ev = Self.event(e)
            MainActor.assumeIsolated { self?.handle(ev) }
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
        global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            let ev = Self.event(e)
            MainActor.assumeIsolated { self?.handle(ev) }
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

    nonisolated private static func event(_ e: NSEvent) -> ChordTap.Event {
        e.type == .keyDown ? .keyDown(at: e.timestamp) : .flags(e.modifierFlags.rawValue, at: e.timestamp)
    }

    private func handle(_ e: ChordTap.Event) {
        guard tap.step(e) else { return }
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
