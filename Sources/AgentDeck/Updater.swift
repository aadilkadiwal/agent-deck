import Foundation
import AgentDeckCore

/// Checks the source checkout the installer built from (path saved in ~/.claude/agent-deck/source-path)
/// for new commits on its remote, and updates by pulling them and re-running the installer.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var status = "Checking…"
    @Published private(set) var updatesAvailable = 0
    @Published private(set) var incoming: [String] = []
    @Published private(set) var busy = false

    private var source: String? {
        (try? String(contentsOf: ClaudePaths().appDir.appendingPathComponent("source-path"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func check() {
        guard let src = source, FileManager.default.fileExists(atPath: src + "/.git") else {
            status = "This copy wasn't installed with git. Run install.sh again to update."
            return
        }
        busy = true
        Task {
            defer { busy = false }
            guard (try? await Self.git(src, "rev-parse", "--abbrev-ref", "@{u}")) != nil else {
                status = "You're up to date."
                return
            }
            _ = try? await Self.git(src, "fetch", "--quiet")
            let count = Int((try? await Self.git(src, "rev-list", "--count", "HEAD..@{u}")) ?? "0") ?? 0
            updatesAvailable = count
            incoming = count == 0 ? [] : ((try? await Self.git(src, "log", "--format=%s", "HEAD..@{u}")) ?? "")
                .split(separator: "\n").map(String.init)
            status = count == 0 ? "Up to date." : "Update available: \(Fmt.count(count, "new change"))."
        }
    }

    /// The installer quits and reopens the app, so on success this is the last thing it does.
    func update() {
        guard let src = source else { return }
        busy = true
        Task {
            // A pull into a checkout with local edits could fail halfway or build something unexpected.
            if let dirty = try? await Self.git(src, "status", "--porcelain"), !dirty.isEmpty {
                status = "Your source folder has changes that aren't committed. Commit or stash them, then update."
                busy = false
                return
            }
            status = "Updating. Agent Deck restarts when it's done."
            do {
                _ = try await Self.git(src, "pull", "--ff-only", "--quiet")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [src + "/install.sh"]
                p.currentDirectoryURL = URL(fileURLWithPath: src)
                p.terminationHandler = { p in
                    let code = p.terminationStatus
                    guard code != 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.status = "Update failed: install.sh exited with code \(code). Run it in Terminal to see why."
                        self?.busy = false
                    }
                }
                try p.run()
            } catch {
                status = "The update didn't work. \(error.localizedDescription)"
                busy = false
            }
        }
    }

    private static func git(_ dir: String, _ args: String...) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            // Never wait on a password or host-key prompt nobody can see.
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try p.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(p.terminationStatus)) }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
