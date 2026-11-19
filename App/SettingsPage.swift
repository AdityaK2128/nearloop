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
    /// The picker's own selection: the engine, or the "Other…" entry while the file dialog is up.
    @State private var selection = ""
    @State private var version = "…"
    @State private var installed: [URL] = []
    /// The last answer of `kapitsa update --check`, for an installed engine.
    @State private var check: Kapitsa.UpdateCheck?
    /// For an engine built from source: how far its checkout is behind main.
    @State private var sourceStatus: EngineSource.Status?
    @State private var updating = false
    /// The step of a source build under way, in a few words.
    @State private var buildStep = ""
    /// How the last update ended, in the engine's own words, until the next check.
    @State private var updateResult: String?

    private static let other = "__other__"
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private func short(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }

    /// What kind of engine is chosen; the actions below the rows follow from it.
    private enum Kind: Equatable {
        case bundled
        case installed
        /// Built from source in this checkout; `built` is false for Nearloop's own clone before its first build.
        case source(EngineSource.Checkout, built: Bool)
    }
    private var kind: Kind {
        if engine.isEmpty { return .bundled }
        let managed = EngineSource.managed
        if engine == managed.binary.path { return .source(managed, built: FileManager.default.isExecutableFile(atPath: engine)) }
        if let checkout = EngineSource.checkout(of: URL(fileURLWithPath: engine)) { return .source(checkout, built: true) }
        return .installed
    }
    /// The chosen engine is gone (uninstalled, or on a drive that is not connected): the bundled copy stands in.
    private var chosenMissing: Bool {
        if case .source(_, built: false) = kind { return false }
        return !engine.isEmpty && !FileManager.default.isExecutableFile(atPath: engine)
    }

    var body: some View {
        Form {
            LabeledContent("Nearloop", value: "\(Updater.currentVersion) (\(Updater.currentBuild))")
            Section {
                Picker("Engine", selection: $selection) {
                    Text(Kapitsa.bundled == nil ? "Bundled (not in this build)" : "Bundled").tag("")
                    ForEach(installed, id: \.path) { Text(short($0.path)).tag($0.path) }
                    if !engine.isEmpty, engine != EngineSource.managed.binary.path, !installed.contains(where: { $0.path == engine }) {
                        Text(short(engine)).tag(engine)
                    }
                    Text("Latest commit (built from source)").tag(EngineSource.managed.binary.path)
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                LabeledContent("Engine Version", value: version)
                LabeledContent("Engine Path", value: Kapitsa.binary?.path ?? "Not Found")
                LabeledContent("Engine Update") {
                    HStack(spacing: 8) {
                        if updating { ProgressView().controlSize(.small) }
                        Text(updateStatus).foregroundStyle(updateStatusColor)
                    }
                }
                switch kind {
                case .bundled:
                    EmptyView()
                case .installed:
                    HStack {
                        Spacer()
                        Button("Check for Updates") { checkForUpdate() }.disabled(updating)
                        Button(updating ? "Updating…" : "Update") { update() }.disabled(updating || !updateAvailable)
                    }
                case .source(let checkout, let built):
                    HStack {
                        Spacer()
                        if built { Button("Check for Updates") { checkForUpdate() }.disabled(updating) }
                        Button(updating ? "Building…" : "Build") { build(checkout) }.disabled(updating || (built && !updateAvailable))
                    }
                }
            } footer: {
                Text(footer).foregroundStyle(chosenMissing ? .orange : .secondary)
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
        .onAppear { selection = engine }
        .onChange(of: selection) { _, chosen in
            if chosen == Self.other { choose() } else if chosen != engine { engine = chosen }
        }
        .task(id: engine) { selection = engine; scan(); checkForUpdate() }
    }

    private var footer: String {
        if chosenMissing { return "\(short(engine)) is not an executable file; the bundled engine stands in until it is back." }
        switch kind {
        case .bundled:
            return "The engine that ships inside Nearloop. It changes only with the app. A Kapitsa installed with Homebrew, one you built yourself, or the latest commit of main built here takes its place for the server, downloads, imports, benchmarks and the coding agents, from the next model load on; a running model keeps the engine it started with."
        case .installed:
            return "An installed Kapitsa, used in the bundled copy's place. Update runs its own `kapitsa update`: Homebrew's `brew upgrade` for a Homebrew install, Kapitsa's signed download from GitHub otherwise. A running model keeps the engine it started with until it is reloaded."
        case .source(let checkout, let built):
            return built
                ? "Built from source in \(short(checkout.source.path)). Check for Updates fetches main and counts the commits this checkout is behind; Build pulls main and rebuilds the `kapitsa` and `systemone` targets in Release, with git and CMake from the login shell's PATH. A running model keeps the engine it started with until it is reloaded."
                : "Not built yet. Build clones nace-ai/kapitsa into \(short(checkout.source.path)), builds the latest commit of main in Release (git and CMake from the login shell's PATH; minutes the first time) and runs it as the engine. Until then the bundled engine stands in."
        }
    }

    /// The Engine Update row, in a few words: what the check said, or how the update went.
    private var updateStatus: String {
        if updating { return buildStep.isEmpty ? "Running kapitsa update…" : buildStep }
        if let updateResult { return updateResult }
        switch kind {
        case .bundled: return Kapitsa.binary == nil ? "No engine" : "Updates with the app"
        case .source(_, built: false): return "Not built yet"
        case .source:
            switch sourceStatus {
            case .none: return "Checking main…"
            case .atLatest(let words), .behind(_, let words), .unknown(let words): return words
            }
        case .installed:
            switch check {
            case .none: return "Checking…"
            case .upToDate(let words), .available(let words), .unknown(let words): return words
            }
        }
    }
    private var updateStatusColor: Color {
        if updating || updateResult != nil { return .secondary }
        switch kind {
        case .source(_, built: true):
            switch sourceStatus {
            case .behind: return .primary
            case .unknown: return .orange
            default: return .secondary
            }
        case .installed:
            switch check {
            case .available: return .primary
            case .unknown: return .orange
            default: return .secondary
            }
        default: return .secondary
        }
    }
    /// Something to install: a newer release for an installed engine, newer commits for a source build.
    private var updateAvailable: Bool {
        switch kind {
        case .bundled: return false
        case .source(_, built: false): return true
        case .source: if case .behind = sourceStatus { return true } else { return false }
        case .installed: if case .available = check { return true } else { return false }
        }
    }

    /// Reads the version and the installed copies off the main thread: both may run a shell or the engine.
    private func scan() {
        Task.detached {
            Kapitsa.refreshShellPath()
            let found = Kapitsa.installed, current = Kapitsa.version()
            await MainActor.run { installed = found; version = current }
        }
    }

    /// Asks whether there is something newer: for a source build, commits on main past this checkout; for an
    /// installed engine, a newer release; nothing for the bundled copy, which cannot change.
    private func checkForUpdate() {
        updateResult = nil
        check = nil
        sourceStatus = nil
        switch kind {
        case .bundled, .source(_, built: false):
            return
        case .source(let checkout, built: true):
            Task.detached {
                let status = EngineSource.check(checkout)
                await MainActor.run { sourceStatus = status }
            }
        case .installed:
            Task.detached {
                let answer = Kapitsa.checkForUpdate()
                await MainActor.run { check = answer }
            }
        }
    }

    /// Runs `kapitsa update` for an installed engine and reads the version again.
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

    /// Pulls main (cloning first when the checkout is not there) and builds; the result is checked again at once.
    private func build(_ checkout: EngineSource.Checkout) {
        updating = true
        updateResult = nil
        buildStep = "Starting…"
        Task.detached {
            let failure: String?
            do {
                try EngineSource.update(checkout) { step in Task { @MainActor in buildStep = step } }
                failure = nil
            } catch {
                failure = "Build failed: \(error.localizedDescription)"
            }
            let current = Kapitsa.version()
            await MainActor.run {
                updating = false; buildStep = ""; version = current
                if let failure { updateResult = failure } else { checkForUpdate() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a kapitsa executable"
        panel.directoryURL = URL(fileURLWithPath: installed.first?.deletingLastPathComponent().path ?? "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { engine = url.path } else { selection = engine }
    }
}
