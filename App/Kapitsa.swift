import Darwin
import Foundation

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Nearloop")
        // Data from before the app was renamed (verification records, benchmarks, launchers) moves over once.
        let legacy = base.appendingPathComponent("Kapitsa Library")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// UserDefaults keys shared with the Settings view's @AppStorage.
enum Prefs {
    static let defaults: UserDefaults = {
        let defaults = UserDefaults.standard
        // Settings from before the app was renamed, kept under the old bundle ID, carry over once.
        if !defaults.bool(forKey: "migratedFromKapitsaLibrary") {
            defaults.set(true, forKey: "migratedFromKapitsaLibrary")
            for (key, value) in defaults.persistentDomain(forName: "com.adityak2128.kapitsa-library") ?? [:]
            where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        return defaults
    }()
    static var port: Int { let v = defaults.integer(forKey: "port"); return (1024...65535).contains(v) ? v : 8000 }
    /// Requests Kapitsa serves at once; nil lets Kapitsa choose (up to 4, as memory allows). Unset means 1.
    static var slots: Int? {
        guard let value = defaults.object(forKey: "slots") as? Int else { return 1 }
        return value == 0 ? nil : max(1, value)
    }
    /// KV-cache bytes per token Kapitsa reported when each model last loaded, by model path.
    static var kvMeasured: [String: Int] {
        get { (defaults.dictionary(forKey: "kvBytesPerToken") as? [String: Int]) ?? [:] }
        set { defaults.set(newValue, forKey: "kvBytesPerToken") }
    }
    /// Agents' first-request sizes seen on this Mac, by agent id.
    static var agentPrompts: [String: Int] {
        get { (defaults.dictionary(forKey: "agentPromptTokens") as? [String: Int]) ?? [:] }
        set { defaults.set(newValue, forKey: "agentPromptTokens") }
    }
    /// Settings › Images: describe images with the vision sidecar for models that can't read them.
    static var imageSidecar: Bool {
        get { defaults.bool(forKey: "imageSidecar") }
        set { defaults.set(newValue, forKey: "imageSidecar") }
    }
    /// Whether each model read images when it last ran here, by model path: from the engine's log ("images on" at
    /// engine ready; "left out: this model can't read images" on a request).
    static var modelReadsImages: [String: Bool] {
        get { (defaults.dictionary(forKey: "modelReadsImages") as? [String: Bool]) ?? [:] }
        set { defaults.set(newValue, forKey: "modelReadsImages") }
    }
    static var diskCache: String { defaults.string(forKey: "diskCache").flatMap { $0.isEmpty ? nil : $0 } ?? "auto" }
    static var shareOnNetwork: Bool { defaults.bool(forKey: "shareOnNetwork") }
    static var terminal: String { defaults.string(forKey: "terminalApp") ?? "terminal" }
    static var runtimeFolder: String? { defaults.string(forKey: "runtimeFolder").flatMap { $0.isEmpty ? nil : $0 } }
    /// The kapitsa executable chosen in Settings › Engine; nil runs the copy bundled in the app.
    static var engine: String? { defaults.string(forKey: "enginePath").flatMap { $0.isEmpty ? nil : $0 } }
    /// What Nearloop's own source build follows (Settings › Engine › Source): an `EngineSource.Source` id; nil until
    /// chosen, when the checkout's own branch decides.
    static var engineSource: String? {
        get { defaults.string(forKey: "engineSource").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "engineSource") }
    }
    /// Kapitsa's fast profile (docs/profiles.md): the speedups that move outputs no more than the fastest other engine
    /// does, for the Macs and models each one targets. Off: precise, the exact outputs.
    static var fastProfile: Bool { defaults.bool(forKey: "fastProfile") }
    static var libraries: [String] {
        get { defaults.stringArray(forKey: "libraryFolders") ?? [] }
        set { defaults.set(newValue, forKey: "libraryFolders") }
    }
    /// Cap Kapitsa's GPU memory at what is free less a margin, so loading never causes swapping.
    static var protectMemory: Bool { defaults.object(forKey: "protectMemory") as? Bool ?? true }
    static var memoryMargin: Double { let v = defaults.double(forKey: "memoryMargin"); return v > 0 ? v : 2 }
    static var apiKey: String { defaults.string(forKey: "apiKey") ?? "" }
    static var autoStart: Bool { defaults.bool(forKey: "autoStartLastModel") }
    /// On unless turned off in Settings › General.
    static var checkForUpdates: Bool { defaults.object(forKey: "checkForUpdates") as? Bool ?? true }
    static var lastModel: String? {
        get { defaults.string(forKey: "lastModelPath") }
        set { defaults.set(newValue, forKey: "lastModelPath") }
    }
    static var lastContext: String {
        get { defaults.string(forKey: "lastContext") ?? "64k" }
        set { defaults.set(newValue, forKey: "lastContext") }
    }
    static var agentModel: String? {
        get { defaults.string(forKey: "agentModelPath").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "agentModelPath") }
    }
    static var recentProjects: [String] {
        get { (defaults.stringArray(forKey: "recentProjects") ?? []).filter { FileManager.default.fileExists(atPath: $0) } }
        set { defaults.set(Array(newValue.prefix(8)), forKey: "recentProjects") }
    }
    static func rememberProject(_ path: String) {
        recentProjects = [path] + recentProjects.filter { $0 != path }
    }

    /// Carries settings over from the 1.x launcher, which scanned one folder on one SSD.
    static func migrate() {
        guard !defaults.bool(forKey: "migratedV2") else { return }
        defaults.set(true, forKey: "migratedV2")
        guard let old = defaults.string(forKey: "modelsRoot"), FileManager.default.fileExists(atPath: old) else { return }
        if libraries.isEmpty { libraries = [old] }
        let runtime = URL(fileURLWithPath: old).appendingPathComponent("kapitsa-runtime").path
        if runtimeFolder == nil && FileManager.default.fileExists(atPath: runtime) {
            defaults.set(runtime, forKey: "runtimeFolder")
            defaults.set("8G", forKey: "diskCache")
        }
    }
}

enum Kapitsa {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// The kapitsa chosen in Settings › Engine (one installed with Homebrew, or built by the user), as long as it is
    /// usable; else the copy bundled in Contents/MacOS; else KAPITSA_BIN or an installed one (development builds).
    static var binary: URL? {
        if let chosen = chosenEngine { return chosen }
        if let bundled { return bundled }
        if let custom = ProcessInfo.processInfo.environment["KAPITSA_BIN"], FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        return installed.first
    }

    /// The copy bundled in Contents/MacOS, when this build has one.
    static var bundled: URL? { Bundle.main.url(forAuxiliaryExecutable: "kapitsa") }

    /// The engine chosen in Settings › Engine while it can run: it exists, isn't being rebuilt this moment (a server
    /// started then would run a half-linked file), and isn't this app's own `kapitsa` command, which runs the engine
    /// chosen here and would start itself.
    static var chosenEngine: URL? {
        guard let chosen = Prefs.engine, FileManager.default.isExecutableFile(atPath: chosen) else { return nil }
        let url = URL(fileURLWithPath: chosen)
        if isCommand(url) || EngineSource.isBuilding(url) { return nil }
        return url
    }

    /// This app's `kapitsa` command, by whatever path or link it is reached: the script Nearloop writes, known by its
    /// marker, not by where it is. Kapitsa's own installer puts the real kapitsa in ~/.local/bin too (when
    /// /opt/homebrew/bin isn't writable), and that one is an engine like any other.
    static func isCommand(_ url: URL) -> Bool {
        let text = head(url)
        return text.hasPrefix("#!") && (text.contains(commandMarker) || text.contains(legacyCommandMarker))
    }

    /// The first bytes of a file (through any link), enough to tell a script and its marker from an executable.
    private static func head(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url.resolvingSymlinksInPath()) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: 512)) ?? Data(), as: UTF8.self)
    }

    /// A kapitsa inside an app bundle (this Nearloop or another copy) changes only with that app: updating it in
    /// place would break the app's signature.
    static func insideApp(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().pathComponents.contains { $0.hasSuffix(".app") }
    }

    /// The kapitsa executables installed on this Mac: Homebrew's, /usr/local's and any on the login shell's PATH,
    /// one per real file, leaving out the bundled copy and the app's own `kapitsa` command (a kapitsa that Kapitsa's
    /// installer put in ~/.local/bin is listed: it is on loginPath).
    static var installed: [URL] {
        let fm = FileManager.default
        var seen = Set([bundled].compactMap { $0?.resolvingSymlinksInPath().path })
        var found: [URL] = []
        for folder in ["/opt/homebrew/bin", "/usr/local/bin"] + loginPath.split(separator: ":").map(String.init) {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("kapitsa")
            guard fm.isExecutableFile(atPath: url.path), !isCommand(url),
                  seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            found.append(url)
        }
        return found
    }

    static var home: URL {
        if let custom = Prefs.runtimeFolder { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/kapitsa")
    }
    static var downloads: URL { home.appendingPathComponent("models") }

    /// Kapitsa writes logs, downloads and caches under its data folder; a folder left behind by a `sudo` run
    /// (owned by root) makes it quit with "Permission denied". Explain that before starting anything.
    static func storageProblem() -> String? {
        let fm = FileManager.default
        let short = { (url: URL) in url.path.replacingOccurrences(of: fm.homeDirectoryForCurrentUser.path, with: "~") }
        for folder in [home, home.appendingPathComponent("logs"), home.appendingPathComponent("models")] where fm.fileExists(atPath: folder.path) {
            if !fm.isWritableFile(atPath: folder.path) {
                return "Kapitsa cannot write to \(short(folder)) because it is owned by another user. "
                    + "Run sudo chown -R $(whoami) \(short(home)) in Terminal, or choose a different data location in Settings › Storage."
            }
        }
        return nil
    }

    /// Kapitsa's terminal output without colour and screen-control codes, including fragments of
    /// codes split across two reads (e.g. "[?2026h").
    static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]|\[\?[0-9;]+[hl]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The line of Kapitsa's output that explains a failure, if any.
    static func reason(in lines: [String]) -> String? {
        let markers = ["fatal", "error", "permission denied", "can't", "can’t", "insufficient memory", "no such"]
        return lines.last { line in
            let lower = line.lowercased()
            return lower.hasPrefix("kapitsa:") || markers.contains(where: lower.contains)
        }?.replacingOccurrences(of: "[kapitsa] ", with: "")
    }

    private static let pathLock = NSLock()
    private static var cachedShellPath: String?

    /// The PATH the user's own terminal gets. Read once, and again after `refreshShellPath()`.
    static var shellPath: String {
        pathLock.lock()
        defer { pathLock.unlock() }
        if let cachedShellPath { return cachedShellPath }
        let path = readShellPath()
        cachedShellPath = path
        return path
    }

    /// Forgets the PATH, so an agent installed since the last read is found.
    static func refreshShellPath() {
        pathLock.lock()
        cachedShellPath = nil
        pathLock.unlock()
    }

    /// An app opened from Finder inherits only launchd's short PATH, and a login shell alone skips ~/.zshrc
    /// (or ~/.bashrc), where installers such as OpenCode's, Bun's and nvm's add their folders. So ask an
    /// interactive login shell, as a terminal window would; startup files may print banners, so markers pick
    /// the PATH out of whatever else is written.
    private static func readShellPath() -> String {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"]
            .flatMap { ["zsh", "bash"].contains(URL(fileURLWithPath: $0).lastPathComponent) ? $0 : nil } ?? "/bin/zsh"
        let script = #"printf '%s' "__KL_PATH__${PATH}__KL_END__""#
        for (flags, timeout) in [("-ilc", 6.0), ("-lc", 4.0)] {
            guard let output = (try? runSync(shell, [flags, script], timeout: timeout))?.output,
                  let start = output.range(of: "__KL_PATH__"),
                  let end = output.range(of: "__KL_END__", range: start.upperBound..<output.endIndex) else { continue }
            let path = String(output[start.upperBound..<end.lowerBound])
            if !path.isEmpty { return path }
        }
        return fallback
    }

    /// The shell's PATH plus the usual install folders, so agents installed by npm, Homebrew, pipx or the
    /// OpenCode installer are found from the GUI.
    static var loginPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let extras = [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".opencode/bin").path,
                      "/opt/homebrew/bin", "/usr/local/bin"]
        return (shellPath.split(separator: ":").map(String.init) + extras).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ":")
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        // A bundled binary must never replace itself inside the signed app, and a chosen one is updated by whoever
        // installed it (Homebrew, or the user's own build), not behind the app's back.
        env["KAPITSA_NO_AUTO_UPDATE"] = "1"
        // Every engine reads its profile from here (`kapitsa serve --profile` sets the same variable); an engine
        // without a fast member for this Mac and model runs precise either way.
        env["KAPITSA_PROFILE"] = Prefs.fastProfile ? "fast" : "precise"
        if let custom = Prefs.runtimeFolder {
            let root = URL(fileURLWithPath: custom)
            for name in ["tmp", "cache", "huggingface/hub"] {
                try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            env["KAPITSA_HOME"] = custom
            env["HF_HOME"] = root.appendingPathComponent("huggingface").path
            env["HF_HUB_CACHE"] = root.appendingPathComponent("huggingface/hub").path
            env["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
            env["TMPDIR"] = root.appendingPathComponent("tmp").path
        }
        // APFS clones are impossible elsewhere; ask the importer for a real copy.
        if !isAPFS(home) { env["KAPITSA_IMPORT_COPY"] = "1" }
        return env
    }

    static func isAPFS(_ url: URL) -> Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        var info = statfs()
        guard statfs(probe.path, &info) == 0 else { return true }
        let name = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return name == "apfs"
    }

    /// ExFAT and other non-Mac volumes keep "._" metadata files that Kapitsa would read as weights.
    /// Such folders are presented through a view of symbolic links to the real files only.
    static func loadPath(for path: String) -> String {
        let fm = FileManager.default
        let names = rawNames(path)
        guard names.contains(where: { $0.hasPrefix("._") }) else { return path }
        let view = AppPaths.folder("model-links")
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent + "-" + ModelScanner.identity(path).prefix(8))
        try? fm.createDirectory(at: view, withIntermediateDirectories: true)
        let wanted = Set(names.filter { !$0.hasPrefix(".") })
        for name in wanted {
            let link = view.appendingPathComponent(name)
            let target = URL(fileURLWithPath: path).appendingPathComponent(name).path
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != target {
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: view.path)) ?? [] where !wanted.contains(name) {
            try? fm.removeItem(at: view.appendingPathComponent(name))
        }
        return view.path
    }

    /// Directory entries as Kapitsa sees them; FileManager hides "._" AppleDouble files on ExFAT.
    static func rawNames(_ path: String) -> [String] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// An always-clean view for `kapitsa bench`, with the paired drafter where Kapitsa looks for one (<model>/dflash2).
    static func benchView(for model: LocalModel) -> String {
        let fm = FileManager.default
        let view = AppPaths.folder("model-links/bench").appendingPathComponent(model.name + "-" + ModelScanner.identity(model.path).prefix(8))
        try? fm.createDirectory(at: view, withIntermediateDirectories: true)
        let wanted = Set(rawNames(model.path).filter { !$0.hasPrefix(".") })
        for name in (try? fm.contentsOfDirectory(atPath: view.path)) ?? [] where !wanted.contains(name) && name != "dflash2" {
            try? fm.removeItem(at: view.appendingPathComponent(name))
        }
        for name in wanted {
            let link = view.appendingPathComponent(name), target = model.path + "/" + name
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != target {
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
        }
        let draft = view.appendingPathComponent("dflash2")
        if !wanted.contains("dflash2") {
            try? fm.removeItem(at: draft)
            if !model.drafter.isEmpty { try? fm.createSymbolicLink(atPath: draft.path, withDestinationPath: loadPath(for: model.drafter)) }
        }
        return view.path
    }

    /// `kapitsa` on the user's PATH, running the engine Nearloop uses with this app's storage settings.
    static var commandURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kapitsa") }
    static let commandMarker = "# Installed by Nearloop"
    /// The marker the command carried before the app was renamed; such a command shows as outdated.
    static let legacyCommandMarker = "# Installed by Kapitsa Library"

    /// "missing", "installed", "outdated", "kapitsa" (Kapitsa itself, from its own installer, which has the same
    /// agent commands) or "foreign" (some other file Nearloop leaves alone).
    static var commandState: String {
        let path = commandURL.path
        guard FileManager.default.fileExists(atPath: path) else { return "missing" }
        if !isCommand(commandURL) {
            return !head(commandURL).hasPrefix("#!") && FileManager.default.isExecutableFile(atPath: path) ? "kapitsa" : "foreign"
        }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.contains(commandMarker) && text.contains(binary?.path ?? "\0") ? "installed" : "outdated"
    }

    static func installCommand() throws {
        guard let binary else { throw Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        switch commandState {
        case "kapitsa":
            throw Failure(errorDescription: "\(commandURL.path) is Kapitsa itself, from Kapitsa's installer, and already runs kapitsa claude and the other agents. Nearloop leaves it in place; to use it here as well, choose it in Settings › Engine.")
        case "foreign":
            throw Failure(errorDescription: "\(commandURL.path) already exists and was not installed by this app. Remove it first if you want this app's Kapitsa there.")
        default: break
        }
        var script = "#!/bin/zsh\n\(commandMarker). Runs the Kapitsa engine Nearloop uses.\n"
        script += "export KAPITSA_NO_AUTO_UPDATE=1\n"
        if let custom = Prefs.runtimeFolder { script += "export KAPITSA_HOME=\(Agents.quote(custom))\n" }
        script += "exec \(Agents.quote(binary.path)) \"$@\"\n"
        try FileManager.default.createDirectory(at: commandURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: commandURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)
    }

    static func version() -> String {
        guard let binary else { return "Not found" }
        return version(of: binary) ?? "Not found"
    }

    /// What one kapitsa executable says it is ("kapitsa 0.2.39 (d387c2d)"), or nil when it doesn't run.
    static func version(of binary: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              let result = try? runSync(binary.path, ["--version"], env: environment(), timeout: 10) else { return nil }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Whether the engine in use can be updated in place: an installed copy can (`brew upgrade` for a Homebrew install,
    /// Kapitsa's own updater otherwise); the copy bundled in the signed app cannot, it changes only with the app.
    static var updatable: Bool {
        guard let binary else { return false }
        return !insideApp(binary)
    }

    /// What `kapitsa update --check` says: a newer release is out, this one is the latest, or it could not tell.
    enum UpdateCheck: Equatable { case upToDate(String), available(String), unknown(String) }

    /// Asks github.com, through the engine itself, whether a newer release is out. Exit 0: up to date; 100: a newer
    /// release; anything else: no answer (offline, say). The first line of the engine's own words is kept for the UI.
    static func checkForUpdate() -> UpdateCheck {
        guard let binary else { return .unknown("Not found") }
        do {
            let result = try runSync(binary.path, ["update", "--check"], env: environment(), timeout: 30)
            let line = result.output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            switch result.code {
            case 0: return .upToDate(line.isEmpty ? "Up to date" : line)
            case 100: return .available(line.isEmpty ? "A newer release is out" : line)
            default: return .unknown(line.isEmpty ? "Could not check (exit \(result.code))" : line)
            }
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// A Kapitsa that Homebrew installed: its binary lives in <prefix>/Cellar/kapitsa/<version>/bin/kapitsa, and the brew
    /// beside that Cellar updates it. The formula is homebrew/core's `kapitsa` or the tap's `nace-ai/tap/kapitsa`
    /// (INSTALL_RECEIPT.json names the tap), and a `--HEAD` install (version folder HEAD-<commit>) follows main.
    struct Homebrew: Equatable {
        let brew: String
        let formula: String
        let head: Bool
        var command: String { "brew upgrade " + (head ? "--fetch-HEAD " : "") + formula }
    }

    static func homebrew(_ binary: URL) -> Homebrew? {
        let path = binary.resolvingSymlinksInPath().path
        guard let cellar = path.range(of: "/Cellar/kapitsa/") else { return nil }
        let after = path[cellar.upperBound...]
        let versionFolder = after.range(of: "/").map { String(after[..<$0.lowerBound]) } ?? String(after)
        let receipt = String(path[..<cellar.upperBound]) + versionFolder + "/INSTALL_RECEIPT.json"
        let text = (try? String(contentsOfFile: receipt, encoding: .utf8)) ?? ""
        return Homebrew(brew: String(path[..<cellar.lowerBound]) + "/bin/brew",
                        formula: text.contains("\"homebrew/core\"") ? "kapitsa" : "nace-ai/tap/kapitsa",
                        head: versionFolder.hasPrefix("HEAD-"))
    }

    /// Updates an installed engine. A Homebrew install gets `brew upgrade` run here: Kapitsa's own `kapitsa update`
    /// only runs brew from a terminal and, through a pipe like this one, prints the command and exits 1. Any other
    /// installed copy runs `kapitsa update` (its signed download from GitHub). Minutes, not seconds.
    static func update() throws -> Output {
        guard let binary else { throw Failure(errorDescription: "Kapitsa engine not found.") }
        guard updatable else { throw Failure(errorDescription: "This kapitsa is inside an app and changes only with it.") }
        if let brew = homebrew(binary) {
            guard FileManager.default.isExecutableFile(atPath: brew.brew) else {
                throw Failure(errorDescription: "This Kapitsa is Homebrew's, and there is no \(brew.brew) to update it with.")
            }
            var env = environment()
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_COLOR"] = "1"
            env["HOMEBREW_NO_EMOJI"] = "1"
            env["NONINTERACTIVE"] = "1"
            return try runSync(brew.brew, ["upgrade"] + (brew.head ? ["--fetch-HEAD"] : []) + [brew.formula], env: env, timeout: 900)
        }
        return try runSync(binary.path, ["update"], env: environment(), timeout: 600)
    }

    static func fitLabel(gigabytes: Double) -> String {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        // One threshold for badges and recommendations: weights within two-thirds of memory leave room for context.
        if gigabytes <= ram * 0.66 { return "Fits in memory" }
        if gigabytes < ram * 0.85 { return "Tight fit" }
        return "Exceeds memory"
    }

    struct Output { let code: Int32; let output: String }

    /// Stops every process below `pid`, deepest first.
    private static func terminateDescendants(of pid: pid_t, depth: Int = 0) {
        guard depth < 16, let out = try? runSync("/usr/bin/pgrep", ["-P", String(pid)], timeout: 5) else { return }
        for child in out.output.split(whereSeparator: \.isNewline).compactMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }) {
            terminateDescendants(of: child, depth: depth + 1)
            kill(child, SIGTERM)
        }
    }

    @discardableResult
    static func runSync(_ executable: String, _ arguments: [String], env: [String: String]? = nil,
                        directory: URL? = nil, timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let env { process.environment = env }
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        // The deadline covers the process itself, not only its output: a child can close its pipes and keep running.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let deadline = DispatchTime.now() + timeout
        let reader = DispatchQueue.global()
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut || exited.wait(timeout: deadline) == .timedOut {
            // Its children too: a build's make and compilers would otherwise keep running.
            terminateDescendants(of: process.processIdentifier)
            process.terminate()
            throw Failure(errorDescription: "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.first ?? "") timed out")
        }
        return Output(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func run(_ arguments: [String], timeout: TimeInterval) async throws -> Output {
        guard let binary else { throw Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        return try await Task.detached { try runSync(binary.path, arguments, env: environment(), timeout: timeout) }.value
    }
}

/// A long-running kapitsa command (pull, import) whose output is streamed and which can be cancelled.
@MainActor
final class StreamingCommand: ObservableObject {
    @Published var running = false
    @Published var lines: [String] = []
    @Published var exitCode: Int32?
    private var process: Process?

    func start(_ arguments: [String], finished: @escaping (Int32) -> Void = { _ in }) throws {
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = Kapitsa.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            // Progress bars redraw with carriage returns; keep the newest state of each line.
            let parts = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n").map(String.init)
            Task { @MainActor in
                guard let self else { return }
                self.lines.append(contentsOf: parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
            }
        }
        process.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.running = false
                self?.exitCode = process.terminationStatus
                finished(process.terminationStatus)
            }
        }
        lines = []
        exitCode = nil
        running = true
        try process.run()
        self.process = process
    }

    func cancel() {
        if let process, process.isRunning { process.interrupt() }
    }
}
