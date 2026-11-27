import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    // Sidebar order: what's happening now and what happened, then the models, then the agents that use them.
    case home, chat, usage, models, discover, benchmarks, agents, experimental, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .chat: return "Chat"
        case .usage: return "Usage"
        case .models: return "Library"
        case .discover: return "Discover"
        case .benchmarks: return "Benchmarks"
        case .agents: return "Coding Agents"
        case .experimental: return "iPhone Offload"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .chat: return "bubble.left.and.bubble.right"
        case .usage: return "chart.bar.xaxis"
        case .models: return "square.stack.3d.up"
        case .discover: return "sparkle.magnifyingglass"
        case .benchmarks: return "gauge.with.dots.needle.67percent"
        case .agents: return "terminal"
        case .experimental: return "iphone.gen3.radiowaves.left.and.right"
        case .settings: return "gearshape"
        }
    }
    /// The sidebar group; nil for the overview pages at the top.
    var section: String? {
        switch self {
        case .home, .chat, .usage: return nil
        case .models, .discover, .benchmarks: return "Models"
        case .agents: return "Agents"
        case .experimental: return "Experimental"
        case .settings: return "App"
        }
    }
    static let sections = ["Models", "Agents", "Experimental", "App"]

    /// Experimental pages appear only after "Show Experimental Features" is turned on in Settings › General.
    static let experimentalKey = "showExperimental"
    static func visible(experimental: Bool) -> [Page] {
        allCases.filter { experimental || $0.section != "Experimental" }
    }
}

/// App-wide state shared by the main window and the menu bar.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var page = Page.home
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var libraries = Prefs.libraries
    @Published private(set) var agents: [String: String] = [:]
    @Published private(set) var agentVersions: [String: String] = [:]
    /// Kapitsa's agents and the user's own (`Agents.catalog`), refreshed by each scan and each edit.
    @Published private(set) var agentCatalog: [AgentInfo] = Agents.catalog
    @Published private(set) var catalog: [CatalogFamily] = []
    @Published private(set) var catalogError: String?
    /// Per family: its Hugging Face repository and the files that speed it up, from Kapitsa's catalog.
    @Published private(set) var catalogDetails: [String: Catalog.Details] = [:]
    /// The model types (config.json's model_type) of the repositories the engine's catalog downloads from: what
    /// "Kapitsa-compatible" means in Discover, read from the catalog rather than kept as a list in the app, so a
    /// family Kapitsa adds (Inkling-2, say) counts as soon as the engine in use lists it. Remembered per repository.
    @Published private(set) var catalogTypes: Set<String> = []
    /// Each Hugging Face repository's files, read once (HuggingFace.files): the exact download size the rows show
    /// and the size sort orders by, so the order follows the files, not the listing's estimate.
    @Published var hubFiles: [String: HuggingFace.Files] = [:]
    private static let typesKey = "catalogModelTypes"
    @Published private(set) var benchmarks: [BenchResult] = []
    @Published private(set) var scanning = false
    @Published var selectedModelID: String? = UserDefaults.standard.string(forKey: "selectedModel")
    @Published var context = Prefs.lastContext
    @Published var notice = ""
    @Published var errorMessage: String?
    @Published var showLog = false
    @Published var importTarget: LocalModel?
    @Published private(set) var launching: String?
    /// Models being moved to another folder, with how far each move has got.
    @Published private(set) var relocations: [String: Double] = [:]
    /// GGUF files being converted.
    @Published var converting: Set<String> = []
    /// A launch held back because the agent's prompt doesn't fit the loaded model's context.
    @Published var launchWarning: LaunchWarning?

    struct LaunchWarning: Identifiable {
        let id = UUID()
        let agent: String
        let project: URL
        let message: String
        /// A context to reload the model at before launching, when the loaded one is smaller than the agent needs.
        var reload: String?
        var reloadLabel: String?
    }

    struct ContextFit {
        enum Level { case fits, tight, overflow }
        let level: Level
        let message: String
    }

    /// How an agent's prompt sits in the running model's context; nil when no model is loaded by this app.
    func contextFit(_ agent: String) -> ContextFit? {
        guard server.owned, server.phase == .ready, let available = server.stats.effectiveContext else { return nil }
        let (need, measured) = Agents.promptTokens(agent)
        let name = Agents.displayName(agent), about = measured ? "" : "about "
        // Room for the user's message and the first reply on top of the agent's own prompt.
        if available < need + 2_048 {
            return ContextFit(level: .overflow, message: "\(name)’s first request is \(about)\(shortTokens(need)) tokens, but the loaded model holds \(shortTokens(available)). Load a larger context, or close apps so more memory is left for context.")
        }
        if let compacts = Agents.info(agent)?.compactsAt, available < compacts {
            return ContextFit(level: .tight, message: "\(name) compacts conversations only at \(shortTokens(compacts)) tokens; this model holds \(shortTokens(available)), so a long session can run out of room first.")
        }
        if available < need + 16_384 {
            return ContextFit(level: .tight, message: "Uses \(about)\(shortTokens(need)) of \(shortTokens(available)) tokens, leaving little room for files and conversation.")
        }
        return ContextFit(level: .fits, message: "Uses \(about)\(shortTokens(need)) of \(shortTokens(available)) tokens.")
    }

    let server = ServerController.shared
    private var booted = false

    private init() {
        Downloads.shared.finished = { [weak self] spec in
            Task { await self?.scan(); self?.notice = "\(spec) downloaded." }
        }
        // Models on an external drive appear and disappear with it.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.scan() }
            }
        }
    }

    func bootstrap() async {
        guard !booted else { return }
        booted = true
        Updater.shared.startAutomaticChecks()
        await scan()
        await loadCatalog()
        if Prefs.autoStart, !server.running, let path = Prefs.lastModel, let model = model(at: path) {
            load(model, context: model.accepts(Prefs.lastContext) ? Prefs.lastContext : model.largestPreset)
        }
    }

    // MARK: Library

    var downloadsPath: String { Kapitsa.downloads.path }
    var runnable: [LocalModel] { models.filter(\.loadable) }
    var selected: LocalModel? { models.first { $0.id == selectedModelID } }
    func model(at path: String) -> LocalModel? { models.first { $0.path == path } }
    func libraryTitle(_ path: String) -> String { path == downloadsPath ? "Downloaded" : URL(fileURLWithPath: path).lastPathComponent }
    var allLibraries: [String] { [downloadsPath] + libraries }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let roots = allLibraries, verified = Registry.load()
        models = await Task.detached { ModelScanner.scan(libraries: roots, verified: verified) }.value
        // Re-read the shell's PATH each scan, so Refresh finds an agent installed while the app was open.
        let previous = Agents.supported
        let (supported, found) = await Task.detached { () -> ([(id: String, name: String)], [String: String]) in
            Kapitsa.refreshShellPath()
            let list = Agents.readSupported() ?? previous
            return (list, Agents.installed(supported: list))
        }.value
        Agents.setSupported(supported)
        agents = found
        agentCatalog = Agents.catalog
        let current = models
        benchmarks = await Task.detached { BenchmarkStore.load(models: current) }.value
        if selected == nil { selectedModelID = runnable.first?.id ?? models.first?.id }
        clampContext()
        Task {
            var versions: [String: String] = [:]
            // Only Kapitsa's agents: a custom command is not asked for --version, which it may not understand.
            for (name, path) in found where Agents.custom(name) == nil { versions[name] = await Task.detached { Agents.version(path) }.value }
            agentVersions = versions
        }
    }

    func loadCatalog() async {
        do {
            catalog = try await Task.detached { try Catalog.load() }.value
            catalogError = nil
        } catch { catalogError = error.localizedDescription; return }
        // Another engine may list other families: details of families it doesn't have are dropped.
        let families = Set(catalog.map(\.id))
        catalogDetails = catalogDetails.filter { families.contains($0.key) }
        await loadCatalogDetails()
        await loadCatalogTypes()
    }

    private var loadingDetails = false

    /// Each family's repository and speed-ups, looked up for its default variant. Each lookup asks Hugging Face
    /// for the current revision, so a few run at a time and a failed one is tried once more; whatever is still
    /// missing is tried again the next time Discover opens.
    func loadCatalogDetails() async {
        guard !loadingDetails else { return }
        loadingDetails = true
        defer { loadingDetails = false }
        for _ in 0..<2 {
            let wanted = catalog.compactMap { family in family.defaultVariant.map { (family.id, $0, family.about) } }
                .filter { catalogDetails[$0.0] == nil }
            if wanted.isEmpty { return }
            await withTaskGroup(of: (String, Catalog.Details?).self) { group in
                var queue = wanted[...]
                func next() {
                    guard let (id, variant, about) = queue.popFirst() else { return }
                    group.addTask { (id, Catalog.details(variant, about: about)) }
                }
                for _ in 0..<4 { next() }
                for await (id, details) in group {
                    if let details { catalogDetails[id] = details }
                    next()
                }
            }
            await loadCatalogTypes()
        }
    }

    var recommended: CatalogVariant? { Catalog.recommended(catalog) }

    /// Reads each catalog repository's model_type once (then from UserDefaults) and keeps the set of the ones the
    /// engine's catalog has now. Called after the catalog details, which name the repositories.
    func loadCatalogTypes() async {
        var known = (UserDefaults.standard.dictionary(forKey: Self.typesKey) as? [String: String]) ?? [:]
        let families = Set(catalog.map(\.id))
        let repos = Set(catalogDetails.filter { families.contains($0.key) }.values.compactMap(\.repo))
        await withTaskGroup(of: (String, String?).self) { group in
            for repo in repos where known[repo] == nil {
                group.addTask {
                    guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/config.json"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (repo, nil) }
                    return (repo, config["model_type"] as? String)
                }
            }
            for await (repo, type) in group { if let type { known[repo] = type } }
        }
        UserDefaults.standard.set(known, forKey: Self.typesKey)
        catalogTypes = Set(repos.compactMap { known[$0] }.map(ModelScanner.familyType))
    }

    /// Whether Kapitsa can download a Hugging Face model of this type: a Qwen3.5-family MLX upload from any repository
    /// (Kapitsa's own check takes them all), another family when the engine's catalog has it (a text-only conversion
    /// counts with its family). Until the catalog's types are known (first run, offline), only the Qwen family counts.
    func compatible(_ modelType: String?) -> Bool {
        guard let modelType else { return false }
        return ModelScanner.qwenTypes.contains(modelType) || catalogTypes.contains(ModelScanner.familyType(modelType))
    }

    /// The catalog variant `kapitsa pull <repo>` takes for one of the catalog's repositories: Kapitsa downloads it as
    /// that build, into the variant's folder rather than one named after the repository.
    func catalogVariant(forRepo repo: String) -> CatalogVariant? {
        let wanted = repo.lowercased()
        guard let family = catalogDetails.first(where: { $0.value.repo?.lowercased() == wanted })?.key else { return nil }
        return catalog.first { $0.id == family }?.defaultVariant
    }

    func localModel(for variant: CatalogVariant) -> LocalModel? { model(at: variant.folder.path) }

    /// The Hugging Face page of a library model, when where it came from is known: a catalog download (its family's
    /// repository), or a Hub download, which Kapitsa saves in a folder named owner--name.
    func modelCard(for model: LocalModel) -> URL? {
        let folder = URL(fileURLWithPath: model.path).standardizedFileURL.path
        if let family = catalog.first(where: { $0.variants.contains { $0.folder.standardizedFileURL.path == folder } }),
           let card = catalogDetails[family.id]?.modelCard { return card }
        let parts = URL(fileURLWithPath: folder).lastPathComponent.components(separatedBy: "--")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return URL(string: "https://huggingface.co/\(parts[0])/\(parts[1])")
    }

    func benchmark(for model: LocalModel) -> BenchResult? { BenchmarkStore.best(benchmarks, for: model) }

    func clampContext() {
        guard let model = selected, model.loadable, !model.accepts(context) else { return }
        context = model.largestPreset
    }

    func addLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders containing models. Subfolders are scanned for MLX models and GGUF files."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !libraries.contains(url.path) { libraries.append(url.path) }
        Prefs.libraries = libraries
        page = .models
        Task { await scan() }
    }

    func removeLibrary(_ path: String) {
        libraries.removeAll { $0 == path }
        Prefs.libraries = libraries
        Task { await scan() }
    }

    /// Why a model's files can't be moved or deleted right now: something running reads or writes them.
    func busyReason(_ model: LocalModel) -> String? {
        func uses(_ path: String?) -> Bool {
            guard let path, !path.isEmpty else { return false }
            return path == model.path || path.hasPrefix(model.path + "/")
        }
        if let path = server.record?.modelPath, uses(path) || uses(self.model(at: path)?.drafter) {
            return "Stop the running model first; it uses these files."
        }
        if let running = BenchmarkRunner.shared.running, uses(running.path) || uses(running.drafter) {
            return "Wait for the benchmark to finish; it uses these files."
        }
        if Downloads.shared.jobs.values.contains(where: { $0.busy && uses($0.folder?.standardizedFileURL.path) }) {
            return "Pause or finish the download first."
        }
        if converting.contains(model.path) { return "Wait for the conversion to finish." }
        if relocations[model.path] != nil { return "This model is being moved." }
        return nil
    }

    /// File work that quitting would cut off partway: a move to another folder (across volumes, a copy), or a
    /// GGUF conversion, whose process would carry on unmanaged.
    var unfinishedFileWork: String? {
        if !relocations.isEmpty { return "A model is being moved to another folder" }
        if !converting.isEmpty { return "A GGUF model is being converted" }
        return nil
    }

    /// Models go to the Trash, so a mistake can be undone.
    func trash(_ model: LocalModel) {
        if let reason = busyReason(model) { errorMessage = reason; return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: model.path), resultingItemURL: nil)
            notice = "\(model.name) moved to the Trash."
            Task { await scan() }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Moves a model folder (and anything inside it, such as a bundled drafter) to a folder the user picks,
    /// keeps it in the library, and carries its verification and benchmark records over to the new path.
    func relocate(_ model: LocalModel) {
        if let reason = busyReason(model) { errorMessage = reason; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose where to move \(model.name). It stays in your library."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let source = URL(fileURLWithPath: model.path)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        guard destination.standardizedFileURL.path != source.standardizedFileURL.path else { return }
        guard !destination.path.hasPrefix(source.path + "/") else { errorMessage = "Choose a folder outside the model itself."; return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "\(folder.lastPathComponent) already contains an item named \(source.lastPathComponent)."
            return
        }
        relocations[model.path] = 0
        Task {
            let total = max(1, await Task.detached { SystemMemory.allocatedBytes(source) }.value)
            let progress = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let done = await Task.detached { SystemMemory.allocatedBytes(destination) }.value
                    if relocations[model.path] != nil { relocations[model.path] = min(0.99, Double(done) / Double(total)) }
                }
            }
            defer { progress.cancel() }
            do {
                // Within a volume this is a rename; across volumes, a copy followed by removing the original.
                try await Task.detached { try FileManager.default.moveItem(at: source, to: destination) }.value
                relocations[model.path] = nil
                Registry.move(from: model.path, to: destination.path)
                BenchmarkStore.move(from: model.path, to: destination.path)
                if Prefs.lastModel == model.path { Prefs.lastModel = destination.path }
                if Prefs.agentModel == model.path { Prefs.agentModel = destination.path }
                if !allLibraries.contains(where: { destination.path.hasPrefix($0 + "/") }) {
                    libraries.append(folder.path)
                    Prefs.libraries = libraries
                }
                await scan()
                selectedModelID = ModelScanner.identity(destination.path)
                notice = "\(model.name) moved to \(folder.path)."
            } catch {
                relocations[model.path] = nil
                // A failed copy across volumes can leave a partial folder; the original is still intact.
                if FileManager.default.fileExists(atPath: source.path), FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                errorMessage = "Couldn’t move \(model.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Server

    func load(_ model: LocalModel, context: String? = nil) {
        let context = context ?? self.context
        Task {
            do {
                if try await startServer(model, context: context) { notice = "Loading \(model.name)…" }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Starts a model on the port in Settings › Server, or on a free one the person chooses when another app holds
    /// that (`wanted`: the port to keep, for a reload). False when they cancel.
    @discardableResult
    func startServer(_ model: LocalModel, context: String, wanted: Int? = nil) async throws -> Bool {
        guard server.canLoad else { throw Kapitsa.Failure(errorDescription: "A model is already running. Stop it before loading another.") }
        guard let port = try await server.choosePort(for: model.name, wanted: wanted) else { return false }
        try server.start(model, context: context, port: port)
        return true
    }

    func loadLast() {
        guard let path = Prefs.lastModel, let model = model(at: path) else { page = .models; return }
        load(model, context: model.accepts(Prefs.lastContext) ? Prefs.lastContext : nil)
    }

    func verify(_ model: LocalModel) async {
        do {
            let took = try await server.verify(model)
            await scan()
            notice = "\(model.name) verified (\(took))."
        } catch { errorMessage = error.localizedDescription }
    }

    func runBenchmark(_ model: LocalModel) {
        do {
            try BenchmarkRunner.shared.run(model) { [weak self] in Task { await self?.scan() } }
            page = .benchmarks
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Agents

    /// The model agents start with when none is running: the chosen one, else the last loaded, else the
    /// largest model that fits and passed the tool-call benchmark (capability matters more than speed for
    /// coding), else the largest that fits.
    var agentModel: LocalModel? {
        if let path = Prefs.agentModel, let model = model(at: path), model.loadable { return model }
        if let path = Prefs.lastModel, let model = model(at: path), model.loadable { return model }
        let fitting = runnable.filter { SystemMemory.estimatedNeedGB($0) < SystemMemory.totalGB * 0.7 }
        let capable = fitting.filter { benchmark(for: $0)?.toolsPass == true }
        return (capable.isEmpty ? fitting : capable).max { $0.size < $1.size }
    }

    /// The model Quick Chat loads when none is running: the one chosen in Settings › Quick Chat, else the default.
    var quickChatModel: LocalModel? {
        if let path = Prefs.defaults.string(forKey: "quickChatModel"), let model = model(at: path), model.loadable { return model }
        return agentModel
    }

    func chooseProject() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Select the project folder for the agent."
        return panel.runModal() == .OK ? panel.url : nil
    }

    func launch(_ agent: String, project: URL? = nil, force: Bool = false) {
        guard let project = project ?? chooseProject() else { return }
        guard agents[agent] != nil else {
            errorMessage = "\(Agents.displayName(agent)) is not installed. See Coding Agents to install it."
            page = .agents
            return
        }
        Task {
            do {
                if !(server.phase == .ready || server.phase == .external) && agentModel == nil {
                    errorMessage = "No model available. Download one from Discover or add a model folder."
                    page = .discover
                    return
                }
                try await ensureServer(for: agent)
                if !force, let warning = contextWarning(agent, project: project) {
                    launchWarning = warning
                    return
                }
                server.measurePrompt(of: agent)
                var model = server.record?.apiId ?? ""
                if model.isEmpty, Agents.custom(agent) != nil {
                    model = await Agents.servedModel(port: server.port, apiKey: server.apiKey) ?? ""
                }
                try Agents.launch(agent, project: project, server: .init(port: server.port, apiKey: server.apiKey, model: model,
                                                                          context: server.stats.effectiveContext))
                notice = "\(Agents.displayName(agent)) launched in \(project.lastPathComponent)."
            } catch is CancellationError {
                // (the port choice was cancelled: nothing started)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Loads the agent model when nothing is serving, and waits until it answers.
    func ensureServer(for agent: String) async throws {
        try await ensureServer(purpose: Agents.displayName(agent)) { [weak self] model in self?.agentContext(agent, model) ?? model.largestPreset }
    }

    /// Loads a model for whatever needs one, a chat or an agent, unless one is serving already (that one is
    /// used as it is), and waits until it answers. Without a model given, the default model (`agentModel`).
    func ensureServer(purpose: String, context: (LocalModel) -> String, model chosen: LocalModel? = nil) async throws {
        if server.phase == .ready || server.phase == .external { return }
        guard let model = chosen ?? agentModel else {
            throw Kapitsa.Failure(errorDescription: "No model available. Download one from Discover or add a model folder.")
        }
        // Registered before the start, so a start that throws still clears the launch state.
        defer { launching = nil }
        if !server.running {
            launching = "Starting \(model.name) for \(purpose)…"
            guard try await startServer(model, context: context(model)) else { throw CancellationError() }
        }
        while server.phase == .starting {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard server.phase == .ready else {
            throw Kapitsa.Failure(errorDescription: "The model failed to start, so \(purpose) couldn’t use it. See Logs for details.")
        }
    }

    /// Before an agent starts on a model this app loaded: a warning when the loaded context is smaller than the
    /// agent should have (a heavy agent on a small context fills it within a few steps and its replies get
    /// cut off), offering to reload at the right size; or when its first prompt cannot fit at all.
    private func contextWarning(_ agent: String, project: URL) -> LaunchWarning? {
        let fit = contextFit(agent)
        guard server.owned, server.phase == .ready, let record = server.record, let model = model(at: record.modelPath) else {
            return fit?.level == .overflow ? LaunchWarning(agent: agent, project: project, message: fit!.message) : nil
        }
        let wanted = agentContext(agent, model)
        let loaded = server.stats.effectiveContext ?? model.contextTokens(record.context) ?? 0
        guard let wantedTokens = model.contextTokens(wanted), loaded < wantedTokens, wanted != record.context else {
            return fit?.level == .overflow ? LaunchWarning(agent: agent, project: project, message: fit!.message) : nil
        }
        let name = Agents.displayName(agent), label = model.contextLabel(wanted).replacingOccurrences(of: " (Max)", with: "")
        let (need, measured) = Agents.promptTokens(agent)
        var message = "\(model.name) is loaded with a \(shortTokens(loaded))-token context. \(name) sends \(measured ? "" : "about ")\(shortTokens(need)) tokens before you type, and every file it reads and command it runs adds more, so on this context it runs out of room within a few steps and its replies get cut off. \(name) works best with \(label)."
        if let fits = SystemMemory.tokensThatFit(model), fits < wantedTokens {
            message += " About \(shortTokens(fits)) tokens fit in the memory free now; Kapitsa will use as much as fits."
        }
        message += " Reloading takes a moment, and anything else using the model disconnects."
        return LaunchWarning(agent: agent, project: project, message: message, reload: wanted, reloadLabel: label)
    }

    /// Stops the loaded model, loads it again with a larger context, then launches the agent.
    func reloadAndLaunch(_ agent: String, project: URL, context: String) {
        guard let record = server.record, let model = model(at: record.modelPath) else { launch(agent, project: project, force: true); return }
        let port = record.port
        Task {
            launching = "Reloading \(model.name) at \(model.contextLabel(context).replacingOccurrences(of: " (Max)", with: ""))…"
            defer { launching = nil }
            server.stop()
            for _ in 0..<100 where server.owned { try? await Task.sleep(nanoseconds: 200_000_000) }
            if server.owned { errorMessage = "The model didn’t stop, so it wasn’t reloaded."; return }
            do {
                // The same port as before, so the agents and apps using it stay connected.
                guard try await startServer(model, context: context, wanted: port) else { return }
                while server.phase == .starting { try await Task.sleep(nanoseconds: 500_000_000) }
                guard server.phase == .ready else {
                    errorMessage = "\(model.name) failed to load at the larger context. See Logs for details."
                    return
                }
                launch(agent, project: project, force: true)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// The context to load for an agent: 64K suits most; an agent that compacts late gets 128K when the model has it.
    private func agentContext(_ agent: String, _ model: LocalModel) -> String {
        if let compacts = Agents.info(agent)?.compactsAt, compacts > 65_536, model.contexts.contains("128k") { return "128k" }
        return model.contexts.contains("64k") ? "64k" : model.largestPreset
    }

    /// Adds a custom agent, or replaces the one with its id.
    func saveCustomAgent(_ agent: CustomAgent) {
        var list = Prefs.customAgents
        if let index = list.firstIndex(where: { $0.id == agent.id }) {
            // A different program has a different prompt size, so measure it again.
            if list[index].executable != agent.executable { forgetPrompt(agent.id) }
            list[index] = agent
        } else { list.append(agent) }
        Prefs.customAgents = list
        agentCatalog = Agents.catalog
        // Found or not right away, so the card doesn't say "not found" until the rescan finishes.
        agents[agent.id] = Agents.locate(agent.executable)
        Task { await scan() }
    }

    func removeCustomAgent(_ id: String) {
        Prefs.customAgents.removeAll { $0.id == id }
        forgetPrompt(id)
        agentCatalog = Agents.catalog
        agents[id] = nil
    }

    private func forgetPrompt(_ id: String) {
        var seen = Prefs.agentPrompts
        seen[id] = nil
        Prefs.agentPrompts = seen
    }

    func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = message
    }
}
