import AppKit
import Foundation

struct AgentInfo: Identifiable, Hashable {
    let id: String          // the command, and Kapitsa's agent name
    let name: String
    let maker: String
    let summary: String
    let symbol: String
    let install: String
    let homepage: URL
    /// Tokens in the agent's first request: its instructions and tool definitions plus a short message.
    let promptEstimate: Int
    /// The agent compacts a conversation only once it reaches this many tokens, so less context than this
    /// can run out before it does.
    var compactsAt: Int? = nil
}

enum Agents {
    static let catalog: [AgentInfo] = [
        AgentInfo(id: "claude", name: "Claude Code", maker: "Anthropic", summary: "Anthropic’s agentic coding tool, connected through the Messages API.",
                  symbol: "sparkles", install: "curl -fsSL https://claude.ai/install.sh | bash",
                  homepage: URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!,
                  promptEstimate: 20_000, compactsAt: 100_000),
        AgentInfo(id: "opencode", name: "OpenCode", maker: "SST", summary: "Open-source coding agent with a full-screen terminal interface.",
                  symbol: "chevron.left.forwardslash.chevron.right", install: "curl -fsSL https://opencode.ai/install | bash",
                  homepage: URL(string: "https://opencode.ai")!, promptEstimate: 12_100),
        AgentInfo(id: "codex", name: "Codex CLI", maker: "OpenAI", summary: "OpenAI’s coding agent, connected through the Responses API.",
                  symbol: "terminal", install: "npm install -g @openai/codex",
                  homepage: URL(string: "https://github.com/openai/codex")!, promptEstimate: 10_000),
        AgentInfo(id: "pi", name: "Pi", maker: "Mario Zechner", summary: "Minimal, extensible coding agent. Launches with thinking disabled for faster responses.",
                  symbol: "pi", install: "curl -fsSL https://pi.dev/install.sh | sh",
                  homepage: URL(string: "https://pi.dev")!, promptEstimate: 5_600),
    ]
    // OpenCode 1.19 and Pi 1.4 were measured on Kapitsa 0.2.26; Claude Code and Codex are estimates. Each is
    // replaced by what this Mac sees on the agent's first launch (`Prefs.agentPrompts`).

    static func info(_ id: String) -> AgentInfo? { catalog.first { $0.id == id } }

    /// The agent's first-request size: measured on this Mac when it has been launched here, else the estimate.
    static func promptTokens(_ id: String) -> (tokens: Int, measured: Bool) {
        if let seen = Prefs.agentPrompts[id] { return (seen, true) }
        return (info(id)?.promptEstimate ?? 10_000, false)
    }
    static var all: [String] { catalog.map(\.id) }

    static func displayName(_ key: String) -> String { catalog.first { $0.id == key }?.name ?? key }

    /// Agents on the user's login PATH (Kapitsa's `kapitsa <agent>` starts them from there).
    static func installed() -> [String: String] {
        let directories = Kapitsa.loginPath.split(separator: ":").map(String.init)
        var found: [String: String] = [:]
        for name in all {
            if let dir = directories.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }) { found[name] = dir + "/" + name }
        }
        return found
    }

    static func version(_ path: String) -> String {
        let output = (try? Kapitsa.runSync(path, ["--version"], env: Kapitsa.environment(), timeout: 5))?.output ?? ""
        return output.split(separator: "\n").first.map { String($0.prefix(40)).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static var ghostty: URL? {
        [URL(fileURLWithPath: "/Applications/Ghostty.app"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/ghostty").path) }
    }

    /// Writes a small launcher script and opens it in the user's terminal of choice.
    static func launch(_ name: String, project: URL, port: Int, apiKey: String) throws {
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        var command = [binary.path, name, "--port", String(port)]
        if !apiKey.isEmpty { command += ["--api-key", apiKey] }
        if name == "pi" { command += ["--", "--thinking", "off"] }
        let env = Kapitsa.environment()
        var script = "#!/bin/zsh\nset -uo pipefail\n"
        for key in ["PATH", "KAPITSA_NO_AUTO_UPDATE", "KAPITSA_HOME", "HF_HOME", "HF_HUB_CACHE", "XDG_CACHE_HOME"] {
            if let value = env[key] { script += "export \(key)=\(quote(value))\n" }
        }
        script += "cd \(quote(project.path))\n"
        script += "clear\nprint \(quote("\(displayName(name)) on Kapitsa · \(project.lastPathComponent)"))\n"
        // Not exec: when the agent can't start, the window stays open so its message can be read.
        script += command.map(quote).joined(separator: " ") + "\n"
        script += "code=$?\nif (( code != 0 )); then\n"
        script += "  print\n  print -r -- \(quote(displayName(name) + " exited with an error (code"))\" $code). Press Return to close this window.\"\n"
        script += "  read -r\nfi\nexit $code\n"

        let folder = AppPaths.folder("launchers")
        cleanOldLaunchers(folder)
        let file = folder.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        Prefs.rememberProject(project.path)

        if Prefs.terminal == "ghostty", let ghostty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", ghostty.path, "--args", "--window-save-state=never",
                                 "--quit-after-last-window-closed=true", "--wait-after-command=true",
                                 "--title=\(displayName(name)) · \(project.lastPathComponent)",
                                 "--working-directory=\(project.path)", "-e", "/bin/zsh", file.path]
            try process.run()
        } else {
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleanOldLaunchers(_ folder: URL) {
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
