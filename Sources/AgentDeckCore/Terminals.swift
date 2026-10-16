import AppKit
import Foundation

/// Brings a session's own tab to the front: iTerm and Terminal by tty, a tmux pane (then the
/// terminal tab its client is in), kitty and WezTerm by folder. Any other app is just activated.
enum Terminals {
    static let terminalBundleId = "com.apple.Terminal"

    @MainActor
    static func focus(pid: Int32, cwd: String) -> Bool {
        var tty = SessionWindow.tty(of: pid)
        var hostPid = pid
        // Under tmux the session's parents lead to the tmux server, not to a terminal app.
        if let paneTTY = tty, let client = selectTmuxPane(tty: paneTTY) { (tty, hostPid) = (client.tty, client.pid) }
        guard let app = ClaudeCLI.owningApp(pid: hostPid) else { return false }
        switch app.bundleIdentifier {
        case SessionWindow.itermBundleId:
            if let tty, (try? SessionWindow(tty: tty).focus()) != nil { return true }
        case terminalBundleId:
            if let tty, focusTerminalTab(tty: tty) { return true }
        case "net.kovidgoyal.kitty":
            _ = run("kitty", ["@", "focus-window", "--match", "cwd:\(cwd)"], extra: ["/Applications/kitty.app/Contents/MacOS/kitty"])
        case "com.github.wez.wezterm":
            focusWezTermPane(cwd: cwd)
        default: break
        }
        return app.activate()
    }

    @MainActor
    private static func focusTerminalTab(tty: String) -> Bool {
        let source = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t from 1 to count of tabs of w
                    if tty of tab t of w is "\(ClaudeCLI.appleScriptEscape(tty))" then
                        set selected tab of w to tab t of w
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        """
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue == "ok"
    }

    private static func selectTmuxPane(tty: String) -> (tty: String, pid: Int32)? {
        guard let panes = run("tmux", ["list-panes", "-a", "-F", "#{pane_tty} #{session_name} #{window_id} #{pane_id}"]),
              let pane = rows(panes, 4).first(where: { $0[0] == tty }) else { return nil }
        _ = run("tmux", ["select-window", "-t", pane[2]])
        _ = run("tmux", ["select-pane", "-t", pane[3]])
        guard let clients = run("tmux", ["list-clients", "-F", "#{client_tty} #{client_pid} #{client_session}"]),
              let client = rows(clients, 3).first(where: { $0[2] == pane[1] }), let pid = Int32(client[1]) else { return nil }
        return (client[0], pid)
    }

    private static func focusWezTermPane(cwd: String) {
        guard let out = run("wezterm", ["cli", "list", "--format", "json"], extra: ["/Applications/WezTerm.app/Contents/MacOS/wezterm"]),
              let panes = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]],
              let pane = panes.first(where: { (($0["cwd"] as? String).flatMap { URL(string: $0)?.path }) == cwd }),
              let id = pane["pane_id"] as? Int else { return }
        _ = run("wezterm", ["cli", "activate-pane", "--pane-id", "\(id)"], extra: ["/Applications/WezTerm.app/Contents/MacOS/wezterm"])
    }

    private static func rows(_ text: String, _ count: Int) -> [[String]] {
        text.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.filter { $0.count == count }
    }

    /// GUI apps get a bare PATH, so look in the usual install folders.
    private static func run(_ tool: String, _ args: [String], extra: [String] = []) -> String? {
        let candidates = ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "/usr/bin/\(tool)"] + extra
        guard let exe = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
