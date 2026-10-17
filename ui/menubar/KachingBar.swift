// KachingBar.swift - the Kaching menu bar dot. A status-bar-only app (LSUIElement, no Dock icon).
//
//   green  Kaching is running: the org.kaching.watch plist is installed and the watcher's heartbeat is fresh
//   amber  Kaching is running and at least one session needs the owner (blocked or waiting for input, as dash.sh decides)
//   grey   hollow: Kaching is not running, or its heartbeat is stale
//
// Layers, so transcripts and notifications can be added later without touching the drawing code:
//   KachingPaths        where everything lives (environment overrides, for tests and a non-default install)
//   KachingSnapshot     the model: one computed reading of Kaching's state, plus the menu it implies (MenuEntry list)
//   KachingStatusProvider  reads the files and runs `dash.sh --counts` (cheap, read-only); no UI code
//   StatusBarController  draws the dot and the menu from a snapshot; actions open Terminal
//
// Menu: Open Kaching (ui/raycast/kaching-open.sh: brings kaching forward, or starts it); one submenu per open
// proposal (Show and Approve open Terminal, approve asks for its typed code there; Reject and Snooze 7 days run
// here); Recaps: the latest recap (Claude Code's "while you were away" summary, an away_summary line in the
// transcript) of each live session, newest first.
//
// Signals (no launchctl calls):
//   running  $LAUNCH_AGENTS_DIR/org.kaching.watch.plist exists AND the newest mtime of $AGENT_HOME/watch.heartbeat
//            (rewritten by every kaching-watch.sh tick, every 300 s) or $AGENT_HOME/watch.log is at most
//            KACHING_BAR_STALE_SECS old (default 660: two ticks plus a minute).
//   needs    `dash.sh --counts` (needs = blocked + input over the session registry), run with a 5 s ceiling.
//
// Drags (D38): DragWatcher reads the Terminal windows' frames from the window server twice a second (no
// permission needed for frames). When a window has landed on another display by hand (mouse button up, frame
// still for one tick), it runs `queue.sh dragged ID X Y W H` with the frame it had before; queue.sh decides
// (park frame on the main display, its reserved cell or the grid on the other). Windows the queue moves itself
// are reported too; queue.sh leaves those alone. KACHING_BAR_DRAGS=off turns the watcher off.
//
// CLI: KachingBar --status-once  prints the computed state as key=value lines and exits (used by tests/t_menubar.sh).
// Env: AGENT_HOME (~/.agent) KACHING_DIR (~/.claude/kaching) LAUNCH_AGENTS_DIR (~/Library/LaunchAgents) CLAUDE_DIR (~/.claude)
//      KACHING_BAR_STALE_SECS (660) KACHING_BAR_POLL_SECS (12); the CHING_* names from before D35 still count.
//      The watcher counts as installed under its old label org.ching.watch too, until install.sh replaces it.

import AppKit
import Foundation

// MARK: - Paths

struct KachingPaths: Sendable {
    let agentHome: URL
    let kachingDir: URL
    let launchAgentsDir: URL
    var claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)

    var heartbeat: URL { agentHome.appendingPathComponent("watch.heartbeat") }
    var watchLog: URL { agentHome.appendingPathComponent("watch.log") }
    var watchPlist: URL { launchAgentsDir.appendingPathComponent("org.kaching.watch.plist") }
    var oldWatchPlist: URL { launchAgentsDir.appendingPathComponent("org.ching.watch.plist") }   // before D35
    var dash: URL { kachingDir.appendingPathComponent("bin/dash.sh") }
    var queue: URL { kachingDir.appendingPathComponent("bin/queue.sh") }
    var proposalsTool: URL { kachingDir.appendingPathComponent("bin/kaching-proposals") }
    var openKaching: URL { kachingDir.appendingPathComponent("ui/raycast/kaching-open.sh") }
    var claudeSessions: URL { claudeDir.appendingPathComponent("sessions") }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> KachingPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func dir(_ key: String, _ fallback: String) -> URL {
            if let v = env[key], !v.isEmpty { return URL(fileURLWithPath: v, isDirectory: true) }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        return KachingPaths(agentHome: dir("AGENT_HOME", ".agent"),
                          kachingDir: dir("KACHING_DIR", ".claude/kaching"),
                          launchAgentsDir: dir("LAUNCH_AGENTS_DIR", "Library/LaunchAgents"),
                          claudeDir: dir("CLAUDE_DIR", ".claude"))
    }
}

// MARK: - Model

enum DotState: String, Sendable { case green, amber, grey }

struct KachingCounts: Sendable, Equatable {
    var sessions = 0, active = 0, blocked = 0, input = 0, needs = 0, proposals = 0

    /// Parses dash.sh --counts output (key=value lines). nil when no known key is present.
    static func parse(_ text: String) -> KachingCounts? {
        var c = KachingCounts(), seen = false
        for line in text.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let n = Int(kv[1].trimmingCharacters(in: .whitespaces)) else { continue }
            switch kv[0] {
            case "sessions": c.sessions = n
            case "active": c.active = n
            case "blocked": c.blocked = n
            case "input": c.input = n
            case "needs": c.needs = n
            case "proposals": c.proposals = n
            default: continue
            }
            seen = true
        }
        return seen ? c : nil
    }
}

enum MenuAction: String, Sendable {
    case openInbox, showProposal, approveProposal, rejectProposal, snoozeProposal, quit
}

enum MenuEntry: Sendable, Equatable {
    case info(String)                      // disabled text line
    case action(String, MenuAction)
    case actionOn(String, MenuAction, String)   // an action on one thing (a proposal id)
    case text(String, MenuAction)          // a multi-line block of text that stays readable (enabled), with an action
    case submenu(String, [MenuEntry])
    case placeholder(String)               // disabled, for features that are coming
    case separator
}

/// One open proposal, from a `kaching-proposals list` line: "  skill skill-x: Writes ... (4 sessions/4 days)".
struct Proposal: Sendable, Equatable {
    let id: String
    let summary: String

    static func parse(_ text: String) -> [Proposal] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> Proposal? in
            guard line.hasPrefix("  "), !line.hasPrefix("  ("), let colon = line.firstIndex(of: ":") else { return nil }
            let head = line[..<colon].split(separator: " ")
            guard head.count >= 2 else { return nil }
            return Proposal(id: String(head[1]), summary: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

/// The latest recap of one live session.
struct Recap: Sendable, Equatable {
    let session: String
    let text: String
    let at: Date
}

struct KachingSnapshot: Sendable {
    let watcherInstalled: Bool
    let heartbeatAge: Int?                 // seconds since the watcher last wrote; nil = never
    let staleAfter: Int
    let counts: KachingCounts?               // nil when dash.sh failed or timed out
    var proposals: [Proposal] = []
    var recaps: [Recap] = []               // newest first
    var now = Date()

    var running: Bool { watcherInstalled && (heartbeatAge.map { $0 <= staleAfter } ?? false) }

    var state: DotState {
        guard running else { return .grey }
        return (counts?.needs ?? 0) > 0 ? .amber : .green
    }

    var statusLine: String {
        let head = running ? "Kaching running" : "Kaching not running"
        guard let c = counts else { return "\(head) · counts unavailable" }
        let s = c.sessions == 1 ? "1 session" : "\(c.sessions) sessions"
        let n = c.needs == 1 ? "1 needs you" : "\(c.needs) need you"
        return "\(head) · \(s) · \(n)"
    }

    var detailLine: String {
        if !watcherInstalled { return "Watcher not installed (org.kaching.watch)" }
        guard let age = heartbeatAge else { return "No watcher heartbeat yet" }
        let when = Self.ago(age)
        return running ? "Watcher last ran \(when)" : "Watcher silent since \(when)"
    }

    var menu: [MenuEntry] {
        var m: [MenuEntry] = [.info(statusLine), .info(detailLine), .separator, .action("Open Kaching", .openInbox)]
        if let p = counts?.proposals, p > 0 {
            m.append(.submenu("Proposals waiting: \(p)", proposals.map { pr in
                .submenu(pr.id, [.actionOn(Self.wrap(pr.summary, 60), .showProposal, pr.id),
                                 .separator,
                                 .actionOn("Show…", .showProposal, pr.id),
                                 .actionOn("Approve…", .approveProposal, pr.id),
                                 .actionOn("Reject", .rejectProposal, pr.id),
                                 .actionOn("Snooze 7 days", .snoozeProposal, pr.id)])
            }))
        }
        if recaps.isEmpty {
            m.append(.placeholder("Recaps: none yet"))
        } else {
            var sub: [MenuEntry] = []
            for (i, r) in recaps.enumerated() {
                if i > 0 { sub.append(.separator) }
                sub.append(.text("\(r.session) · \(Self.ago(max(0, Int(now.timeIntervalSince(r.at)))))\n"
                                 + Self.wrap(r.text, 64), .openInbox))
            }
            m.append(.submenu("Recaps (\(recaps.count))", sub))
        }
        m += [.separator, .action("Quit KachingBar", .quit)]
        return m
    }

    /// Breaks text into lines of at most `width` characters, at spaces.
    static func wrap(_ text: String, _ width: Int) -> String {
        var lines: [String] = [], cur = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !cur.isEmpty && cur.count + 1 + word.count > width { lines.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + word
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.joined(separator: "\n")
    }

    static func ago(_ secs: Int) -> String {
        if secs < 90 { return "\(secs)s ago" }
        if secs < 5400 { return "\((secs + 30) / 60)m ago" }
        if secs < 172_800 { return "\((secs + 1800) / 3600)h ago" }
        return "\((secs + 43200) / 86400)d ago"
    }

    /// The --status-once output: stable key=value lines.
    var report: String {
        var lines = [
            "state=\(state.rawValue)",
            "running=\(running ? "yes" : "no")",
            "watcher_installed=\(watcherInstalled ? "yes" : "no")",
            "heartbeat_age=\(heartbeatAge.map(String.init) ?? "none")",
        ]
        if let c = counts {
            lines += ["sessions=\(c.sessions)", "active=\(c.active)", "blocked=\(c.blocked)", "input=\(c.input)",
                      "needs=\(c.needs)", "proposals=\(c.proposals)"]
        } else {
            lines.append("counts=unavailable")
        }
        lines.append("status=\(statusLine)")
        func add(_ entries: [MenuEntry], _ indent: String) {
            for e in entries {
                switch e {
                case .info(let t): lines.append("menu=\(indent)\(t.replacingOccurrences(of: "\n", with: " ")) [info]")
                case .action(let t, _), .text(let t, _): lines.append("menu=\(indent)\(t.replacingOccurrences(of: "\n", with: " "))")
                case .actionOn(let t, let a, let arg):
                    lines.append("menu=\(indent)\(t.replacingOccurrences(of: "\n", with: " ")) [\(a.rawValue) \(arg)]")
                case .submenu(let t, let sub): lines.append("menu=\(indent)\(t) >"); add(sub, indent + "  ")
                case .placeholder(let t): lines.append("menu=\(indent)\(t) [disabled]")
                case .separator: lines.append("menu=\(indent)---")
                }
            }
        }
        add(menu, "")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Provider

protocol StatusProvider: Sendable {
    func snapshot() -> KachingSnapshot
}

final class KachingStatusProvider: StatusProvider {
    let paths: KachingPaths
    let staleAfter: Int
    let dashTimeout: TimeInterval

    init(paths: KachingPaths, staleAfter: Int, dashTimeout: TimeInterval = 5) {
        self.paths = paths; self.staleAfter = staleAfter; self.dashTimeout = dashTimeout
    }

    func snapshot() -> KachingSnapshot {
        let fm = FileManager.default
        let counts = readCounts()
        return KachingSnapshot(watcherInstalled: fm.fileExists(atPath: paths.watchPlist.path)
                                 || fm.fileExists(atPath: paths.oldWatchPlist.path),
                             heartbeatAge: heartbeatAge(now: Date()),
                             staleAfter: staleAfter,
                             counts: counts,
                             proposals: (counts?.proposals ?? 0) > 0 ? readProposals() : [],
                             recaps: readRecaps())
    }

    func readProposals() -> [Proposal] {
        run(paths.proposalsTool, ["list"]).map(Proposal.parse) ?? []
    }

    /// The latest recap of every live interactive session (~/.claude/sessions/<pid>.json, the process alive),
    /// read from the tail of its transcript. Claude-mem's observer sessions are machinery: left out.
    func readRecaps() -> [Recap] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: paths.claudeSessions, includingPropertiesForKeys: nil) else { return [] }
        var out: [Recap] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = o["pid"] as? Int, let sid = o["sessionId"] as? String,
                  (o["kind"] as? String) == "interactive" else { continue }
            let cwd = o["cwd"] as? String ?? ""
            guard !cwd.contains("/.claude-mem/observer-sessions"), kill(pid_t(pid), 0) == 0 || errno == EPERM else { continue }
            guard let (text, at) = Self.lastRecap(transcript(sid: sid, cwd: cwd)) else { continue }
            var name = o["name"] as? String ?? ""
            if name.isEmpty { name = (cwd as NSString).lastPathComponent + " " + sid.prefix(8) }
            out.append(Recap(session: name, text: text, at: at))
        }
        return out.sorted { $0.at > $1.at }
    }

    /// Kaching's meta names the transcript; else Claude Code's project folder: the cwd with every
    /// non-alphanumeric character as '-'.
    func transcript(sid: String, cwd: String) -> URL {
        let meta = (try? String(contentsOf: paths.agentHome.appendingPathComponent("sessions/\(sid)/meta"), encoding: .utf8)) ?? ""
        for line in meta.split(whereSeparator: \.isNewline) where line.hasPrefix("transcript=") {
            return URL(fileURLWithPath: String(line.dropFirst("transcript=".count)))
        }
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return paths.claudeDir.appendingPathComponent("projects/\(folder)/\(sid).jsonl")
    }

    /// The newest away_summary in the last 512 KB of a transcript, without Claude Code's "(disable recaps ...)" hint.
    static func lastRecap(_ url: URL) -> (String, Date)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512 << 10 ? size - (512 << 10) : 0)
        guard let data = try? h.readToEnd() else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.count > 30, String(decoding: line.prefix(4096), as: UTF8.self).contains("\"away_summary\""),
                  let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["subtype"] as? String == "away_summary", var text = o["content"] as? String else { continue }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = text.range(of: "(disable recaps", options: .backwards), text.hasSuffix(")") {
                text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { continue }
            return (text, (o["timestamp"] as? String).flatMap(iso.date(from:)) ?? Date())
        }
        return nil
    }

    /// Seconds since the newest of watch.heartbeat / watch.log was written (a future mtime counts as now).
    func heartbeatAge(now: Date) -> Int? {
        let dates = [paths.heartbeat, paths.watchLog].compactMap { url -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        guard let newest = dates.max() else { return nil }
        return max(0, Int(now.timeIntervalSince(newest)))
    }

    /// `dash.sh --counts`; nil when it fails or times out.
    func readCounts() -> KachingCounts? {
        run(paths.dash, ["--counts"]).flatMap(KachingCounts.parse)
    }

    /// Runs a kit script with bash and AGENT_HOME pinned to ours; its stdout, or nil on any failure or after dashTimeout.
    func run(_ script: URL, _ args: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["AGENT_HOME"] = paths.agentHome.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(dashTimeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); p.waitUntilExit(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Actions

enum TerminalLauncher {
    /// Opens a Terminal window running a script (a .command file: no Apple Events permission needed).
    static func run(name: String, body: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaching-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).command")
        let script = "#!/bin/bash\nclear\n\(body)\necho\necho '(KachingBar: you can close this window)'\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", file.path]
        try? p.run()
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Drags

@MainActor
final class DragWatcher {
    private struct Seen { var frame: CGRect; var display: Int }
    private let paths: KachingPaths
    private var timer: Timer?
    private var settled: [Int: Seen] = [:]   // window number -> where it last stood still
    private var last: [Int: CGRect] = [:]    // window number -> frame at the previous tick

    init(paths: KachingPaths) { self.paths = paths }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    /// Display frames in top-left coordinates (y down from the top of the main display), as Terminal reports them.
    private static func displays() -> [CGRect] {
        let screens = NSScreen.screens
        guard let mainH = screens.first?.frame.height else { return [] }
        return screens.map { CGRect(x: $0.frame.minX, y: mainH - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    private static func display(of f: CGRect, in displays: [CGRect]) -> Int {
        displays.firstIndex(where: { $0.contains(CGPoint(x: f.midX, y: f.midY)) }) ?? -1
    }

    private static func terminalWindows() -> [Int: CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var out: [Int: CGRect] = [:]
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Terminal"
                && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let n = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            out[n] = r
        }
        return out
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons == 0 else { return }   // a drag in progress: wait for the drop
        let displays = Self.displays()
        let now = Self.terminalWindows()
        for (n, f) in now {
            defer { last[n] = f }
            guard last[n] == f else { continue }                 // still moving (or first sight): next tick
            let d = Self.display(of: f, in: displays)
            guard let before = settled[n] else { settled[n] = Seen(frame: f, display: d); continue }
            if before.frame == f { continue }
            settled[n] = Seen(frame: f, display: d)
            if before.display != d && d >= 0 && before.display >= 0 { report(n, before.frame) }
        }
        // a window on a hidden desktop is not on screen: keep where it settled, so coming back is not a move
        for n in Array(last.keys) where now[n] == nil { last[n] = nil }
    }

    private func report(_ n: Int, _ f: CGRect) {
        guard FileManager.default.fileExists(atPath: paths.queue.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [paths.queue.path, "dragged", String(n)] + [f.minX, f.minY, f.width, f.height].map { String(Int($0.rounded())) }
        var vars = ProcessInfo.processInfo.environment
        vars["AGENT_HOME"] = paths.agentHome.path
        p.environment = vars
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - UI

@MainActor
final class StatusBarController: NSObject {
    private let provider: KachingStatusProvider
    private let pollSecs: TimeInterval
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var inFlight = false
    private var snapshot: KachingSnapshot?

    init(provider: KachingStatusProvider, pollSecs: TimeInterval) {
        self.provider = provider; self.pollSecs = pollSecs
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = Self.dot(.grey)
        item.button?.toolTip = "Kaching: checking..."
        item.menu = NSMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollSecs, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 2
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let provider = self.provider
        Task.detached(priority: .utility) {
            let snap = provider.snapshot()
            await self.apply(snap)
        }
    }

    private func apply(_ snap: KachingSnapshot) {
        inFlight = false
        snapshot = snap
        guard let item = statusItem else { return }
        item.button?.image = Self.dot(snap.state)
        item.button?.toolTip = snap.statusLine
        item.button?.setAccessibilityLabel(snap.statusLine)
        item.menu = buildMenu(snap.menu)
    }

    private func buildMenu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in entries {
            switch e {
            case .info(let t), .placeholder(let t):
                let mi = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
            case .action(let t, let a):
                let mi = NSMenuItem(title: t, action: #selector(menuAction(_:)), keyEquivalent: a == .quit ? "q" : "")
                mi.target = self
                mi.representedObject = [a.rawValue]
                menu.addItem(mi)
            case .actionOn(let t, let a, let arg):
                let mi = NSMenuItem(title: t, action: #selector(menuAction(_:)), keyEquivalent: "")
                if t.contains("\n") { mi.attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.menuFont(ofSize: 0)]) }
                mi.target = self
                mi.representedObject = [a.rawValue, arg]
                menu.addItem(mi)
            case .text(let t, let a):
                // first line bold (who and when), the rest in the menu font: an enabled item, so it reads in full contrast
                let mi = NSMenuItem(title: t, action: #selector(menuAction(_:)), keyEquivalent: "")
                let head = t.prefix { $0 != "\n" }
                let s = NSMutableAttributedString(string: t, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                s.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: NSRange(location: 0, length: (head as Substring).utf16.count))
                mi.attributedTitle = s
                mi.target = self
                mi.representedObject = [a.rawValue]
                menu.addItem(mi)
            case .submenu(let t, let sub):
                let mi = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                mi.submenu = buildMenu(sub)
                menu.addItem(mi)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let rep = sender.representedObject as? [String], let raw = rep.first, let a = MenuAction(rawValue: raw) else { return }
        let id = rep.count > 1 ? rep[1] : ""
        let paths = provider.paths
        let env = "export AGENT_HOME=\(TerminalLauncher.quote(paths.agentHome.path))"
        let tool = TerminalLauncher.quote(paths.proposalsTool.path)
        switch a {
        case .openInbox:
            openKaching()
        case .showProposal:
            TerminalLauncher.run(name: "proposal", body: "\(env)\n\(tool) show \(TerminalLauncher.quote(id))")
        case .approveProposal:   // only a person approves: kaching-proposals asks for its typed code in this window
            TerminalLauncher.run(name: "approve", body: "\(env)\n\(tool) approve \(TerminalLauncher.quote(id))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.refresh() }
        case .rejectProposal, .snoozeProposal:
            let args = a == .rejectProposal ? ["reject", id] : ["snooze", id, "7"]
            let provider = self.provider
            Task.detached(priority: .userInitiated) {
                let ok = provider.run(paths.proposalsTool, args) != nil
                await MainActor.run {
                    // on failure, run it again where the owner can read why
                    if !ok { TerminalLauncher.run(name: "proposal", body: "\(env)\n\(tool) \(args.map(TerminalLauncher.quote).joined(separator: " "))") }
                    self.refresh()
                }
            }
        case .quit:
            NSApp.terminate(nil)
        }
    }

    /// kaching-open.sh brings kaching forward or starts it; it talks to Terminal with Apple Events. When that fails
    /// (no Automation permission yet, or the script is missing), kaching starts in a plain new Terminal window.
    private func openKaching() {
        let paths = provider.paths
        Task.detached(priority: .userInitiated) {
            var ok = false
            if FileManager.default.fileExists(atPath: paths.openKaching.path) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [paths.openKaching.path]
                var env = ProcessInfo.processInfo.environment
                env["AGENT_HOME"] = paths.agentHome.path
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 }
            }
            if !ok {
                let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kaching").path
                TerminalLauncher.run(name: "kaching", body: "export AGENT_HOME=\(TerminalLauncher.quote(paths.agentHome.path))\nexec \(TerminalLauncher.quote(bin))")
            }
        }
    }

    /// A small dot: filled green or amber; grey is a hollow template ring (follows the menu bar's appearance).
    static func dot(_ state: DotState) -> NSImage {
        let size = NSSize(width: 18, height: 18), d: CGFloat = 8
        let img = NSImage(size: size, flipped: false) { rect in
            let r = NSRect(x: (rect.width - d) / 2, y: (rect.height - d) / 2, width: d, height: d)
            switch state {
            case .green, .amber:
                (state == .green ? NSColor.systemGreen : NSColor.systemOrange).setFill()
                NSBezierPath(ovalIn: r).fill()
            case .grey:
                NSColor.black.setStroke()
                let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
                p.lineWidth = 1.5
                p.stroke()
            }
            return true
        }
        img.isTemplate = (state == .grey)
        img.accessibilityDescription = "Kaching \(state.rawValue)"
        return img
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: StatusBarController
    private let drags: DragWatcher?

    init(controller: StatusBarController, drags: DragWatcher?) { self.controller = controller; self.drags = drags }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One dot per login: launchd and a manual open must not give two.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil); return
        }
        controller.start()
        drags?.start()
    }
}

// MARK: - Entry

/// The environment, with a variable under its pre-D35 CHING_* name counting when the KACHING_* one is unset.
func kachingEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for (k, v) in env where k.hasPrefix("CHING_") && env["KA" + k] == nil { env["KA" + k] = v }
    return env
}

@main
struct KachingBarMain {
    static func main() {
        let env = kachingEnvironment()
        func num(_ key: String, _ fallback: Int) -> Int {
            if let v = env[key], let n = Int(v), n > 0 { return n }
            return fallback
        }
        let provider = KachingStatusProvider(paths: .fromEnvironment(env), staleAfter: num("KACHING_BAR_STALE_SECS", 660))
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--status-once") {
            print(provider.snapshot().report)
            exit(0)
        }
        if let bad = args.first(where: { !$0.hasPrefix("-psn_") }) {
            FileHandle.standardError.write(Data("KachingBar: unknown argument \(bad) (only --status-once)\n".utf8))
            exit(64)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let drags = (env["KACHING_BAR_DRAGS"] ?? "").lowercased() == "off" ? nil : DragWatcher(paths: .fromEnvironment(env))
            let delegate = AppDelegate(controller: StatusBarController(provider: provider,
                                                                       pollSecs: TimeInterval(num("KACHING_BAR_POLL_SECS", 12))),
                                       drags: drags)
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            _ = delegate
        }
    }
}
