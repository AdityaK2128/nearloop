import AppKit
import Foundation

struct AgentInfo: Identifiable, Hashable {
    let id: String          // the command Kapitsa starts it with, or "custom-…" for one the user added
    let name: String
    let maker: String
    let summary: String
    let symbol: String
    /// How to install it; empty when unknown (a custom agent, or one only Kapitsa's help names).
    let install: String
    let homepage: URL?
    /// Tokens in the agent's first request: its instructions and tool definitions plus a short message.
    let promptEstimate: Int
    /// The agent compacts a conversation only once it reaches this many tokens, so less context than this
    /// can run out before it does.
    var compactsAt: Int? = nil
    /// A user-added agent: the shell command run in the project folder. Nil for an agent Kapitsa starts.
    var command: String? = nil
    var isCustom: Bool { command != nil }
}

/// An agent the user added on the Agents page: any command that talks to an OpenAI- or Anthropic-compatible
/// server. Nearloop runs it in the project folder with the running model's address in its environment.
struct CustomAgent: Codable, Identifiable, Hashable {
    var id = "custom-" + UUID().uuidString.lowercased()
    var name: String
    /// Shell text, e.g. `omp` or `late --model {model}`. Placeholders are filled in at launch (Agents.placeholders).
    var command: String
    /// Extra environment, one KEY=value per line; values may use the same placeholders.
    var environment: String = ""

    /// The executable: the command's first word, with ~ expanded.
    var executable: String {
        let first = command.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return (first as NSString).expandingTildeInPath
    }

    /// KEY=value lines that set a valid variable name; the rest are reported by `invalidLines`.
    var variables: [(key: String, value: String)] {
        environment.split(whereSeparator: \.isNewline).compactMap { CustomAgent.variable(String($0)) }
    }
    var invalidLines: [String] {
        environment.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && CustomAgent.variable($0) == nil }
    }
    private static func variable(_ line: String) -> (key: String, value: String)? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("export ") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard !text.hasPrefix("#"), let equals = text.firstIndex(of: "=") else { return nil }
        let key = String(text[..<equals])
        guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
        var value = String(text[text.index(after: equals)...])
        // A value written quoted, as it would be in a shell file, means the text inside the quotes.
        if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
        return (key, value)
    }

    var info: AgentInfo {
        AgentInfo(id: id, name: name, maker: "Custom agent", summary: "Runs `\(command)` in the project folder, connected to the running model.",
                  symbol: "terminal", install: "", homepage: nil, promptEstimate: 10_000, command: command)
    }
}

enum Agents {
    /// What Nearloop knows about the agents Kapitsa can start. Which of them Kapitsa can start comes from the
    /// engine itself (`kapitsa --help`), so an engine that adds one lists it and an older one hides what it lacks.
    static let known: [AgentInfo] = [
        AgentInfo(id: "claude", name: "Claude Code", maker: "Anthropic", summary: "Anthropic’s agentic coding tool, connected through the Messages API.",
                  symbol: "sparkles", install: "curl -fsSL https://claude.ai/install.sh | bash",
                  homepage: URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview"),
                  promptEstimate: 20_000, compactsAt: 100_000),
        AgentInfo(id: "opencode", name: "OpenCode", maker: "SST", summary: "Open-source coding agent with a full-screen terminal interface.",
                  symbol: "chevron.left.forwardslash.chevron.right", install: "curl -fsSL https://opencode.ai/install | bash",
                  homepage: URL(string: "https://opencode.ai"), promptEstimate: 12_100),
        AgentInfo(id: "codex", name: "Codex CLI", maker: "OpenAI", summary: "OpenAI’s coding agent, connected through the Responses API.",
                  symbol: "terminal", install: "npm install -g @openai/codex",
                  homepage: URL(string: "https://github.com/openai/codex"), promptEstimate: 10_000),
        AgentInfo(id: "pi", name: "Pi", maker: "Mario Zechner", summary: "Minimal, extensible coding agent. Launches with thinking disabled for faster responses.",
                  symbol: "pi", install: "curl -fsSL https://pi.dev/install.sh | sh",
                  homepage: URL(string: "https://pi.dev"), promptEstimate: 5_600),
        AgentInfo(id: "hermes", name: "Hermes", maker: "Nous Research", summary: "Nous Research’s agent for code and everyday tasks, with memory across sessions.",
                  symbol: "bolt", install: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
                  homepage: URL(string: "https://hermes-agent.nousresearch.com"), promptEstimate: 10_000),
        AgentInfo(id: "goose", name: "Goose", maker: "Block", summary: "Open-source agent that edits code, runs commands and uses extensions.",
                  symbol: "bird", install: "brew install block-goose-cli",
                  homepage: URL(string: "https://goose-docs.ai"), promptEstimate: 10_000),
        AgentInfo(id: "aider", name: "aider", maker: "Paul Gauthier", summary: "Pair programming in the terminal that edits files and commits to git.",
                  symbol: "person.2", install: "brew install aider",
                  homepage: URL(string: "https://aider.chat"), promptEstimate: 10_000),
        AgentInfo(id: "copilot", name: "Copilot CLI", maker: "GitHub", summary: "GitHub’s coding agent in the terminal.",
                  symbol: "airplane", install: "npm install -g @github/copilot",
                  homepage: URL(string: "https://github.com/github/copilot-cli"), promptEstimate: 10_000),
    ]
    // OpenCode 1.19 and Pi 1.4 were measured on Kapitsa 0.2.26; the others are estimates. Each is replaced by
    // what this Mac sees on the agent's first launch (`Prefs.agentPrompts`).

    /// The agents Kapitsa can start, by id with the name its help gives, in its order. Read by `refreshSupported`.
    private(set) static var supported: [(id: String, name: String)] = fallback
    private static let fallback: [(id: String, name: String)] = ["claude", "opencode", "codex", "pi"].map { ($0, $0) }

    /// Reads the agents the current engine can start from its help. Keeps the previous list when that fails.
    static func refreshSupported() {
        guard let binary = Kapitsa.binary,
              let help = try? Kapitsa.runSync(binary.path, ["--help"], env: Kapitsa.environment(), timeout: 10).output,
              let parsed = parseSupported(help), !parsed.isEmpty else { return }
        supported = parsed
    }

    /// The help's command list has a line `  claude, codex, opencode, … [--model M] …`; the lines
    /// `  kapitsa <agent>   <Name>` give the names.
    static func parseSupported(_ help: String) -> [(id: String, name: String)]? {
        let lines = help.split(separator: "\n").map(String.init)
        guard let list = lines.first(where: { $0.range(of: "^\\s+[a-z0-9][a-z0-9-]*(, [a-z0-9][a-z0-9-]*)+ \\[--model", options: .regularExpression) != nil })
        else { return nil }
        let ids = list.trimmingCharacters(in: .whitespaces).components(separatedBy: " [")[0].components(separatedBy: ", ")
        return ids.map { id in
            let prefix = "kapitsa \(id) "
            let name = lines.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            return (id, (name?.isEmpty == false ? name : nil) ?? id)
        }
    }

    /// Every agent to show: the ones Kapitsa starts (Nearloop's order for those it knows, then any others), then
    /// the user's own.
    static var catalog: [AgentInfo] {
        let ids = Set(supported.map(\.id))
        var list = known.filter { ids.contains($0.id) }
        for (id, name) in supported where !known.contains(where: { $0.id == id }) {
            list.append(AgentInfo(id: id, name: name, maker: "Supported by Kapitsa", summary: "Started through `kapitsa \(id)`, connected to the running model.",
                                  symbol: "terminal", install: "", homepage: nil, promptEstimate: 10_000))
        }
        return list + Prefs.customAgents.map(\.info)
    }

    static func info(_ id: String) -> AgentInfo? { catalog.first { $0.id == id } }
    static func custom(_ id: String) -> CustomAgent? { Prefs.customAgents.first { $0.id == id } }

    /// The agent's first-request size: measured on this Mac when it has been launched here, else the estimate.
    static func promptTokens(_ id: String) -> (tokens: Int, measured: Bool) {
        if let seen = Prefs.agentPrompts[id] { return (seen, true) }
        return (info(id)?.promptEstimate ?? 10_000, false)
    }

    static func displayName(_ key: String) -> String { catalog.first { $0.id == key }?.name ?? key }

    /// The name the server gives the agent's requests: Kapitsa names clients from their User-Agent, which
    /// usually starts with the program's name.
    static func clientName(_ id: String) -> String {
        guard let custom = custom(id) else { return id }
        return (custom.executable as NSString).lastPathComponent
    }

    /// Installed agents by id, with the executable's path: Kapitsa's on the user's login PATH (`kapitsa <agent>`
    /// starts them from there), and custom ones whose command is found there or at the path given.
    static func installed() -> [String: String] {
        let directories = Kapitsa.loginPath.split(separator: ":").map(String.init)
        func find(_ name: String) -> String? {
            if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
            return directories.first { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }.map { $0 + "/" + name }
        }
        var found: [String: String] = [:]
        for (id, _) in supported { if let path = find(id) { found[id] = path } }
        for agent in Prefs.customAgents where !agent.executable.isEmpty {
            if let path = find(agent.executable) { found[agent.id] = path }
        }
        return found
    }

    static func version(_ path: String) -> String {
        let output = (try? Kapitsa.runSync(path, ["--version"], env: Kapitsa.environment(), timeout: 5))?.output ?? ""
        return output.split(separator: "\n").first.map { String($0.prefix(40)).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The running server as a custom agent sees it, by placeholder.
    struct Server {
        let port: Int
        let apiKey: String
        let model: String
        let context: Int?
        var root: String { "http://127.0.0.1:\(port)" }
        var key: String { apiKey.isEmpty ? "kapitsa" : apiKey }
        var placeholders: [String: String] {
            ["{base_url}": root + "/v1", "{host}": root, "{port}": String(port), "{model}": model,
             "{api_key}": key, "{context}": context.map(String.init) ?? ""]
        }
        /// What most agents read for an OpenAI- or Anthropic-compatible server, set before the user's own variables.
        var standard: [(String, String)] {
            [("OPENAI_BASE_URL", root + "/v1"), ("OPENAI_API_BASE", root + "/v1"), ("OPENAI_API_KEY", key),
             ("ANTHROPIC_BASE_URL", root), ("ANTHROPIC_API_KEY", key),
             ("KAPITSA_BASE_URL", root + "/v1"), ("KAPITSA_API_KEY", key), ("KAPITSA_MODEL", model)]
        }
    }
    static let placeholderHelp: [(String, String)] = [
        ("{base_url}", "http://127.0.0.1:PORT/v1"), ("{host}", "http://127.0.0.1:PORT"), ("{port}", "the port"),
        ("{model}", "the running model’s name"), ("{api_key}", "the API key (kapitsa when none is set)"),
        ("{context}", "the loaded context in tokens"),
    ]

    /// The model a server this app did not start is serving (the first of `/v1/models`).
    static func servedModel(port: Int, apiKey: String) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return nil }
        return models.first?["id"] as? String
    }

    static func fill(_ text: String, _ values: [String: String], quoting: Bool) -> String {
        values.reduce(text) { result, item in result.replacingOccurrences(of: item.key, with: quoting ? quote(item.value) : item.value) }
    }

    static var ghostty: URL? {
        [URL(fileURLWithPath: "/Applications/Ghostty.app"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/ghostty").path) }
    }

    /// Writes a small launcher script and opens it in the user's terminal of choice. Kapitsa's agents start
    /// through `kapitsa <agent>`, which connects them; a custom one runs its own command with the server in its
    /// environment.
    static func launch(_ name: String, project: URL, server: Server) throws {
        let env = Kapitsa.environment()
        var script = "#!/bin/zsh\nset -uo pipefail\n"
        for key in ["PATH", "KAPITSA_NO_AUTO_UPDATE", "KAPITSA_HOME", "HF_HOME", "HF_HUB_CACHE", "XDG_CACHE_HOME"] {
            if let value = env[key] { script += "export \(key)=\(quote(value))\n" }
        }
        let run: String
        if let custom = custom(name) {
            let values = server.placeholders
            for (key, value) in server.standard { script += "export \(key)=\(quote(value))\n" }
            for (key, value) in custom.variables { script += "export \(key)=\(quote(fill(value, values, quoting: false)))\n" }
            // The user's own shell text, with each placeholder filled in as one quoted word.
            run = fill(custom.command, values, quoting: true)
        } else {
            guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
            var command = [binary.path, name, "--port", String(server.port)]
            if !server.apiKey.isEmpty { command += ["--api-key", server.apiKey] }
            if name == "pi" { command += ["--", "--thinking", "off"] }
            run = command.map(quote).joined(separator: " ")
        }
        script += "cd \(quote(project.path))\n"
        script += "clear\nprint -r -- \(quote("\(displayName(name)) on Kapitsa · \(project.lastPathComponent)"))\n"
        // Not exec: when the agent can't start, the window stays open so its message can be read.
        script += run + "\n"
        script += "code=$?\nif (( code != 0 )); then\n"
        script += "  print\n  print -r -- \(quote(displayName(name) + " exited with an error (code"))\" $code). Press Return to close this window.\"\n"
        script += "  read -r\nfi\nexit $code\n"

        let folder = AppPaths.folder("launchers")
        cleanOldLaunchers(folder)
        let file = folder.appendingPathComponent("\(clientName(name).filter { $0.isLetter || $0.isNumber || $0 == "-" })-\(Int(Date().timeIntervalSince1970)).command")
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
