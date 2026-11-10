import AppKit
import Foundation

/// Experimental: an iPhone runs the last layers of a model while the Mac runs the first, while a long prompt
/// is read (prefill). Decode stays on the Mac. Built on the getFaster project: its Tail Worker app on the
/// phone, its shard format, and its prefill hook, loaded into the user's installed oMLX by `offload/serve.py`.
/// Nothing here is specific to one model or one phone: the shard is cut from whichever model is chosen, and
/// how many layers go to the phone comes from the phone's own memory report and from measured speeds.
@MainActor
final class Offload: ObservableObject {
    static let shared = Offload()

    // MARK: - Types

    struct Engine: Equatable {
        let app: URL
        let python: String
        let home: String
        let sitePackages: String
        let resources: String
        let version: String
    }

    struct Phone: Equatable {
        let id: String
        let name: String
        let model: String
        let transport: String
        let udid: String
    }

    struct Worker: Equatable {
        let bundle: String
        let name: String
        let version: String
    }

    struct PhoneFile: Identifiable, Equatable {
        let name: String
        let size: Int64
        var id: String { name }
    }

    struct Inspection {
        let supported: Bool
        let reasons: [String]
        let numLayers: Int
        let layerBytes: [Int64]
        let info: [String: Any]?
        /// Per layer, what it costs the phone: weights plus its share of a 32K-token prompt; and the fixed part.
        let phoneLayerCost: [Int64]
        let phoneFixedCost: Int64
        var fingerprint: String { info?["fingerprint"] as? String ?? "" }
        var modelType: String { info?["model_type"] as? String ?? "" }
        func tailBytes(_ layers: Int) -> Int64 { layerBytes.suffix(max(0, layers)).reduce(0, +) }
    }

    enum State: Equatable { case stopped, preparing, starting, running, failed(String) }

    /// What the engine's prefill hook reports (offload/phone_control.py writes it).
    struct Status {
        var state = "idle"
        var detail = ""
        var enabled = false
        var hookApplied = false
        var hookDetail = ""
        var completed = 0
        var fallbacks = 0
        var skipped = 0
        var tokens = 0
        var activeTokens = 0
        var activeProcessed = 0
        var lastRun: [String: Any]?
        var lastSkip: String?
        var lastFallback: String?
        var device: String?

        init() {}
        init(_ object: [String: Any]) {
            state = object["state"] as? String ?? "idle"
            detail = object["detail"] as? String ?? ""
            enabled = (object["config"] as? [String: Any])?["enabled"] as? Bool ?? false
            let hook = object["hook"] as? [String: Any]
            hookApplied = hook?["applied"] as? Bool ?? false
            hookDetail = hook?["detail"] as? String ?? ""
            completed = object["completed"] as? Int ?? 0
            fallbacks = object["fallbacks"] as? Int ?? 0
            skipped = object["skipped"] as? Int ?? 0
            tokens = object["tokens"] as? Int ?? 0
            if let active = object["active"] as? [String: Any] {
                activeTokens = active["tokens"] as? Int ?? 0
                activeProcessed = active["processed"] as? Int ?? 0
            }
            lastRun = object["last_run"] as? [String: Any]
            // A skip or fall-back counts only when it is newer than the last prompt the phone helped with.
            let finished = lastRun?["finished_at"] as? Double ?? 0
            let skip = object["last_skip"] as? [String: Any], fallback = object["last_fallback"] as? [String: Any]
            lastSkip = (skip?["at"] as? Double ?? 0) > finished ? skip?["reason"] as? String : nil
            lastFallback = (fallback?["at"] as? Double ?? 0) > finished ? fallback?["reason"] as? String : nil
            device = object["device"] as? String
        }
    }

    struct BenchRun: Identifiable {
        let id = UUID()
        let label: String
        let promptTokens: Int
        let firstToken: Double
        let generation: Double?
        let reply: String
        let usedPhone: Bool
        let note: String?
        var prefill: Double { firstToken > 0 ? Double(promptTokens) / firstToken : 0 }
    }

    /// Kept between launches: the running engine, and per phone and model what was learned.
    struct Saved: Codable {
        var pid: Int32 = 0
        var port = 0
        var modelPath = ""
        var modelName = ""
        var tailLayers = 0
        var numLayers = 0
        /// "udid|fingerprint" → most layers that phone can hold for that model (the phone's own figure).
        var fits: [String: Int] = [:]
        /// "udid|fingerprint" → share of layers for the phone at which both sides finish together (measured).
        var balance: [String: Double] = [:]
        /// "udid|fingerprint" → layers the shard on the phone holds, as last prepared.
        var onPhone: [String: Int] = [:]
        /// "udid|fingerprint" of the model the engine serves, so speeds are learned after a relaunch too.
        var servingKey = ""
        /// udid → bytes the Tail Worker has for a shard and one prompt (its `shard` + `available`).
        var budgets: [String: Int64] = [:]

        init() {}
        // Every field optional, so a file from an older build still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
            modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? ""
            modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
            tailLayers = try c.decodeIfPresent(Int.self, forKey: .tailLayers) ?? 0
            numLayers = try c.decodeIfPresent(Int.self, forKey: .numLayers) ?? 0
            fits = try c.decodeIfPresent([String: Int].self, forKey: .fits) ?? [:]
            balance = try c.decodeIfPresent([String: Double].self, forKey: .balance) ?? [:]
            onPhone = try c.decodeIfPresent([String: Int].self, forKey: .onPhone) ?? [:]
            servingKey = try c.decodeIfPresent(String.self, forKey: .servingKey) ?? ""
            budgets = try c.decodeIfPresent([String: Int64].self, forKey: .budgets) ?? [:]
        }
    }

    // MARK: - Published state

    @Published private(set) var engine: Engine?
    @Published private(set) var phone: Phone?
    @Published private(set) var unavailablePhones: [String] = []
    @Published private(set) var worker: Worker?
    @Published private(set) var usbAddress: String?
    @Published private(set) var toolsProblem: String?
    @Published private(set) var phoneFiles: [PhoneFile] = []
    @Published private(set) var checking = false
    @Published private(set) var checkedOnce = false
    @Published private(set) var linkSpeed: Double?

    @Published var modelPath: String { didSet { UserDefaults.standard.set(modelPath, forKey: "offload.model") } }
    /// Layers for the phone chosen by hand; 0 picks them automatically.
    @Published var layerChoice: Int { didSet { UserDefaults.standard.set(layerChoice, forKey: "offload.layers") } }
    @Published var usePhone: Bool { didSet { UserDefaults.standard.set(usePhone, forKey: "offload.enabled"); writeConfig() } }
    @Published var minTokens: Int { didSet { UserDefaults.standard.set(minTokens, forKey: "offload.minTokens"); writeConfig() } }
    @Published private(set) var inspections: [String: Inspection] = [:]
    @Published private(set) var inspecting: String?

    @Published private(set) var state = State.stopped
    @Published private(set) var activity: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var status = Status()
    @Published private(set) var saved: Saved

    @Published private(set) var benchmarking: String?
    @Published private(set) var benchRuns: [BenchRun] = []
    @Published private(set) var benchVerdict: String?
    @Published var benchTokens: Int { didSet { UserDefaults.standard.set(benchTokens, forKey: "offload.benchTokens") } }

    private var process: Process?
    private var poller: Task<Void, Never>?
    private var job: Task<Void, Never>?

    nonisolated static let shardName = "nearloop.safetensors"

    // MARK: - Paths

    static var folder: URL { AppPaths.folder("offload") }
    private static var savedURL: URL { folder.appendingPathComponent("state.json") }
    private static var configURL: URL { folder.appendingPathComponent("phone-config.json") }
    private static var statusURL: URL { folder.appendingPathComponent("phone-status.json") }
    static var logURL: URL { folder.appendingPathComponent("engine.log") }
    private static var shardURL: URL { folder.appendingPathComponent(shardName) }

    /// The Python side, bundled in Contents/Resources/offload.
    static var scripts: URL? {
        if let url = Bundle.main.url(forResource: "offload", withExtension: nil) { return url }
        // A development build run from the project: App/Offload next to the app.
        let dev = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("App/Offload")
        return FileManager.default.fileExists(atPath: dev.appendingPathComponent("serve.py").path) ? dev : nil
    }

    init() {
        let defaults = UserDefaults.standard
        modelPath = defaults.string(forKey: "offload.model") ?? ""
        layerChoice = defaults.integer(forKey: "offload.layers")
        usePhone = defaults.object(forKey: "offload.enabled") as? Bool ?? true
        minTokens = defaults.object(forKey: "offload.minTokens") as? Int ?? 2048
        benchTokens = defaults.object(forKey: "offload.benchTokens") as? Int ?? 8192
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: Self.savedURL))) ?? Saved()
        adopt()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.savedURL, options: .atomic) }
    }

    private func note(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.append("\(time)  \(line)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    var busy: Bool { [.preparing, .starting].contains(state) || benchmarking != nil }
    var running: Bool { state == .running }

    /// Whether the engine on `port` is this one (Home and the menu name it).
    func owns(port: Int) -> Bool { (running || state == .starting) && saved.pid != 0 && saved.port == port }
    var externalName: String { owns(port: Prefs.port) ? "\(saved.modelName) with iPhone" : "External Server" }

    // MARK: - Checks

    /// Finds oMLX, the iPhone, its Tail Worker app and the USB network link.
    func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false; checkedOnce = true }
            engine = Self.findEngine()
            let tools = await Task.detached { Self.deviceToolsProblem() }.value
            toolsProblem = tools
            if tools == nil {
                let (found, others) = await Task.detached { Self.findPhone() }.value
                phone = found
                unavailablePhones = others
                if let found {
                    worker = await Task.detached { Self.findWorker(on: found) }.value
                    if let worker { phoneFiles = await Task.detached { Self.files(on: found, app: worker) }.value }
                } else {
                    worker = nil
                    phoneFiles = []
                }
            }
            usbAddress = await Task.detached { Self.usbNeighbour() }.value
        }
    }

    nonisolated static func findEngine() -> Engine? {
        var apps: [URL] = []
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.omlx") { apps.append(url) }
        apps += ["/Applications/oMLX.app", NSHomeDirectory() + "/Applications/oMLX.app"].map(URL.init(fileURLWithPath:))
        let fm = FileManager.default
        for app in apps {
            let resources = app.appendingPathComponent("Contents/Resources")
            let pythonRoot = resources.appendingPathComponent("Python")
            guard fm.fileExists(atPath: resources.appendingPathComponent("omlx/scheduler.py").path),
                  let home = ((try? fm.contentsOfDirectory(atPath: pythonRoot.path)) ?? []).sorted().last(where: { $0.hasPrefix("cpython-") })
            else { continue }
            let python = pythonRoot.appendingPathComponent("\(home)/bin/python3").path
            let lib = pythonRoot.appendingPathComponent("framework-mlx-base/lib")
            guard fm.isExecutableFile(atPath: python),
                  let version = ((try? fm.contentsOfDirectory(atPath: lib.path)) ?? []).sorted().last(where: { $0.hasPrefix("python3") })
            else { continue }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            return Engine(app: app, python: python, home: pythonRoot.appendingPathComponent(home).path,
                          sitePackages: lib.appendingPathComponent("\(version)/site-packages").path,
                          resources: resources.path, version: info?["CFBundleShortVersionString"] as? String ?? "")
        }
        return nil
    }

    nonisolated static func deviceToolsProblem() -> String? {
        guard let out = try? Kapitsa.runSync("/usr/bin/xcrun", ["--find", "devicectl"], timeout: 15), out.code == 0 else {
            return "Xcode is needed to reach the iPhone (its devicectl tool). Install Xcode from the App Store and open it once."
        }
        return nil
    }

    /// Runs `xcrun devicectl …` and returns its JSON result.
    nonisolated static func devicectl(_ arguments: [String], timeout: TimeInterval) throws -> [String: Any] {
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("nearloop-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: json) }
        let out = try Kapitsa.runSync("/usr/bin/xcrun", ["devicectl"] + arguments + ["--json-output", json.path], timeout: timeout)
        let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: json))) as? [String: Any] ?? [:]
        if out.code != 0 {
            let error = object["error"] as? [String: Any]
            let user = error?["userInfo"] as? [String: Any]
            let reason = (user?["NSLocalizedDescription"] as? [String: Any])?["string"] as? String
                ?? out.output.split(separator: "\n").last(where: { $0.lowercased().contains("error") }).map(String.init)
                ?? "devicectl \(arguments.prefix(3).joined(separator: " ")) failed"
            throw Kapitsa.Failure(errorDescription: reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    /// The first connected iPhone or iPad (a cable first), and the names of known ones that aren't connected.
    nonisolated static func findPhone() -> (Phone?, [String]) {
        guard let result = try? devicectl(["list", "devices"], timeout: 30),
              let devices = result["devices"] as? [[String: Any]] else { return (nil, []) }
        var found: [Phone] = [], others: [String] = []
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["platform"] as? String == "iOS", hardware["reality"] as? String == "physical" else { continue }
            let name = properties["name"] as? String ?? "iPhone"
            let model = hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "iPhone"
            let transport = connection["transportType"] as? String
            if let transport, connection["tunnelState"] as? String != "unavailable" {
                found.append(Phone(id: device["identifier"] as? String ?? "", name: name, model: model,
                                   transport: transport, udid: hardware["udid"] as? String ?? ""))
            } else {
                others.append("\(name) (\(model))")
            }
        }
        found.sort { ($0.transport == "wired" ? 0 : 1) < ($1.transport == "wired" ? 0 : 1) }
        return (found.first, others)
    }

    /// getFaster's Tail Worker app on the phone, whatever bundle prefix it was signed with.
    nonisolated static func findWorker(on phone: Phone) -> Worker? {
        guard let result = try? devicectl(["device", "info", "apps", "--device", phone.id], timeout: 60),
              let apps = result["apps"] as? [[String: Any]] else { return nil }
        let match = apps.first { ($0["bundleIdentifier"] as? String ?? "").lowercased().hasSuffix(".tailworker") }
            ?? apps.first { $0["name"] as? String == "Tail Worker" }
        guard let match, let bundle = match["bundleIdentifier"] as? String else { return nil }
        return Worker(bundle: bundle, name: match["name"] as? String ?? "Tail Worker",
                      version: match["version"] as? String ?? "")
    }

    nonisolated static func files(on phone: Phone, app: Worker) -> [PhoneFile] {
        guard let result = try? devicectl(["device", "info", "files", "--device", phone.id, "--domain-type", "appDataContainer",
                                           "--domain-identifier", app.bundle, "--subdirectory", "Documents"], timeout: 60),
              let files = result["files"] as? [[String: Any]] else { return [] }
        return files.compactMap { file in
            guard let name = file["name"] as? String, name.hasSuffix(".safetensors") else { return nil }
            let size = ((file["metadata"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? 0
            return PhoneFile(name: name, size: size)
        }.sorted { $0.name < $1.name }
    }

    /// The phone's address on the USB network link (Apple's anri interface), if it is up.
    nonisolated static func usbNeighbour() -> String? {
        let table = (try? Kapitsa.runSync("/usr/sbin/ndp", ["-an"], timeout: 5))?.output ?? ""
        for line in table.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 3, parts[0].contains("%anri"), parts[1] != "(incomplete)", !line.contains("permanent") {
                return String(parts[0])
            }
        }
        // The neighbour cache forgets an idle phone, so ask the link who is there.
        let interfaces = (try? Kapitsa.runSync("/sbin/ifconfig", ["-l"], timeout: 5))?.output ?? ""
        for interface in interfaces.split(whereSeparator: \.isWhitespace) where interface.hasPrefix("anri") {
            guard let ping = try? Kapitsa.runSync("/sbin/ping6", ["-c", "2", "-i", "0.2", "ff02::1%\(interface)"], timeout: 6) else { continue }
            var own: Substring?
            for line in ping.output.split(separator: "\n") {
                if line.hasPrefix("PING6"), let arrow = line.range(of: " -->"), let space = line[..<arrow.lowerBound].lastIndex(of: " ") {
                    own = line[line.index(after: space)..<arrow.lowerBound]
                } else if let from = line.range(of: "bytes from "), let comma = line[from.upperBound...].firstIndex(of: ",") {
                    let address = line[from.upperBound..<comma]
                    if address != own { return String(address) }
                }
            }
        }
        return nil
    }

    /// What still stands between this Mac and offloading, in the order to fix it.
    var blocker: String? {
        if engine == nil { return "Install oMLX (free, open source). Nearloop runs it with the iPhone hook added; your oMLX stays unchanged." }
        if Self.scripts == nil { return "Nearloop’s offload files are missing. Reinstall Nearloop." }
        if let toolsProblem { return toolsProblem }
        if phone == nil {
            return unavailablePhones.isEmpty
                ? "Connect your iPhone with a cable, unlock it and tap Trust."
                : "Connect and unlock your iPhone (\(unavailablePhones.joined(separator: ", ")) is known but not connected)."
        }
        if worker == nil { return "Install the Tail Worker app on the iPhone (from the getFaster project, with Xcode)." }
        return nil
    }

    // MARK: - Models

    /// Library models oMLX can load: MLX folders.
    var candidates: [LocalModel] { AppStore.shared.models.filter { $0.loadable && $0.format == "MLX" } }
    /// The chosen model, else the first one the iPhone can share (once checked), else the first.
    var model: LocalModel? {
        candidates.first { $0.path == modelPath }
            ?? candidates.first { inspections[$0.path]?.supported == true }
            ?? candidates.first
    }

    func inspect(_ model: LocalModel) {
        guard inspections[model.path] == nil, inspecting == nil else { return }
        Task { _ = try? await inspection(for: model) }
    }

    private var inspectingAll = false

    /// Checks every candidate in turn (a couple of seconds each, weights stay on disk), so the menu can
    /// say which models the iPhone can share.
    func inspectAll() {
        guard !inspectingAll, engine != nil || Self.findEngine() != nil else { return }
        inspectingAll = true
        Task {
            defer { inspectingAll = false }
            if engine == nil { engine = Self.findEngine() }
            for model in candidates where inspections[model.path] == nil {
                while inspecting != nil { try? await Task.sleep(nanoseconds: 200_000_000) }
                if inspections[model.path] == nil { _ = try? await inspection(for: model) }
            }
        }
    }

    private func inspection(for model: LocalModel) async throws -> Inspection {
        if let known = inspections[model.path] { return known }
        inspecting = model.path
        defer { inspecting = nil }
        let object = try await tool(["inspect", "--model", Kapitsa.loadPath(for: model.path)], timeout: 300)
        let result = Inspection(
            supported: object["supported"] as? Bool ?? false,
            reasons: object["reasons"] as? [String] ?? [object["error"] as? String ?? "Could not read this model"],
            numLayers: object["num_layers"] as? Int ?? 0,
            layerBytes: (object["layer_bytes"] as? [NSNumber] ?? []).map(\.int64Value),
            info: object["info"] as? [String: Any],
            phoneLayerCost: ((object["phone_costs"] as? [String: Any])?["per_layer"] as? [NSNumber] ?? []).map(\.int64Value),
            phoneFixedCost: ((object["phone_costs"] as? [String: Any])?["fixed"] as? NSNumber)?.int64Value ?? 0)
        inspections[model.path] = result
        return result
    }

    private func key(_ inspection: Inspection) -> String { "\(phone?.udid ?? "")|\(inspection.fingerprint)" }

    /// Most layers the phone can hold for this model, once it has said so.
    func fit(for model: LocalModel) -> Int? {
        guard let inspection = inspections[model.path], inspection.supported else { return nil }
        if let budget = saved.budgets[phone?.udid ?? ""], let fit = Self.fit(inspection, budget: budget) { return fit }
        return saved.fits[key(inspection)]
    }

    /// Layers for the phone: the hand-picked number, else the point where the phone and the Mac finish their
    /// parts together (measured on this pair once a prompt has run; half the layers until then), capped by
    /// what the phone can hold.
    func plannedLayers(for model: LocalModel) -> Int? {
        guard let inspection = inspections[model.path], inspection.supported, inspection.numLayers > 1 else { return nil }
        let limit = min(fit(for: model) ?? inspection.numLayers - 1, inspection.numLayers - 1)
        if layerChoice > 0 { return max(1, min(layerChoice, limit)) }
        let share = saved.balance[key(inspection)] ?? 0.5
        return max(1, min(limit, Int((Double(inspection.numLayers) * share).rounded())))
    }

    var autoExplanation: String? {
        guard let model, let inspection = inspections[model.path], inspection.supported else { return nil }
        let k = key(inspection), most = fit(for: model)
        if let share = saved.balance[k] {
            return String(format: "Balanced from measured speeds: the iPhone takes %.0f%% of the layers", share * 100)
                + (most.map { ", up to the \($0) it can hold" } ?? "")
        }
        if let most { return "As many as the iPhone can hold (\(most)), at most half; refined after the first long prompt" }
        return "Measured on the iPhone when you start"
    }

    // MARK: - Python

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for name in ["PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONUSERBASE", "VIRTUAL_ENV"] { env.removeValue(forKey: name) }
        guard let engine else { return env }
        env["PYTHONHOME"] = engine.home
        env["PYTHONPATH"] = "\(engine.resources):\(engine.sitePackages)"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env["NEARLOOP_PHONE_CONFIG"] = Self.configURL.path
        env["NEARLOOP_PHONE_STATUS"] = Self.statusURL.path
        return env
    }

    /// Runs offload/tool.py with oMLX's Python and returns the JSON it prints last.
    private func tool(_ arguments: [String], timeout: TimeInterval) async throws -> [String: Any] {
        guard let engine, let scripts = Self.scripts else { throw Kapitsa.Failure(errorDescription: blocker ?? "oMLX not found") }
        let env = environment(), folder = Self.folder
        let out = try await Task.detached {
            try Kapitsa.runSync(engine.python, ["-B", scripts.appendingPathComponent("tool.py").path] + arguments,
                                env: env, directory: folder, timeout: timeout)
        }.value
        for line in out.output.split(separator: "\n").reversed() {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return object }
        }
        let tail = out.output.split(separator: "\n").suffix(3).joined(separator: " ")
        throw Kapitsa.Failure(errorDescription: tail.isEmpty ? "The offload helper failed (exit \(out.code))." : tail)
    }

    // MARK: - Start and stop

    func start() {
        guard !busy, !running else { return }
        job = Task { await prepareAndStart() }
    }

    func cancelPreparation() {
        job?.cancel()
    }

    private func fail(_ message: String) {
        state = .failed(message)
        activity = nil
        note("Stopped: \(message)")
    }

    private func prepareAndStart() async {
        state = .preparing
        note("Preparing…")
        do {
            if !checkedOnce || phone == nil || worker == nil || engine == nil {
                activity = "Looking for the iPhone…"
                refresh()
                while checking { try await Task.sleep(nanoseconds: 200_000_000) }
            }
            if let blocker { throw Kapitsa.Failure(errorDescription: blocker) }
            guard let model, let phone, let worker else { throw Kapitsa.Failure(errorDescription: "Choose a model.") }
            let server = ServerController.shared
            if server.owned {
                activity = "Stopping \(server.record?.modelName ?? "the loaded model")…"
                note("Stopping the Kapitsa server to free memory and port \(server.port)")
                server.stopAndWait()
            }
            let port = Prefs.port
            if await Task.detached(operation: { ServerController.listener(port) }).value != 0 {
                throw Kapitsa.Failure(errorDescription: "Port \(port) is in use by another application. Stop it or change the port in Settings › Server.")
            }

            activity = "Reading \(model.name)…"
            let inspection = try await inspection(for: model)
            guard inspection.supported else {
                throw Kapitsa.Failure(errorDescription: "\(model.name) can’t be split with the iPhone: " + inspection.reasons.joined(separator: "; "))
            }
            let k = key(inspection)
            let total = inspection.numLayers
            note("\(model.name): \(total) layers, \(inspection.modelType), fingerprint \(inspection.fingerprint)")

            // What the phone holds now: a shard of this model, for how many layers, and how many it could hold.
            activity = "Checking the iPhone…"
            phoneFiles = await Task.detached { Self.files(on: phone, app: worker) }.value
            var ready: [String: Any]? = nil
            if phoneFiles.contains(where: { $0.name == Self.shardName && $0.size > 0 }) {
                ready = try await launchAndGreet(inspection, phone: phone, worker: worker, quietMismatch: true)
            }
            learnBudget(ready, phone: phone)
            if saved.budgets[phone.udid] == nil {
                // The phone reports its memory only once it serves a shard: a one-layer shard tells it, once
                // per phone. Every model is then sized from that budget.
                activity = "Measuring the iPhone’s memory…"
                note("Asking the iPhone for its memory with one layer of \(model.name)")
                try await export(model, inspection: inspection, layers: 1, phone: phone, worker: worker)
                ready = try await launchAndGreet(inspection, phone: phone, worker: worker, quietMismatch: false)
                learnBudget(ready, phone: phone)
            }
            if let budget = saved.budgets[phone.udid], let fit = Self.fit(inspection, budget: budget) {
                saved.fits[k] = fit
            } else if let fit = (ready?["memory"] as? [String: Any])?["max_tail_layers"] as? Int {
                saved.fits[k] = fit
            } else if saved.fits[k] == nil {
                throw Kapitsa.Failure(errorDescription: "The iPhone didn’t report its free memory. Keep the Tail Worker app open and try again.")
            }
            note("The iPhone can hold \(saved.fits[k] ?? 0) of \(total) layers")
            persist()
            guard let fit = saved.fits[k], fit >= 1 else {
                throw Kapitsa.Failure(errorDescription: "The iPhone doesn’t have enough free memory for even one layer of \(model.name). Close other apps on the phone and try again.")
            }
            guard let want = plannedLayers(for: model) else { throw Kapitsa.Failure(errorDescription: "Could not plan the split.") }
            let holds = (ready?["tail_start"] as? Int).map { total - $0 }
            if holds != want {
                activity = "Cutting \(want) of \(total) layers for the iPhone…"
                note("Exporting layers \(total - want)…\(total - 1) (\(Self.gigabytes(inspection.tailBytes(want))))")
                try await export(model, inspection: inspection, layers: want, phone: phone, worker: worker)
                ready = try await launchAndGreet(inspection, phone: phone, worker: worker, quietMismatch: false)
                guard let start = ready?["tail_start"] as? Int, total - start == want else {
                    throw Kapitsa.Failure(errorDescription: "The iPhone didn’t load its layers. Keep the Tail Worker app open and unlocked, then try again.")
                }
            } else {
                note("The iPhone already holds layers \(total - want)…\(total - 1)")
            }
            saved.onPhone[k] = want
            persist()

            activity = "Measuring the USB link…"
            let link = try? await tool(["link", "--rounds", "3"], timeout: 60)
            if let speed = link?["mb_per_second"] as? Double {
                linkSpeed = speed
                note(String(format: "USB link: %.0f MB/s, %.1f ms round trip", speed, link?["round_trip_ms"] as? Double ?? 0))
            }

            try Task.checkCancellation()
            state = .starting
            activity = "Starting the engine with \(model.name)…"
            try launchEngine(model, inspection: inspection, layers: want, port: port)
            try await waitUntilServing(port: port)
            state = .running
            activity = nil
            note("Serving \(model.name) on port \(port); the iPhone runs \(want) of \(total) layers for prompts over \(shortTokens(minTokens)) tokens")
            refreshPhoneFiles()
        } catch is CancellationError {
            stopEngine()
            fail("Cancelled")
        } catch {
            if process != nil { stopEngine() }
            fail(error.localizedDescription)
        }
    }

    /// The phone's `shard` + `available` bytes: what it has for layers and a prompt, whatever the model.
    private func learnBudget(_ ready: [String: Any]?, phone: Phone) {
        guard let memory = ready?["memory"] as? [String: Any],
              let shard = (memory["shard"] as? NSNumber)?.int64Value,
              let available = (memory["available"] as? NSNumber)?.int64Value, available > 0 else { return }
        saved.budgets[phone.udid] = shard + available
        note("The iPhone has \(Self.gigabytes(shard + available)) for layers and prompts")
        persist()
    }

    /// Most of this model's last layers whose weights and 32K-token prompt fit the phone's budget,
    /// by the Tail Worker's own rules (worked out per layer by offload/tool.py).
    static func fit(_ inspection: Inspection, budget: Int64) -> Int? {
        guard !inspection.phoneLayerCost.isEmpty else { return nil }
        // 8% stays free: iOS ends an app at its limit, and the phone's own check averages layers.
        var room = budget * 92 / 100 - inspection.phoneFixedCost, count = 0
        for cost in inspection.phoneLayerCost.reversed().dropLast() {
            room -= cost
            if room < 0 { break }
            count += 1
        }
        return count
    }

    /// (Re)starts the Tail Worker on our shard and shakes hands as the server will. Nil when the phone holds
    /// a different model and `quietMismatch` is set.
    private func launchAndGreet(_ inspection: Inspection, phone: Phone, worker: Worker, quietMismatch: Bool) async throws -> [String: Any]? {
        _ = try await Task.detached {
            try Self.devicectl(["device", "process", "launch", "--device", phone.id, "--terminate-existing", worker.bundle,
                                "--autostart", Self.shardName], timeout: 60)
        }.value
        guard let info = inspection.info, let data = try? JSONSerialization.data(withJSONObject: info),
              let json = String(data: data, encoding: .utf8) else { throw Kapitsa.Failure(errorDescription: "Missing model facts") }
        let reply = try await tool(["hello", "--info", json, "--wait", "90"], timeout: 150)
        if reply["ok"] as? Bool == true { return reply["ready"] as? [String: Any] }
        let message = reply["error"] as? String ?? "no reply"
        if reply["reachable"] as? Bool == true, message.contains("mismatch"), quietMismatch {
            note("The iPhone holds layers of another model")
            return nil
        }
        if reply["reachable"] as? Bool == false {
            throw Kapitsa.Failure(errorDescription: "The Tail Worker app didn’t start serving. Unlock the iPhone, keep the app on screen, and try again. (\(message))")
        }
        throw Kapitsa.Failure(errorDescription: "The iPhone refused: \(message)")
    }

    /// Cuts the last `layers` layers into a shard, copies it to the phone (replacing the previous one) and
    /// deletes the Mac's copy.
    private func export(_ model: LocalModel, inspection: Inspection, layers: Int, phone: Phone, worker: Worker) async throws {
        let need = inspection.tailBytes(layers)
        let free = (try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if free < need + 2_000_000_000 {
            throw Kapitsa.Failure(errorDescription: "Not enough free disk space to prepare the iPhone’s layers: \(Self.gigabytes(need)) are needed briefly and \(Self.gigabytes(free)) is free.")
        }
        defer { try? FileManager.default.removeItem(at: Self.shardURL) }
        let result = try await tool(["export", "--model", Kapitsa.loadPath(for: model.path), "--tail-layers", String(layers),
                                     "--out", Self.shardURL.path], timeout: 1800)
        guard result["ok"] as? Bool == true else {
            throw Kapitsa.Failure(errorDescription: result["error"] as? String ?? "Export failed")
        }
        try Task.checkCancellation()
        // Stop the worker before its shard is replaced underneath it.
        _ = try? await Task.detached {
            try Self.devicectl(["device", "process", "launch", "--device", phone.id, "--terminate-existing", worker.bundle], timeout: 60)
        }.value
        activity = "Copying \(Self.gigabytes(need)) to the iPhone…"
        let started = Date()
        let source = Self.shardURL.path
        _ = try await Task.detached {
            try Self.devicectl(["device", "copy", "to", "--device", phone.id, "--domain-type", "appDataContainer",
                                "--domain-identifier", worker.bundle, "--source", source,
                                "--destination", "Documents/\(Self.shardName)"], timeout: 3600)
        }.value
        let seconds = Date().timeIntervalSince(started)
        note(String(format: "Copied %@ to the iPhone in %.0f s", Self.gigabytes(need), seconds))
    }

    private func refreshPhoneFiles() {
        guard let phone, let worker else { return }
        Task { phoneFiles = await Task.detached { Self.files(on: phone, app: worker) }.value }
    }

    private func writeConfig() {
        let config: [String: Any] = ["enabled": usePhone, "address": "auto", "min_tokens": minTokens,
                                     "chunk": 0, "max_seed_mb": 2000, "max_inflight": 2]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }

    private func setPhoneForBenchmark(_ enabled: Bool) {
        let config: [String: Any] = ["enabled": enabled, "address": "auto", "min_tokens": 1024,
                                     "chunk": 0, "max_seed_mb": 2000, "max_inflight": 2]
        if let data = try? JSONSerialization.data(withJSONObject: config) { try? data.write(to: Self.configURL, options: .atomic) }
    }

    private func launchEngine(_ model: LocalModel, inspection: Inspection, layers: Int, port: Int) throws {
        guard let engine, let scripts = Self.scripts else { throw Kapitsa.Failure(errorDescription: blocker ?? "oMLX not found") }
        let fm = FileManager.default
        let folder = Self.folder
        // oMLX serves every folder in --model-dir; this one holds a link to the chosen model only.
        let models = folder.appendingPathComponent("models")
        try? fm.removeItem(at: models)
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        let id = model.name.replacingOccurrences(of: #"[^A-Za-z0-9_.-]+"#, with: "-", options: .regularExpression)
        try fm.createSymbolicLink(atPath: models.appendingPathComponent(id).path, withDestinationPath: Kapitsa.loadPath(for: model.path))
        // Any requested model name reaches the one loaded, as Nearloop's chat and agents expect.
        let home = folder.appendingPathComponent("omlx-home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let settingsURL = home.appendingPathComponent("settings.json")
        var settings = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) as? [String: Any]) ?? [:]
        var modelSettings = settings["model"] as? [String: Any] ?? [:]
        modelSettings["model_fallback"] = true
        settings["model"] = modelSettings
        try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted).write(to: settingsURL, options: .atomic)
        writeConfig()
        try? fm.removeItem(at: Self.statusURL)
        status = Status()

        // The prompt cache on disk: what Settings › Server allows, at most a quarter of free space.
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        let cacheGB = max(2, min(50, Int(Double(free) / 4e9)))
        var arguments = ["-B", scripts.appendingPathComponent("serve.py").path, "serve",
                         "--model-dir", models.path, "--port", String(port),
                         "--host", Prefs.shareOnNetwork ? "0.0.0.0" : "127.0.0.1",
                         "--base-path", home.path, "--headless", "--no-hf-cache"]
        // Same choice as Settings › Server: "0" turns it off, a size like "8G" caps it, "auto" sizes it here.
        let setting = Prefs.diskCache
        if setting == "0" {
            arguments.append("--no-cache")
        } else {
            let size = setting.hasSuffix("G") && Int(setting.dropLast()) != nil ? "\(setting.dropLast())GB" : "\(cacheGB)GB"
            arguments += ["--paged-ssd-cache-dir", home.appendingPathComponent("cache").path,
                          "--paged-ssd-cache-max-size", size]
        }
        if !Prefs.apiKey.isEmpty { arguments += ["--api-key", Prefs.apiKey] }
        // The same memory rule as a Kapitsa load (Settings › Memory): what is free now, less the margin
        // kept for other apps. oMLX's own default tier can sit below a model that fits.
        if Prefs.protectMemory {
            let budget = SystemMemory.safeBudgetGB(), need = SystemMemory.estimatedNeedGB(model)
            if need > budget {
                throw Kapitsa.Failure(errorDescription: String(format: "Not enough free memory: %@ needs about %.0f GB and %.0f GB is free now, keeping %.0f GB for other apps. Close some apps, or turn off Memory Protection in Settings › Memory.", model.name, need, budget, Prefs.memoryMargin))
            }
            arguments += ["--memory-guard-gb", String(format: "%.1f", budget)]
        }

        fm.createFile(atPath: Self.logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: Self.logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: engine.python)
        process.arguments = arguments
        process.environment = environment()
        process.currentDirectoryURL = folder
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.engineEnded(ended.processIdentifier, code: ended.terminationStatus) }
        }
        try process.run()
        self.process = process
        saved.pid = process.processIdentifier
        saved.port = port
        saved.modelPath = model.path
        saved.modelName = model.name
        saved.tailLayers = layers
        saved.numLayers = inspection.numLayers
        saved.servingKey = key(inspection)
        persist()
        note("Engine started (oMLX \(engine.version), PID \(process.processIdentifier))")
        startPolling()
    }

    private func waitUntilServing(port: Int) async throws {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            if saved.pid == 0 || kill(saved.pid, 0) != 0 {
                throw Kapitsa.Failure(errorDescription: "The engine stopped while starting. " + Self.logTail())
            }
            if await Self.healthy(port) {
                // oMLX loads the model on its first request; load it now so the first chat isn't the slow one.
                activity = "Loading the model into memory…"
                _ = try? await complete(prompt: "Reply with OK.", maxTokens: 2, port: port)
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw Kapitsa.Failure(errorDescription: "The engine didn’t start within 3 minutes. " + Self.logTail())
    }

    /// oMLX answers {"status": "healthy"} (Kapitsa says "ok").
    nonisolated static func healthy(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return ["ok", "healthy"].contains(object["status"] as? String ?? "")
    }

    static func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(2).joined(separator: " ")
    }

    func stop() {
        job?.cancel()
        stopEngine()
        state = .stopped
        activity = nil
        note("Stopped")
    }

    private func stopEngine() {
        let pid = saved.pid
        guard pid != 0 else { return }
        if kill(pid, 0) == 0 {
            kill(pid, SIGINT)
            for _ in 0..<50 where kill(pid, 0) == 0 { usleep(100_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGTERM); usleep(500_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        process = nil
        saved.pid = 0
        persist()
        poller?.cancel()
        poller = nil
    }

    private func engineEnded(_ pid: Int32, code: Int32) {
        guard pid == saved.pid else { return }
        process = nil
        saved.pid = 0
        persist()
        poller?.cancel()
        poller = nil
        if state == .running || state == .starting {
            fail("The engine exited (code \(code)). " + Self.logTail())
        }
    }

    /// An engine left running by an earlier launch of Nearloop is picked up again.
    private func adopt() {
        let pid = saved.pid
        guard pid != 0 else { return }
        let command = (try? Kapitsa.runSync("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 3))?.output ?? ""
        // oMLX renames its process to omlx-server once it is up.
        if kill(pid, 0) == 0, command.contains("serve.py") || command.contains("omlx-server") {
            state = .running
            note("Reconnected to the engine (PID \(pid)) serving \(saved.modelName)")
            startPolling()
        } else {
            saved.pid = 0
            persist()
        }
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                self?.readStatus()
                if let pid = self?.saved.pid, pid != 0, self?.process == nil, kill(pid, 0) != 0 {
                    self?.engineEnded(pid, code: -1)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private var lastCompleted = 0

    private func readStatus() {
        guard let data = try? Data(contentsOf: Self.statusURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let next = Status(object)
        if next.completed > lastCompleted, let run = next.lastRun { learn(from: run) }
        lastCompleted = next.completed
        status = next
    }

    /// After each prompt the phone helped with: how fast each side ran per layer, which sets the split that
    /// lets both finish together (used by Auto the next time the iPhone is prepared).
    private func learn(from run: [String: Any]) {
        guard let start = run["tail_start"] as? Int, let total = run["num_layers"] as? Int, start > 0, total > start,
              let mac = run["mac_seconds"] as? Double, let phoneSeconds = run["phone_seconds"] as? Double,
              mac > 0, phoneSeconds > 0, !saved.servingKey.isEmpty else { return }
        let macPerLayer = mac / Double(start), phonePerLayer = phoneSeconds / Double(total - start)
        let ratio = macPerLayer / phonePerLayer
        let share = min(0.9, max(0.05, ratio / (1 + ratio)))
        let k = saved.servingKey
        saved.balance[k] = saved.balance[k].map { 0.5 * $0 + 0.5 * share } ?? share
        persist()
    }

    // MARK: - Requests

    struct Completion {
        let promptTokens: Int
        let completionTokens: Int
        let firstToken: Double
        let total: Double
        let text: String
    }

    /// One streamed chat request; times the first token, which a long prompt makes almost all prefill.
    private func complete(prompt: String, system: String? = nil, maxTokens: Int, port: Int) async throws -> Completion {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 1800
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Prefs.apiKey.isEmpty { request.setValue("Bearer \(Prefs.apiKey)", forHTTPHeaderField: "Authorization") }
        var messages: [[String: Any]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        // Thinking off, so a short reply is an answer rather than the start of a thought.
        let body: [String: Any] = ["model": "local", "messages": messages, "max_tokens": maxTokens, "temperature": 0,
                                   "stream": true, "stream_options": ["include_usage": true],
                                   "chat_template_kwargs": ["enable_thinking": false]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 400 { break } }
            throw Kapitsa.Failure(errorDescription: "The engine answered \(http.statusCode): \(text.prefix(300))")
        }
        var first: Double?, text = "", thinking = "", promptTokens = 0, completionTokens = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let usage = object["usage"] as? [String: Any] {
                promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
            }
            if let delta = ((object["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] {
                let piece = (delta["content"] as? String ?? "")
                let thought = (delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? "")
                if first == nil, !(piece.isEmpty && thought.isEmpty) { first = Date().timeIntervalSince(started) }
                text += piece
                thinking += thought
            }
        }
        let total = Date().timeIntervalSince(started)
        return Completion(promptTokens: promptTokens, completionTokens: completionTokens,
                          firstToken: first ?? total, total: total, text: text.isEmpty ? thinking : text)
    }

    // MARK: - Benchmark

    /// The same long prompt read twice, each time new to the cache: by the Mac alone, then with the iPhone.
    func runBenchmark() {
        guard running, benchmarking == nil else { return }
        benchRuns = []
        benchVerdict = nil
        job = Task { await benchmark() }
    }

    private func benchmark() async {
        let port = saved.port
        defer {
            benchmarking = nil
            writeConfig()
        }
        do {
            benchmarking = "Warming up…"
            setPhoneForBenchmark(false)
            _ = try await complete(prompt: "Reply with OK.", maxTokens: 2, port: port)
            for (label, phoneOn) in [("Mac only", false), ("Mac + iPhone", true)] {
                try Task.checkCancellation()
                benchmarking = "\(label): reading a \(shortTokens(benchTokens))-token prompt…"
                setPhoneForBenchmark(phoneOn)
                try await Task.sleep(nanoseconds: 300_000_000)
                let before = status
                // A fresh opening line makes the whole prompt new to the prompt cache.
                let system = "Session \(UUID().uuidString). You are a careful reader."
                let result = try await complete(prompt: Self.benchmarkText(tokens: benchTokens), system: system, maxTokens: 24, port: port)
                try await Task.sleep(nanoseconds: 900_000_000)
                readStatus()
                let used = status.completed > before.completed
                var note: String?
                if phoneOn, !used {
                    note = status.fallbacks > before.fallbacks ? "The iPhone fell back: \(status.lastFallback ?? "")"
                        : "The iPhone wasn’t used: \(status.lastSkip ?? status.detail)"
                } else if phoneOn, let run = status.lastRun {
                    note = String(format: "Mac %.1f s · iPhone %.1f s of compute · %.0f MB sent, %.0f MB back",
                                  run["mac_seconds"] as? Double ?? 0, run["phone_seconds"] as? Double ?? 0,
                                  (run["sent_bytes"] as? Double ?? 0) / 1e6, (run["received_bytes"] as? Double ?? 0) / 1e6)
                }
                let generation = result.completionTokens > 1 && result.total > result.firstToken
                    ? Double(result.completionTokens - 1) / (result.total - result.firstToken) : nil
                benchRuns.append(BenchRun(label: label, promptTokens: result.promptTokens, firstToken: result.firstToken,
                                          generation: generation, reply: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                          usedPhone: used && phoneOn, note: note))
            }
            if benchRuns.count == 2 {
                let mac = benchRuns[0], both = benchRuns[1]
                let speedup = mac.firstToken / max(0.001, both.firstToken)
                if !both.usedPhone {
                    benchVerdict = "The iPhone wasn’t used, so there is nothing to compare. " + (both.note ?? "")
                } else if speedup >= 1.1 {
                    benchVerdict = String(format: "%.2f× faster prompt reading with the iPhone (%.1f s → %.1f s). Worth using for long prompts.", speedup, mac.firstToken, both.firstToken)
                } else if speedup >= 0.97 {
                    benchVerdict = String(format: "About the same (%.2f×). The iPhone doesn’t help this model on this Mac; try more layers, a longer prompt, or keep it off.", speedup)
                } else {
                    benchVerdict = String(format: "Slower with the iPhone (%.2f×). Keep it off for this model, or try fewer layers.", speedup)
                }
                note("Benchmark at \(shortTokens(mac.promptTokens)) tokens: Mac \(String(format: "%.1f", mac.firstToken)) s, with iPhone \(String(format: "%.1f", both.firstToken)) s")
            }
        } catch is CancellationError {
            benchVerdict = "Benchmark cancelled."
        } catch {
            benchVerdict = "Benchmark failed: \(error.localizedDescription)"
        }
    }

    func cancelBenchmark() { job?.cancel() }

    /// Readable filler of about `tokens` tokens: numbered notes built from a fixed vocabulary, so every run
    /// reads the same amount of text and it looks like ordinary prose to the model.
    static func benchmarkText(tokens: Int) -> String {
        let words = """
        the system reads each request and checks the cache before it schedules work on the device while memory \
        stays within its budget and the report records how long every stage took for later review by the team \
        a model splits the prompt into chunks that pass through layers in order so later layers wait for earlier \
        ones unless two machines share the work and exchange hidden states across a fast cable with little delay \
        engineers measure throughput latency power and temperature then adjust chunk sizes buffers and schedules \
        until results improve without changing answers or losing accuracy on long documents code and tables
        """.split(separator: " ").map(String.init)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(words.count))
        }
        var text = "Below are numbered field notes from a performance study.\n\n"
        var count = 0, note = 1
        // About 1.3 tokens per word for this vocabulary.
        let target = Int(Double(tokens) / 1.3)
        while count < target {
            var sentence = "Note \(note): "
            for _ in 0..<18 { sentence += words[next()] + " " }
            text += sentence.trimmingCharacters(in: .whitespaces) + ".\n"
            count += 20
            note += 1
        }
        return text + "\nIn one short sentence, what are these notes about?"
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: bytes >= 10_000_000_000 ? "%.0f GB" : "%.1f GB", Double(bytes) / 1e9)
    }
}
