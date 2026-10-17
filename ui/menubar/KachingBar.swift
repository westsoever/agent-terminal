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
// A later TranscriptProvider / notification poster plugs in next to KachingStatusProvider and adds MenuEntry cases.
//
// Signals (no launchctl calls):
//   running  $LAUNCH_AGENTS_DIR/org.kaching.watch.plist exists AND the newest mtime of $AGENT_HOME/watch.heartbeat
//            (rewritten by every kaching-watch.sh tick, every 300 s) or $AGENT_HOME/watch.log is at most
//            KACHING_BAR_STALE_SECS old (default 660: two ticks plus a minute).
//   needs    `dash.sh --counts` (needs = blocked + input over the session registry), run with a 5 s ceiling.
//
// CLI: KachingBar --status-once  prints the computed state as key=value lines and exits (used by tests/t_menubar.sh).
// Env: AGENT_HOME (~/.agent) KACHING_DIR (~/.claude/kaching) LAUNCH_AGENTS_DIR (~/Library/LaunchAgents)
//      KACHING_BAR_STALE_SECS (660) KACHING_BAR_POLL_SECS (12); the CHING_* names from before D35 still count.
//      The watcher counts as installed under its old label org.ching.watch too, until install.sh replaces it.

import AppKit
import Foundation

// MARK: - Paths

struct KachingPaths: Sendable {
    let agentHome: URL
    let kachingDir: URL
    let launchAgentsDir: URL

    var heartbeat: URL { agentHome.appendingPathComponent("watch.heartbeat") }
    var watchLog: URL { agentHome.appendingPathComponent("watch.log") }
    var watchPlist: URL { launchAgentsDir.appendingPathComponent("org.kaching.watch.plist") }
    var oldWatchPlist: URL { launchAgentsDir.appendingPathComponent("org.ching.watch.plist") }   // before D35
    var dash: URL { kachingDir.appendingPathComponent("bin/dash.sh") }
    var proposalsTool: URL { kachingDir.appendingPathComponent("bin/kaching-proposals") }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> KachingPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func dir(_ key: String, _ fallback: String) -> URL {
            if let v = env[key], !v.isEmpty { return URL(fileURLWithPath: v, isDirectory: true) }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        return KachingPaths(agentHome: dir("AGENT_HOME", ".agent"),
                          kachingDir: dir("KACHING_DIR", ".claude/kaching"),
                          launchAgentsDir: dir("LAUNCH_AGENTS_DIR", "Library/LaunchAgents"))
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

enum MenuAction: String, Sendable { case openInbox, openProposals, quit }

enum MenuEntry: Sendable, Equatable {
    case info(String)                      // disabled text line
    case action(String, MenuAction)
    case placeholder(String)               // disabled, for features that are coming
    case separator
}

struct KachingSnapshot: Sendable {
    let watcherInstalled: Bool
    let heartbeatAge: Int?                 // seconds since the watcher last wrote; nil = never
    let staleAfter: Int
    let counts: KachingCounts?               // nil when dash.sh failed or timed out

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
        var m: [MenuEntry] = [.info(statusLine), .info(detailLine), .separator, .action("Open inbox", .openInbox)]
        if let p = counts?.proposals, p > 0 { m.append(.action("Proposals waiting: \(p)", .openProposals)) }
        m.append(.placeholder("Transcripts (coming soon)"))
        m += [.separator, .action("Quit KachingBar", .quit)]
        return m
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
        for e in menu {
            switch e {
            case .info(let t): lines.append("menu=\(t) [info]")
            case .action(let t, _): lines.append("menu=\(t)")
            case .placeholder(let t): lines.append("menu=\(t) [disabled]")
            case .separator: lines.append("menu=---")
            }
        }
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
        return KachingSnapshot(watcherInstalled: fm.fileExists(atPath: paths.watchPlist.path)
                                 || fm.fileExists(atPath: paths.oldWatchPlist.path),
                             heartbeatAge: heartbeatAge(now: Date()),
                             staleAfter: staleAfter,
                             counts: readCounts())
    }

    /// Seconds since the newest of watch.heartbeat / watch.log was written (a future mtime counts as now).
    func heartbeatAge(now: Date) -> Int? {
        let dates = [paths.heartbeat, paths.watchLog].compactMap { url -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        guard let newest = dates.max() else { return nil }
        return max(0, Int(now.timeIntervalSince(newest)))
    }

    /// Runs `dash.sh --counts` with AGENT_HOME pinned to ours; nil on any failure or after dashTimeout.
    func readCounts() -> KachingCounts? {
        guard FileManager.default.fileExists(atPath: paths.dash.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [paths.dash.path, "--counts"]
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
        return KachingCounts.parse(String(decoding: data, as: UTF8.self))
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
                mi.representedObject = a.rawValue
                menu.addItem(mi)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = MenuAction(rawValue: raw) else { return }
        let paths = provider.paths
        let env = "export AGENT_HOME=\(TerminalLauncher.quote(paths.agentHome.path))"
        switch a {
        case .openInbox:
            TerminalLauncher.run(name: "inbox", body: "\(env)\n\(TerminalLauncher.quote(paths.dash.path)) --inbox")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.refresh() }
        case .openProposals:
            TerminalLauncher.run(name: "proposals", body: "\(env)\n\(TerminalLauncher.quote(paths.proposalsTool.path)) list")
        case .quit:
            NSApp.terminate(nil)
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

    init(controller: StatusBarController) { self.controller = controller }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One dot per login: launchd and a manual open must not give two.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil); return
        }
        controller.start()
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
            let delegate = AppDelegate(controller: StatusBarController(provider: provider,
                                                                       pollSecs: TimeInterval(num("KACHING_BAR_POLL_SECS", 12))))
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            _ = delegate
        }
    }
}
