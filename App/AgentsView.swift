import SwiftUI

struct AgentsView: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @State private var commandState = Kapitsa.commandState
    @AppStorage("agentModelPath") private var agentModelPath = ""
    /// The custom agent being added or edited.
    @State private var editing: CustomAgent?

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
                    ForEach(store.agentCatalog) { agent in
                        AgentCard(agent: agent, store: store) { editing = Agents.custom(agent.id) }
                    }
                    addAgentCard
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "From the Terminal",
                              detail: "Other apps connect with the address and key shown on Home.")
                terminalCard
            }
        }
        .onAppear { commandState = Kapitsa.commandState }
        .sheet(item: $editing) { agent in
            CustomAgentEditor(agent: agent, savedName: Agents.custom(agent.id)?.name,
                              save: { store.saveCustomAgent($0) }, remove: { store.removeCustomAgent(agent.id) })
        }
    }

    private var addAgentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentColor.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Your Own").font(.title3.weight(.semibold))
                    Text("Any agent that works with an OpenAI- or Anthropic-compatible server").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Give it a name and the command that starts it. It opens in the project folder with the running model’s address and key set.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
            HStack {
                Button { editing = CustomAgent(name: "", command: "") } label: { Label("Add Agent…", systemImage: "plus") }
                    .controlSize(.large)
                Spacer()
            }
        }.frame(minHeight: 196, alignment: .top).card()
    }

    /// "`kapitsa claude`, `kapitsa codex` or `kapitsa pi`", from the agents this engine starts.
    private var commandList: String {
        let names = store.agentCatalog.filter { !$0.isCustom }.map { "`kapitsa \($0.id)`" }
        guard names.count > 1 else { return names.first ?? "`kapitsa claude`" }
        return names.dropLast().joined(separator: ", ") + " or " + names.last!
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
        return model.name + String(format: "  (%.0f tok/s)", result.writing ?? 0)
    }

    private var binOnPath: Bool {
        let bin = Kapitsa.commandURL.deletingLastPathComponent().path
        return Kapitsa.shellPath.split(separator: ":").map(String.init).contains(bin)
    }

    private var terminalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Command-Line Tool", systemImage: "apple.terminal").font(.headline)
            Text("Installs `kapitsa` to ~/.local/bin. Run \(commandList) in any project to start an agent on the running model.")
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
    var edit: () -> Void = {}
    @ObservedObject var server = ServerController.shared
    @State private var confirmRemove = false

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
                if agent.isCustom {
                    Menu {
                        Button("Edit…", action: edit)
                        Button("Remove…", role: .destructive) { confirmRemove = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Edit or Remove")
                }
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
            } else if let command = agent.command {
                VStack(alignment: .leading, spacing: 8) {
                    Label("`\(Agents.custom(agent.id)?.executable ?? command)` was not found on your PATH. Install the agent, or edit the command to give its full path.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Edit…", action: edit).controlSize(.small)
                        Spacer()
                        Button("Refresh") { Task { await store.scan() } }.controlSize(.small)
                    }
                }
            } else if agent.install.isEmpty {
                HStack {
                    Text("Install `\(agent.id)`, then click Refresh.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await store.scan() } }.controlSize(.small)
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
                        if let homepage = agent.homepage { Link("Website ↗", destination: homepage).font(.caption) }
                        Spacer()
                        Button("Refresh") { Task { await store.scan() } }.controlSize(.small)
                    }
                }
            }
        }.frame(minHeight: 196, alignment: .top).card()
        .confirmationDialog("Remove \(agent.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeCustomAgent(agent.id) }
        } message: { Text("It leaves the Agents page. The agent itself stays installed.") }
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
        if agent.isCustom { return "installed" }
        let text = store.agentVersions[agent.id] ?? ""
        return text.split(separator: " ").first.map { "v" + String($0) } ?? "installed"
    }
}

/// Adds or edits a custom agent: a name, the command that starts it, and any environment it needs.
private struct CustomAgentEditor: View {
    @State var agent: CustomAgent
    /// The name it was saved under; nil while adding a new one.
    let savedName: String?
    let save: (CustomAgent) -> Void
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    private var isNew: Bool { savedName == nil }

    private var valid: Bool {
        !agent.name.trimmingCharacters(in: .whitespaces).isEmpty && !agent.executable.isEmpty && agent.invalidLines.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(savedName.map { "Edit \($0)" } ?? "Add an Agent").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $agent.name, prompt: Text("OMP"))
                TextField("Command", text: $agent.command, prompt: Text("omp"))
                    .font(.system(.body, design: .monospaced))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Environment")
                    TextEditor(text: $agent.environment)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    Text("Optional. One KEY=value per line, for agents that need more than the variables below.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !agent.invalidLines.isEmpty {
                        Text("Not KEY=value: " + agent.invalidLines.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 6) {
                Text("The agent starts in the project folder with OPENAI_BASE_URL, OPENAI_API_KEY, ANTHROPIC_BASE_URL and ANTHROPIC_API_KEY pointing at the running model, which most agents read. If yours reads its own settings file instead, point that at the server address shown on Home. In the command and the environment, these are filled in at launch:")
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(Agents.placeholderHelp, id: \.0) { item in
                        GridRow {
                            Text(item.0).font(.system(.caption, design: .monospaced))
                            Text(item.1)
                        }
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                if !isNew { Button("Remove…", role: .destructive) { confirmRemove = true } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    agent.name = agent.name.trimmingCharacters(in: .whitespaces)
                    agent.command = agent.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(agent)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .confirmationDialog("Remove \(savedName ?? agent.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { remove(); dismiss() }
        } message: { Text("It leaves the Agents page. The agent itself stays installed.") }
    }
}
