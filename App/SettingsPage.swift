import AppKit
import ServiceManagement
import SwiftUI

/// Settings, as a page of the main window: categories on the left, the chosen one's form on the right.
struct SettingsPage: View {
    enum Category: String, CaseIterable, Identifiable {
        case general, shortcut, chat, images, server, engine, memory, storage, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .shortcut: return "Quick Chat"
            case .chat: return "Web Search"
            case .images: return "Images"
            case .server: return "Server"
            case .engine: return "Engine"
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
            case .images: return "eye"
            case .server: return "server.rack"
            case .engine: return "cpu"
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
                // Every tab stays in sight: the row wraps onto a second line when the window is too narrow.
                FlowLayout(spacing: 6) {
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
                // The row stops redrawing after the first change of tab (macOS 27), so the highlight stayed
                // on one tab while the pages changed; a row per tab is drawn fresh.
                .id(category)
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
                case .images: ImagesSettings()
                case .server: ServerSettings()
                case .engine: EngineSettings()
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

/// Nearloop's version and credits.
struct AboutSettings: View {
    @State private var engine = "…"

    var body: some View {
        Form {
            LabeledContent("Nearloop", value: "\(Updater.currentVersion) (\(Updater.currentBuild))")
            LabeledContent("Engine") {
                HStack(spacing: 8) {
                    Text(engine).foregroundStyle(.secondary)
                    Button("Change…") { UserDefaults.standard.set(SettingsPage.Category.engine.rawValue, forKey: "settingsCategory") }
                        .controlSize(.small)
                }
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
        .task { engine = await Task.detached { Kapitsa.version() }.value }
    }
}

/// The Kapitsa engine the app runs: the bundled one, an installed one, or the latest commit built from source.
struct EngineSettings: View {
    @AppStorage("enginePath") private var engine = ""
    @AppStorage("fastProfile") private var fastProfile = false
    /// The picker's own selection: the engine, or the "Other…" entry while the file dialog is up.
    @State private var selection = ""
    /// What Nearloop's own source build follows: Kapitsa's main or a beta branch (EngineSource.sources).
    @State private var source = EngineSource.chosen.id
    @State private var version = "…"
    @State private var installed: [URL] = []
    /// What each engine in the picker says it is, by path ("" for the bundled copy).
    @State private var versions: [String: String] = [:]
    /// The last answer of `kapitsa update --check`, for an installed engine.
    @State private var check: Kapitsa.UpdateCheck?
    /// For an engine built from source: how far its checkout is behind main.
    @State private var sourceStatus: EngineSource.Status?
    @State private var updating = false
    /// The step of a source build under way, in a few words.
    @State private var buildStep = ""
    /// How the last update ended, in the engine's own words, until the next check.
    @State private var updateResult: String?
    /// What an update would bring, when there is one: the newest commits' subjects for a source build, the latest
    /// release's notes for an installed engine.
    @State private var whatsNew: [String] = []

    private static let other = "__other__"
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private func short(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }

    /// An engine by name: its version ("Kapitsa 0.2.39 (d387c2d)") and where it comes from.
    private func name(_ path: String, from origin: String) -> String {
        guard let version = versions[path] else { return "Kapitsa · \(origin)" }
        return version.prefix(1).uppercased() + version.dropFirst() + " · " + origin
    }
    /// Where an installed engine comes from, in a word or its folder.
    private func origin(_ path: String) -> String {
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Cellar/") || path == "/usr/local/bin/kapitsa" { return "Homebrew" }
        if path == EngineSource.managed.binary.path { return managedOrigin }
        if EngineSource.checkout(of: URL(fileURLWithPath: path)) != nil { return "Built from Source, " + short(path) }
        return short(path)
    }
    /// Nearloop's own source build, named with the beta it follows, if any.
    private var managedOrigin: String {
        let chosen = EngineSource.source(source)
        return "Built from Source" + (chosen.isMain ? "" : " · \(chosen.label)")
    }
    /// The source picker belongs to Nearloop's own clone only; a checkout of the user's own follows main.
    private var managedSource: Bool {
        if case .source(let checkout, _) = kind { return checkout == EngineSource.managed }
        return false
    }

    /// What kind of engine is chosen; the actions below the rows follow from it.
    private enum Kind: Equatable {
        case bundled
        case installed
        /// Built from source in this checkout; `built` is false for Nearloop's own clone before its first build.
        case source(EngineSource.Checkout, built: Bool)
    }
    private var kind: Kind {
        // A kapitsa inside an app (this one's or another copy's) changes only with that app, like the bundled one.
        if engine.isEmpty || Kapitsa.insideApp(URL(fileURLWithPath: engine)) { return .bundled }
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
            Section {
                Picker("Engine", selection: $selection) {
                    Text(Kapitsa.bundled == nil ? "Bundled (not in this build)" : name("", from: "Bundled")).tag("")
                    ForEach(installed, id: \.path) { Text(name($0.path, from: origin($0.path))).tag($0.path) }
                    if !engine.isEmpty, engine != EngineSource.managed.binary.path, !installed.contains(where: { $0.path == engine }) {
                        Text(name(engine, from: origin(engine))).tag(engine)
                    }
                    let managed = EngineSource.managed.binary.path
                    Text(FileManager.default.isExecutableFile(atPath: managed) ? name(managed, from: managedOrigin) : "\(EngineSource.source(source).label) · Build from Source").tag(managed)
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                if managedSource {
                    Picker("Source", selection: $source) {
                        ForEach(EngineSource.sources) { Text($0.label).tag($0.id) }
                    }
                    let chosen = EngineSource.source(source)
                    if !chosen.isMain {
                        HStack(spacing: 8) {
                            Text(chosen.about).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let pull = chosen.pullRequest { Link("Pull request", destination: pull).font(.caption) }
                        }
                    }
                }
                // A source engine not built yet shows what it will be, not the bundled copy standing in for it.
                if case .source(let checkout, built: false) = kind {
                    LabeledContent("Engine Path", value: checkout.binary.path)
                } else {
                    // The picker names the chosen engine; the version shows only when another one stands in for it.
                    if chosenMissing { LabeledContent("Engine in Use", value: version) }
                    LabeledContent("Engine Path", value: Kapitsa.binary?.path ?? "Not Found")
                }
                LabeledContent("Engine Update") {
                    HStack(spacing: 8) {
                        if updating { ProgressView().controlSize(.small) }
                        Text(updateStatus).foregroundStyle(updateStatusColor)
                    }
                }
                if !whatsNew.isEmpty, !updating, updateResult == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What's New").foregroundStyle(.secondary)
                        ForEach(Array(whatsNew.enumerated()), id: \.offset) { _, line in
                            Text("•  " + line).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
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
                        Button("Check for Updates") { checkForUpdate() }.disabled(updating)
                        Button(updating ? "Building…" : "Build") { build(checkout) }.disabled(updating || (built && !updateAvailable))
                    }
                }
            } footer: {
                Text(footer).foregroundStyle(chosenMissing ? .orange : .secondary)
            }
            Section {
                Picker("Mode", selection: $fastProfile) {
                    Text("Precise").tag(false)
                    Text("Fast").tag(true)
                }
            } footer: {
                Text(fastProfile
                     ? "Kapitsa's fast profile: on top of the exact path, the speedups Kapitsa found to change the output no more than the fastest other engine does for that model on that kind of Mac, such as 8-bit weights for Inkling 2's 16-bit layers. Each speedup applies only to the Macs and models it was measured on; elsewhere Fast runs as Precise. Takes effect when a model is next loaded."
                     : "Kapitsa's default: every output matches the model's reference within its measured noise. Fast adds the speedups Kapitsa found to change the output no more than the fastest other engine does, for the Macs and models each was measured on. Takes effect when a model is next loaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { selection = engine }
        .onChange(of: selection) { _, chosen in
            if chosen == Self.other { choose() } else if chosen != engine { engine = chosen }
        }
        // Another source: the clone moves to its branch when that is there already (Build fetches it otherwise),
        // and the check runs again against it. The engine in use stays until the next Build.
        .onChange(of: source) { _, id in
            guard EngineSource.source(id).id != Prefs.engineSource else { return }
            Prefs.engineSource = id
            Task.detached {
                EngineSource.switchTo(EngineSource.source(id))
                await MainActor.run { scan(); checkForUpdate() }
            }
        }
        // The Library lists what the engine runs and Discover what its catalog has: both are read again.
        .onChange(of: engine) { _, _ in Task { await AppStore.shared.scan(); await AppStore.shared.loadCatalog() } }
        .task(id: engine) {
            selection = engine; scan(); checkForUpdate()
            // A build started before this pane was last closed is still running: show it, and check once it ends.
            guard EngineSource.anyBuilding, !updating else { return }
            updating = true
            buildStep = "Building…"
            while EngineSource.anyBuilding, !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
            if Task.isCancelled { return }
            updating = false; buildStep = ""
            scan()
            checkForUpdate()
            await AppStore.shared.scan()
            await AppStore.shared.loadCatalog()
        }
    }

    private var footer: String {
        if chosenMissing { return "\(short(engine)) is not an executable file; the bundled engine stands in until it is back." }
        switch kind {
        case .bundled where !engine.isEmpty:
            return "The kapitsa inside \(short(engine)). It changes only with that app, so there is nothing to update here."
        case .bundled:
            return "The engine that ships inside Nearloop. It changes only with the app. A Kapitsa installed with Homebrew, one you built yourself, or Kapitsa built here from source takes its place for the server, downloads, imports, benchmarks and the coding agents, from the next model load on; a running model keeps the engine it started with."
        case .installed:
            return "An installed Kapitsa, used in the bundled copy's place. Check for Updates asks for the latest release and shows its notes; Update runs brew upgrade for a Homebrew install and kapitsa update (its signed download from GitHub) otherwise. A running model keeps the engine it started with until it is reloaded."
        case .source(let checkout, let built):
            let chosen = EngineSource.source(for: checkout), branch = chosen.branch
            var words = built
                ? "Built from source in \(short(checkout.source.path)). Check for Updates fetches \(branch), counts the commits this checkout is behind and lists the newest of them; Build pulls \(branch) and rebuilds the kapitsa and systemone targets in Release, with git and CMake from the login shell's PATH. A running model keeps the engine it started with until it is reloaded."
                : "Build clones \(chosen.github) into \(short(checkout.source.path)), compiles the latest commit of \(branch) in Release (git and CMake from the login shell's PATH; minutes the first time) and runs it as the engine. Until then the bundled engine stands in."
            if !chosen.isMain {
                words += " \(chosen.label.replacingOccurrences(of: " (beta)", with: "")) is a beta: the build comes from the \(branch) branch of the fork \(chosen.github), not from Kapitsa itself, and this choice will be retired when Kapitsa ships it. Kapitsa main switches back; the next Build rebuilds main."
            }
            return words
        }
    }

    /// The Engine Update row, in a few words: what the check said, or how the update went.
    private var updateStatus: String {
        if updating { return buildStep.isEmpty ? "Updating the engine…" : buildStep }
        if let updateResult { return updateResult }
        switch kind {
        case .bundled: return Kapitsa.binary == nil ? "No engine" : "Updates with the app"
        case .source:
            switch sourceStatus {
            case .none: return "Checking \(EngineSource.source(source).branch)…"
            case .atLatest(let words), .behind(_, let words, _), .remote(let words), .unknown(let words): return words
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
        case .source:
            switch sourceStatus {
            case .behind, .remote: return .primary
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
            // Every engine on offer is named by what it says it is, so two copies can be told apart.
            var named: [String: String] = [:]
            if let bundled = Kapitsa.bundled { named[""] = Kapitsa.version(of: bundled) }
            let chosen = UserDefaults.standard.string(forKey: "enginePath") ?? ""
            for path in found.map(\.path) + [chosen, EngineSource.managed.binary.path] where !path.isEmpty {
                named[path] = Kapitsa.version(of: URL(fileURLWithPath: path))
            }
            let names = named
            await MainActor.run { installed = found; version = current; versions = names }
        }
    }

    /// Asks whether there is something newer: for a source build, commits on main past this checkout; for an
    /// installed engine, a newer release; nothing for the bundled copy, which cannot change.
    private func checkForUpdate() {
        updateResult = nil
        check = nil
        sourceStatus = nil
        whatsNew = []
        switch kind {
        case .bundled:
            return
        case .source(_, built: false):
            Task.detached {
                let status = EngineSource.remote()
                await MainActor.run { sourceStatus = status }
            }
        case .source(let checkout, built: true):
            Task.detached {
                let status = EngineSource.check(checkout)
                let news: [String] = if case .behind(_, _, let subjects) = status { subjects } else { [] }
                await MainActor.run { sourceStatus = status; whatsNew = news }
            }
        case .installed:
            Task.detached {
                let answer = Kapitsa.checkForUpdate()
                // The release's notes say what the update brings; asked only when there is one.
                let news: [String] = if case .available = answer { EngineSource.releaseNotes() } else { [] }
                await MainActor.run { check = answer; whatsNew = news }
            }
        }
    }

    /// Updates an installed engine (Kapitsa.update) and reads the version again: the outcome names the version it
    /// went to, or says it was the latest already; a failure keeps the last line the updater printed.
    private func update() {
        updating = true
        updateResult = nil
        Task.detached {
            // The version as it is now, not as the pane last read it: the engine may have changed underneath.
            let before = Kapitsa.version()
            var outcome: String
            do {
                let result = try Kapitsa.update()
                let last = result.output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                outcome = result.code == 0 ? "" : "Update failed (exit \(result.code)): \(last)"
            } catch {
                outcome = "Update failed: \(error.localizedDescription)"
            }
            let current = Kapitsa.version()
            let result = outcome.isEmpty ? (current == before ? "Already the latest: \(current)" : "Updated to \(current)") : outcome
            await MainActor.run { updating = false; updateResult = result; version = current; scan() }
            await AppStore.shared.scan()
            await AppStore.shared.loadCatalog()
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
                updating = false; buildStep = ""; version = current; scan()
                if let failure { updateResult = failure } else { checkForUpdate() }
            }
            await AppStore.shared.scan()
            await AppStore.shared.loadCatalog()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a kapitsa executable"
        panel.directoryURL = URL(fileURLWithPath: installed.first?.deletingLastPathComponent().path ?? "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { engine = enginePath(for: url) }
        selection = engine
    }

    /// The path to keep for a file picked with Other…. The open panel resolves links, so Homebrew's
    /// /opt/homebrew/bin/kapitsa arrives as its versioned Cellar folder, which the next upgrade deletes: a file
    /// that is one of the installed engines keeps that engine's own path. The bundled copy is the default choice, and
    /// this app's `kapitsa` command can't be the engine, since it runs the engine chosen here.
    private func enginePath(for url: URL) -> String {
        let real = url.resolvingSymlinksInPath().path
        if Kapitsa.isCommand(url) {
            let alert = NSAlert()
            alert.messageText = "That is Nearloop’s own kapitsa command"
            alert.informativeText = "It runs the engine chosen here, so it can’t be the engine itself. Choose the kapitsa it should run instead."
            alert.runModal()
            return engine
        }
        if let bundled = Kapitsa.bundled, bundled.resolvingSymlinksInPath().path == real { return "" }
        if let match = installed.first(where: { $0.resolvingSymlinksInPath().path == real }) { return match.path }
        return url.path
    }
}


/// Settings › Images: the vision sidecar (Gemma 3 4B on llama.cpp) that describes images for models that can't
/// read them, in Chat and for the coding agents through the `image_tool` command.
struct ImagesSettings: View {
    @ObservedObject private var download = ImageSidecarDownload.shared
    @State private var on = Prefs.imageSidecar
    @State private var downloaded = ImageSidecar.downloaded
    @State private var onDisk: Int64 = 0
    @State private var toolState = ImageSidecar.toolState
    @State private var instructed: [String: Bool] = [:]
    @State private var serverUp = false

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private func short(_ url: URL) -> String { url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path }
    private func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    var body: some View {
        Form {
            Section {
                Toggle("Image Sidecar for Models That Can’t Read Images", isOn: Binding(get: { on }, set: toggle))
                    .disabled(!downloaded && !on)
            } footer: {
                Text(downloaded || on
                     ? "When the loaded model drops an attached image (Kapitsa says so in its log), Chat has \(ImageSidecar.modelName) describe it, with your question and what the conversation is about, and sends the model the description in the image’s place; a note under the reply shows what the sidecar saw. The coding agents get the same through the image_tool command. Everything runs on this Mac."
                     : "Download the vision helper below to turn this on. Models that read images themselves, such as Inkling 2 on an engine with its vision tower, are left alone.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Vision Model") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(ImageSidecar.modelName) · QAT Q4_0 · ggml-org")
                        Text("\(gigabytes(ImageSidecar.modelBytes + ImageSidecar.projectorBytes)) with its image projector").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Runner") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("llama.cpp \(ImageSidecar.runnerBuild) · llama-server")
                        Text("\(ByteCountFormatter.string(fromByteCount: ImageSidecar.runnerBytes, countStyle: .file)) · macOS arm64 release").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("On Disk") {
                    Text(downloaded ? "Downloaded · \(gigabytes(onDisk))" : onDisk > 0 ? "Partial · \(gigabytes(onDisk)) of \(gigabytes(ImageSidecar.totalBytes))" : "Not downloaded")
                        .foregroundStyle(.secondary)
                }
                if downloaded {
                    LabeledContent("Vision Server") {
                        HStack(spacing: 8) {
                            Text(serverUp ? "Running on 127.0.0.1:8765 · stops after 5 idle minutes" : "Not running · starts with the first image").foregroundStyle(.secondary)
                            if serverUp { Button("Stop") { ImageSidecar.stopServer(); Task { await checkServer() } }.controlSize(.small) }
                        }
                    }
                }
                if let job = download.job, job.showsProgress { DownloadProgressLine(job: job) }
                HStack {
                    Spacer()
                    if download.busy {
                        Button("Cancel") { download.cancel() }
                    } else if downloaded {
                        Button("Remove") { download.remove(); refresh() }
                    } else {
                        let resuming = download.job.map { job -> Bool in if case .failed = job.state { return true }; return job.state == .paused } ?? false
                        Button(resuming ? "Resume Download" : "Download \(gigabytes(ImageSidecar.totalBytes))") { download.start() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } footer: {
                Text("Kept in \(short(ImageSidecar.folder)). The model comes from huggingface.co/\(ImageSidecar.modelRepo), the runner from llama.cpp’s GitHub releases; both resume where they stopped.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Command") {
                    HStack(spacing: 8) {
                        switch toolState {
                        case "installed": Label(short(ImageSidecar.toolURL), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case "outdated": Label("\(short(ImageSidecar.toolURL)) · older copy", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                        case "foreign": Label("\(short(ImageSidecar.toolURL)) is another program", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        default: Text("Not installed").foregroundStyle(.secondary)
                        }
                        Button(toolState == "installed" ? "Reinstall" : toolState == "outdated" ? "Update" : "Install") {
                            do { try ImageSidecar.installTool() } catch { AppStore.shared.errorMessage = error.localizedDescription }
                            refresh()
                        }.controlSize(.small).disabled(toolState == "foreign")
                    }
                }
                ForEach(ImageSidecar.instructionFiles, id: \.agent) { file in
                    LabeledContent(file.agent) {
                        HStack(spacing: 6) {
                            Text(short(file.url)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: instructed[file.agent] == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(instructed[file.agent] == true ? Color.green : Color.secondary)
                                .help(instructed[file.agent] == true ? "Has the image_tool line" : "No image_tool line")
                        }
                    }
                }
            } footer: {
                Text("image_tool <file> \"<question>\" \"<context>\" prints what the vision model sees. While the sidecar is on, each agent’s global instruction file carries one line (marked \(ImageSidecar.marker)) telling it to run the command for an image it can’t see; off takes exactly that line out again. The agents start the vision server themselves, so Nearloop needn’t be open.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onChange(of: download.revision) { _, _ in refresh() }
        .task {
            while !Task.isCancelled {
                await checkServer()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func toggle(_ value: Bool) {
        do {
            try ImageSidecar.setEnabled(value)
        } catch {
            AppStore.shared.errorMessage = error.localizedDescription
        }
        on = Prefs.imageSidecar
        refresh()
    }

    private func refresh() {
        on = Prefs.imageSidecar
        downloaded = ImageSidecar.downloaded
        toolState = ImageSidecar.toolState
        instructed = Dictionary(uniqueKeysWithValues: ImageSidecar.instructionFiles.map { ($0.agent, ImageSidecar.hasInstruction($0.url)) })
        Task.detached {
            let bytes = ImageSidecar.bytesOnDisk
            await MainActor.run { onDisk = bytes }
        }
    }

    private func checkServer() async {
        let up = await ImageSidecar.serverRunning()
        serverUp = up
    }
}
