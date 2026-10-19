// Hotkeys.swift - global hotkeys for AgentTerminalBar (D39), so they work without Raycast.
//
// Each binding runs one of the Raycast script commands in ui/raycast (the same scripts Raycast would run), with
// stdin and stdout closed off from any terminal; the last line it prints flashes next to the dot for 3 seconds.
// Registered with Carbon's RegisterEventHotKey, which needs no Accessibility or Input Monitoring permission.
//
// Bindings: $AGENT_HOME/hotkeys (default ~/.agent/hotkeys) when it exists, else the defaults below. One binding
// per line, `#` starts a comment:   ctrl+option+n   ui/raycast/agent-terminal-next.sh
// Modifiers: ctrl (control), option (opt, alt), cmd (command), shift. Key: a letter, a digit or space.
// The script path is relative to the Agent Terminal folder (~/.claude/agent-terminal) unless it starts with / or ~.
// AGENT_TERMINAL_BAR_HOTKEYS=off turns them all off.

import AppKit
import Carbon.HIToolbox

struct HotkeyBinding: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let script: String
    let spec: String

    static let defaults = """
    ctrl+option+n  ui/raycast/agent-terminal-next.sh
    ctrl+option+t  ui/raycast/agent-terminal-tile.sh
    ctrl+option+k  ui/raycast/agent-terminal-open.sh
    """

    private static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space,
    ]

    /// The bindings text: $AGENT_HOME/hotkeys when it exists, else the defaults.
    static func text(agentHome: URL) -> String {
        (try? String(contentsOf: agentHome.appendingPathComponent("hotkeys"), encoding: .utf8)) ?? defaults
    }

    /// For `AgentTerminalBar --hotkeys-check`: "key=<code> mods=<carbon mask> script=<path>" per binding, "bad=<text>" per
    /// line that does not parse.
    static func check(agentHome: URL) -> String {
        let p = parse(text(agentHome: agentHome))
        return (p.bindings.map { "key=\($0.keyCode) mods=\($0.modifiers) script=\($0.script)" } + p.bad.map { "bad=\($0)" })
            .joined(separator: "\n")
    }

    /// Parses the bindings text; lines that do not parse are skipped (and named in `bad`).
    static func parse(_ text: String) -> (bindings: [HotkeyBinding], bad: [String]) {
        var out: [HotkeyBinding] = [], bad: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !parts.isEmpty else { continue }
            guard parts.count >= 2 else { bad.append(line.trimmingCharacters(in: .whitespaces)); continue }
            var mods: UInt32 = 0, key: UInt32?
            for tok in parts[0].lowercased().split(separator: "+").map(String.init) {
                switch tok {
                case "ctrl", "control": mods |= UInt32(controlKey)
                case "option", "opt", "alt": mods |= UInt32(optionKey)
                case "cmd", "command": mods |= UInt32(cmdKey)
                case "shift": mods |= UInt32(shiftKey)
                default: if let k = keys[tok], key == nil { key = UInt32(k) } else { key = nil; mods = 0 }
                }
            }
            guard let k = key, mods != 0 else { bad.append(parts[0]); continue }
            out.append(HotkeyBinding(keyCode: k, modifiers: mods, script: parts[1...].joined(separator: " "), spec: parts[0]))
        }
        return (out, bad)
    }
}

@MainActor
final class Hotkeys {
    private static var current: Hotkeys?
    private let paths: AgentTerminalPaths
    private let flash: @MainActor @Sendable (String) -> Void
    private var bindings: [UInt32: HotkeyBinding] = [:]
    private var refs: [EventHotKeyRef] = []

    init(paths: AgentTerminalPaths, flash: @escaping @MainActor @Sendable (String) -> Void) { self.paths = paths; self.flash = flash }

    func start() {
        let parsed = HotkeyBinding.parse(HotkeyBinding.text(agentHome: paths.agentHome))
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            MainActor.assumeIsolated { Hotkeys.current?.fire(id.id) }
            return noErr
        }, 1, &spec, nil, nil)
        var taken: [String] = []
        for (i, b) in parsed.bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4B434847), id: UInt32(i + 1))   // 'KCHG'
            if RegisterEventHotKey(b.keyCode, b.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let r = ref {
                refs.append(r); bindings[id.id] = b
            } else { taken.append(b.spec) }
        }
        if !parsed.bad.isEmpty { flash("hotkeys: can't read \(parsed.bad.joined(separator: ", "))") }
        else if !taken.isEmpty { flash("hotkeys: \(taken.joined(separator: ", ")) taken by another app") }
    }

    private func fire(_ id: UInt32) {
        VoiceKeys.cancelChord()   // a hotkey's key press never reaches the voice shortcut's monitors (VoiceShortcut.swift)
        guard let b = bindings[id] else { return }
        var path: String
        if b.script.hasPrefix("/") { path = b.script }
        else if b.script.hasPrefix("~/") { path = NSHomeDirectory() + String(b.script.dropFirst(1)) }
        else { path = paths.agentTerminalDir.appendingPathComponent(b.script).path }
        // a hotkeys file written before D64 names ui/raycast/kaching-*.sh: the same script is agent-terminal-*.sh now
        if !FileManager.default.fileExists(atPath: path), let r = path.range(of: "/kaching-", options: .backwards) {
            path.replaceSubrange(r, with: "/agent-terminal-")
        }
        let flash = self.flash
        let home = paths.agentHome.path
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [path]
            var vars = ProcessInfo.processInfo.environment
            vars["AGENT_HOME"] = home
            p.environment = vars
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { Task { @MainActor in flash("can't run \(b.script)") }; return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            if !line.isEmpty { Task { @MainActor in flash(line) } }
        }
    }
}
