import SwiftUI

struct AgentsView: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @State private var commandState = Kapitsa.commandState
    @AppStorage("agentModelPath") private var agentModelPath = ""

    var body: some View {
        PageScaffold(title: "Coding Agents", subtitle: "Set up and launch coding agents on the local model. If no model is running, the default model loads first.") {
            HowItWorks("How Coding Agents Work", key: "agents", steps: [
                .init(symbol: "sparkles", title: "What an agent is",
                      text: "An AI assistant for code that runs in a terminal, inside a project folder. It reads your files, edits them and runs commands while you chat with it."),
                .init(symbol: "arrow.down.circle", title: "Install one",
                      text: "Agents are free apps made by others. Copy an install command below, paste it in Terminal, then click Refresh."),
                .init(symbol: "folder", title: "Open a project",
                      text: "Click Open Project and pick a folder. Nearloop loads the default model and opens a terminal with the agent already connected to it."),
                .init(symbol: "lock.shield", title: "Private and free",
                      text: "These agents normally talk to a paid cloud model. Here they use the model on your Mac: no account, no per-token cost, and your code stays local."),
            ])
            modelCard
            if let launching = store.launching {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(launching).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Agents", detail: "Opens in \(terminalName)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(Agents.catalog) { AgentCard(agent: $0, store: store) }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "From the Terminal",
                              detail: "Other apps connect with the address and key shown on Home.")
                terminalCard
            }
        }
        .onAppear { commandState = Kapitsa.commandState }
    }

    private var terminalName: String { Prefs.terminal == "ghostty" && Agents.ghostty != nil ? "Ghostty" : "Terminal" }

    private var modelCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Default Model").font(.headline)
                Text("Loaded automatically when an agent launches.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Picker("Default Model", selection: $agentModelPath) {
                Text(automaticLabel).tag("")
                Divider()
                ForEach(store.runnable) { model in
                    Text(label(for: model)).tag(model.path)
                }
            }.labelsHidden().frame(minWidth: 200, idealWidth: 320, maxWidth: 320)
        }.card()
    }

    private var automaticLabel: String {
        guard let model = store.agentModel else { return "Automatic" }
        return "Automatic (\(model.name))"
    }

    private func label(for model: LocalModel) -> String {
        guard let result = store.benchmark(for: model) else { return model.name }
        guard result.toolsPass else { return model.name + "  (no tool calling)" }
        guard let speed = result.writing else { return model.name }
        return model.name + String(format: "  (%.0f tok/s)", speed)
    }

    private var binOnPath: Bool {
        let bin = Kapitsa.commandURL.deletingLastPathComponent().path
        return Kapitsa.shellPath.split(separator: ":").map(String.init).contains(bin)
    }

    private var terminalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Command-Line Tool", systemImage: "apple.terminal").font(.headline)
            Text("Installs `kapitsa` to ~/.local/bin. Run `kapitsa claude`, `kapitsa opencode`, `kapitsa codex` or `kapitsa pi` in any project to start an agent on the running model.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                switch commandState {
                case "installed": Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case "kapitsa": Label("Kapitsa is installed in ~/.local/bin", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                case "foreign": Label("Conflicting command in ~/.local/bin", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                default: EmptyView()
                }
                Spacer()
                Button(commandState == "installed" ? "Reinstall" : commandState == "outdated" ? "Update" : "Install") {
                    do {
                        try Kapitsa.installCommand()
                        commandState = Kapitsa.commandState
                        store.notice = "Command-line tool installed. Open a new terminal window to use it."
                    } catch { store.errorMessage = error.localizedDescription }
                }.disabled(commandState == "foreign" || commandState == "kapitsa")
            }
            if commandState == "kapitsa" {
                Text("That is Kapitsa itself, from its own installer, so `kapitsa claude` and the others already work. It runs that Kapitsa; choose it in Settings › Engine to use it in Nearloop too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !binOnPath {
                Text("~/.local/bin is not on your PATH. Add `export PATH=\"$HOME/.local/bin:$PATH\"` to ~/.zshrc.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

}

private struct AgentCard: View {
    let agent: AgentInfo
    @ObservedObject var store: AppStore
    @ObservedObject var server = ServerController.shared

    var body: some View {
        let installed = store.agents[agent.id] != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AgentIcon(agent: agent, active: installed, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.title3.weight(.semibold))
                    Text(agent.maker + (installed ? "  ·  " + version : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Installed") }
            }
            Text(agent.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            if installed { contextNote }
            if installed {
                HStack(spacing: 8) {
                    Button { store.launch(agent.id) } label: { Label("Open Project…", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.launching != nil)
                    let recent = Prefs.recentProjects
                    if !recent.isEmpty {
                        Menu {
                            ForEach(recent, id: \.self) { project in
                                Button(project.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) {
                                    store.launch(agent.id, project: URL(fileURLWithPath: project))
                                }
                            }
                        } label: { Label("Recent", systemImage: "clock.arrow.circlepath") }
                            .fixedSize().controlSize(.large).disabled(store.launching != nil)
                    }
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(agent.install).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { store.copy(agent.install, "Install command copied.") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy Install Command")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    HStack {
                        Link("Website ↗", destination: agent.homepage).font(.caption)
                        Spacer()
                        Button("Refresh") { Task { await store.scan() } }.controlSize(.small)
                    }
                }
            }
        }.frame(minHeight: 196, alignment: .top).card()
    }

    /// How much context the agent's prompt takes, against the loaded model when there is one.
    @ViewBuilder private var contextNote: some View {
        if let fit = store.contextFit(agent.id) {
            Label(fit.message, systemImage: fit.level == .fits ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(fit.level == .fits ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let (need, measured) = Agents.promptTokens(agent.id)
            Label("Needs \(measured ? "" : "about ")\(shortTokens(need)) tokens of context for its first request" +
                  (agent.compactsAt.map { "; works best with \(shortTokens($0)) or more" } ?? "") + ".", systemImage: "text.alignleft")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var version: String {
        let text = store.agentVersions[agent.id] ?? ""
        return text.split(separator: " ").first.map { "v" + String($0) } ?? "installed"
    }
}
