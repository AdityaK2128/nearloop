import AppKit
import ServiceManagement
import SwiftUI

/// Settings, as a page of the main window: categories on the left, the chosen one's form on the right.
struct SettingsPage: View {
    enum Category: String, CaseIterable, Identifiable {
        case general, shortcut, chat, server, memory, storage, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .shortcut: return "Quick Chat"
            case .chat: return "Web Search"
            case .server: return "Server"
            case .memory: return "Memory"
            case .storage: return "Storage"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .shortcut: return "command"
            case .chat: return "globe"
            case .server: return "server.rack"
            case .memory: return "memorychip"
            case .storage: return "externaldrive"
            case .about: return "info.circle"
            }
        }
    }

    @AppStorage("settingsCategory") private var category = Category.general.rawValue

    var body: some View {
        // One title and a row of tabs, like Discover: the app's sidebar is the only sidebar.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(.system(size: 28, weight: .bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Category.allCases) { item in
                            let selected = category == item.rawValue
                            Button { category = item.rawValue } label: {
                                Label(item.title, systemImage: item.symbol)
                                    .font(.callout.weight(selected ? .semibold : .regular))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
                                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            // Lined up with the forms' rows, which sit 20 points inside their own width.
            .padding(.horizontal, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.top, 28).padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            Group {
                switch Category(rawValue: category) ?? .general {
                case .general: GeneralSettings()
                case .shortcut: QuickChatSettings()
                case .chat: ChatSettings()
                case .server: ServerSettings()
                case .memory: MemorySettings()
                case .storage: StorageSettings()
                case .about: AboutSettings()
                }
            }
            // The forms blend into the page instead of drawing their own background under the title bar.
            .scrollContentBackground(.hidden)
            .modifier(NoTopScrollEdge())
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// macOS 26 and later blur scrolled content under the title bar; on a settings form that reads as an empty bar.
private struct NoTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.scrollEdgeEffectHidden(true, for: .top) } else { content }
    }
}

/// "Settings…" in the app menu (⌘,) and the menu bar: opens the Settings page in the main window.
struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            AppStore.shared.page = .settings
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",", modifiers: .command)
    }
}

struct GeneralSettings: View {
    @AppStorage("terminalApp") private var terminal = "terminal"
    @AppStorage("autoStartLastModel") private var autoStart = false
    @AppStorage(Page.experimentalKey) private var experimental = false
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { loginItem }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch { AppStore.shared.errorMessage = error.localizedDescription }
                    loginItem = SMAppService.mainApp.status == .enabled
                }))
                Toggle("Load Last Model at Launch", isOn: $autoStart)
                Picker("Terminal Application", selection: $terminal) {
                    Text("Terminal").tag("terminal")
                    Text(Agents.ghostty == nil ? "Ghostty (Not Installed)" : "Ghostty").tag("ghostty")
                }
            } footer: {
                Text("Nearloop keeps running in the menu bar when its window is closed, so the server and the Quick Chat shortcut stay available.")
            }
            Section {
                Toggle("Show Experimental Features", isOn: Binding(get: { experimental }, set: { on in
                    experimental = on
                    if !on, AppStore.shared.page.section == "Experimental" { AppStore.shared.page = .settings }
                }))
            } footer: {
                Text("Adds an Experimental section to the sidebar with features that are still being tested, such as iPhone Offload. They need extra setup and may change or be removed.")
            }
            UpdateSettings()
        }.formStyle(.grouped)
    }
}

struct ServerSettings: View {
    @AppStorage("port") private var port = 8000
    @AppStorage("slots") private var slots = 1
    @AppStorage("diskCache") private var diskCache = "auto"
    @AppStorage("shareOnNetwork") private var share = false
    @AppStorage("apiKey") private var apiKey = ""

    var body: some View {
        Form {
            TextField("Port", value: $port, format: .number.grouping(.never))
            Picker("Concurrent Requests", selection: $slots) {
                Text("Automatic (up to 4)").tag(0)
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Text("Requests beyond this wait their turn. Each one in flight keeps its own conversation in memory, so more of them means less context each. Choose 2 or more to let two agents or apps work at the same time.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Prompt Cache (SSD)", selection: $diskCache) {
                Text("Automatic").tag("auto"); Text("2 GB").tag("2G"); Text("8 GB").tag("8G"); Text("16 GB").tag("16G"); Text("Off").tag("0")
            }
            Toggle("Allow Network Access", isOn: $share)
            SecureField("API Key", text: $apiKey, prompt: Text("Optional"))
            Text(share && apiKey.isEmpty ? "The server is reachable on your local network without authentication. Set an API key to require one."
                 : "Agents and Chat use the key automatically. Changes take effect on next model load.")
                .font(.caption).foregroundStyle(share && apiKey.isEmpty ? .orange : .secondary)
        }.formStyle(.grouped)
    }
}

struct MemorySettings: View {
    @AppStorage("protectMemory") private var protect = true
    @AppStorage("memoryMargin") private var margin = 2.0

    var body: some View {
        Form {
            Toggle("Memory Protection", isOn: $protect)
            Slider(value: $margin, in: 1...8, step: 0.5) { Text("Reserved for Other Apps: \(margin, specifier: "%.1f") GB") }.disabled(!protect)
            Text("Sizes Kapitsa’s memory budget around what your other apps are using, keeping this reserve free, so a model never drives macOS into heavy swapping. Models that don’t fit are declined with an explanation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent("System Memory", value: String(format: "%.0f GB total · %.0f GB available", SystemMemory.totalGB, SystemMemory.availableGB()))
        }.formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @AppStorage("runtimeFolder") private var runtime = ""

    var body: some View {
        Form {
            LabeledContent("Data Location") {
                HStack {
                    Text(runtime.isEmpty ? "~/.cache/kapitsa (default)" : runtime).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { runtime = url.path; Task { await AppStore.shared.scan() } }
                    }
                    if !runtime.isEmpty { Button("Reset") { runtime = ""; Task { await AppStore.shared.scan() } } }
                }
            }
            Text("Stores downloads, converted models, prompt caches and temporary files. An external drive saves internal storage.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Chats") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support.appendingPathComponent("Chats")])
                }
            }
        }.formStyle(.grouped)
    }
}

struct AboutSettings: View {
    @AppStorage("enginePath") private var engine = ""
    @State private var version = "…"
    @State private var installed: [URL] = []
    /// The last answer of `kapitsa update --check`, asked when the pane opens and after an update.
    @State private var check: Kapitsa.UpdateCheck?
    @State private var updating = false
    /// How the last update ended, in the engine's own words, until the next check.
    @State private var updateResult: String?

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private func short(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
    /// The chosen engine is gone (uninstalled, or on a drive that is not connected): the bundled copy stands in.
    private var chosenMissing: Bool { !engine.isEmpty && !FileManager.default.isExecutableFile(atPath: engine) }

    var body: some View {
        Form {
            LabeledContent("Nearloop", value: "\(Updater.currentVersion) (\(Updater.currentBuild))")
            Section {
                Picker("Engine", selection: $engine) {
                    Text(Kapitsa.bundled == nil ? "Bundled (not in this build)" : "Bundled").tag("")
                    ForEach(installed, id: \.path) { Text(short($0.path)).tag($0.path) }
                    if !engine.isEmpty, !installed.contains(where: { $0.path == engine }) { Text(short(engine)).tag(engine) }
                }
                LabeledContent("Engine Version", value: version)
                LabeledContent("Engine Path", value: Kapitsa.binary?.path ?? "Not Found")
                LabeledContent("Engine Update") {
                    HStack(spacing: 8) {
                        if updating { ProgressView().controlSize(.small) }
                        Text(updateStatus).foregroundStyle(updateStatusColor)
                    }
                }
                HStack {
                    Button("Choose…") { choose() }
                    Button("Rescan") { Kapitsa.refreshShellPath(); scan() }
                    Spacer()
                    Button("Check for Updates") { checkForUpdate() }.disabled(updating || !Kapitsa.updatable)
                    Button(updating ? "Updating…" : "Update") { update() }
                        .disabled(updating || !Kapitsa.updatable || check == nil || { if case .upToDate = check { return true } else { return false } }())
                }
            } footer: {
                Text(chosenMissing
                     ? "\(short(engine)) is not an executable file; the bundled engine stands in until it is back."
                     : "A Kapitsa installed with Homebrew, or one you built yourself, takes the bundled copy's place for the server, downloads, imports, benchmarks and the coding agents. It is used from the next model load on; a running model keeps the engine it started with. The engine never updates itself while Nearloop runs it; Update runs its own `kapitsa update` — Homebrew's `brew upgrade` for a Homebrew install, Kapitsa's download from GitHub otherwise. The bundled engine changes only with the app.")
                    .foregroundStyle(chosenMissing ? .orange : .secondary)
            }
            Text("Powered by Kapitsa, the open-source inference engine for Apple silicon by Nace AI, licensed under the Apache License 2.0. License and notices are included in the app bundle. This app is independent of the Kapitsa project. Chat’s web search follows the design of oMLX’s, also under the Apache License 2.0.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Kapitsa on GitHub", destination: URL(string: "https://github.com/nace-ai/kapitsa")!)
                Link("Published Benchmarks", destination: URL(string: "https://github.com/nace-ai/kapitsa#benchmarks")!)
                Link("Nearloop on GitHub", destination: Updater.releasesPage.deletingLastPathComponent())
            }.font(.callout)
        }
        .formStyle(.grouped)
        .task(id: engine) { scan(); checkForUpdate() }
    }

    /// The Engine Update row, in a few words: what the check said, or how the update went.
    private var updateStatus: String {
        if updating { return "Running kapitsa update…" }
        if let updateResult { return updateResult }
        guard Kapitsa.updatable else { return Kapitsa.binary == nil ? "No engine" : "Bundled: updates with the app" }
        switch check {
        case .none: return "Checking…"
        case .upToDate(let words), .available(let words), .unknown(let words): return words
        }
    }
    private var updateStatusColor: Color {
        if updating || updateResult != nil { return .secondary }
        switch check {
        case .available: return .primary
        case .unknown: return .orange
        default: return .secondary
        }
    }

    /// Reads the version and the installed copies off the main thread: both may run a shell or the engine.
    private func scan() {
        Task.detached {
            let found = Kapitsa.installed, current = Kapitsa.version()
            await MainActor.run { installed = found; version = current }
        }
    }

    /// Asks the engine whether a newer release is out; nothing for the bundled copy, which cannot change.
    private func checkForUpdate() {
        updateResult = nil
        guard Kapitsa.updatable else { check = nil; return }
        check = nil
        Task.detached {
            let answer = Kapitsa.checkForUpdate()
            await MainActor.run { check = answer }
        }
    }

    /// Runs `kapitsa update` and reads the version again: a running model keeps the engine it started with.
    private func update() {
        updating = true
        updateResult = nil
        Task.detached {
            let outcome: String
            do {
                let result = try Kapitsa.update()
                let last = result.output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                outcome = result.code == 0 ? (last.isEmpty ? "Updated" : last) : "Update failed (exit \(result.code)): \(last)"
            } catch {
                outcome = "Update failed: \(error.localizedDescription)"
            }
            let current = Kapitsa.version()
            await MainActor.run { updating = false; updateResult = outcome; version = current }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a kapitsa executable"
        panel.directoryURL = URL(fileURLWithPath: installed.first?.deletingLastPathComponent().path ?? "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { engine = url.path }
    }
}
