import Foundation

struct CatalogVariant: Identifiable, Hashable {
    let id: String          // e.g. qwen3.6-35b-a3b:4bit, what `kapitsa pull` takes
    let family: String
    let variant: String
    let alias: String
    let gigabytes: Double
    var isDefault = false
    var forSmallerMacs = false

    var folder: URL { Kapitsa.downloads.appendingPathComponent("\(family)-\(variant)") }
    var downloaded: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) }
    var bytes: Int64 { Int64(gigabytes * 1e9) }
}

struct CatalogFamily: Identifiable, Hashable {
    let id: String
    var alias = ""
    var about = ""
    var format = ""
    var variants: [CatalogVariant] = []

    var title: String {
        id.split(separator: "-").map { part in
            let text = String(part)
            if text.first?.isNumber == true || text.count <= 3 { return text.uppercased() }
            return text.prefix(1).uppercased() + text.dropFirst()
        }.joined(separator: " ")
    }
    var defaultVariant: CatalogVariant? { variants.first(where: \.isDefault) ?? variants.first }
    var isMoE: Bool { about.localizedCaseInsensitiveContains("MoE") }
}

/// Kapitsa's model catalog, read from `kapitsa --help` (descriptions) and `kapitsa list` (every variant and size).
enum Catalog {

    static func load() throws -> [CatalogFamily] {
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        let help = try Kapitsa.runSync(binary.path, ["--help"], env: Kapitsa.environment(), timeout: 20).output
        let list = try Kapitsa.runSync(binary.path, ["list"], env: Kapitsa.environment(), timeout: 30).output
        return parse(help: help, list: list)
    }

    static func parse(help: String, list: String) -> [CatalogFamily] {
        var families: [CatalogFamily] = []
        var smaller: [String: String] = [:]
        var defaults: [String: String] = [:]
        let header = try! NSRegularExpression(pattern: #"^  ([a-z0-9][\w.\-]*)\s+\(([^)]+)\)\s+[\d.]+ GB\s+(.+)$"#)
        var current: Int?
        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func group(_ i: Int) -> String { String(line[Range(match.range(at: i), in: line)!]) }
                families.append(CatalogFamily(id: group(1), alias: group(2), about: group(3)))
                current = families.count - 1
            } else if let index = current, line.hasPrefix(String(repeating: " ", count: 20)) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("also ") { continue }
                if families[index].format.isEmpty {
                    let id = families[index].id
                    defaults[id] = String(text.prefix { $0 != " " })
                    if let range = text.range(of: "smaller Macs: ") { smaller[id] = String(text[range.upperBound...].prefix { $0 != " " && $0 != ")" }) }
                    families[index].format = text.split(separator: ";").first.map(String.init) ?? text
                }
            } else if !line.hasPrefix(" ") {
                current = nil
            }
        }
        // `kapitsa list` prints downloaded models as rows ("  qwen3.8-27b:4bit    20.17 GB  weights + …") and
        // the rest on one line that starts "Available:" (or "Also available:" once something is downloaded).
        let entry = try! NSRegularExpression(pattern: #"([\w.\-]+):([\w.\-]+) \(([^,]+), ([\d.]+) GB\)"#)
        let downloaded = try! NSRegularExpression(pattern: #"^\s+([\w.\-]+):([\w.\-]+)\s+([\d.]+) GB\b"#, options: .anchorsMatchLines)
        var found: [(family: String, variant: String, alias: String, gigabytes: Double)] = []
        for match in downloaded.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
            func group(_ i: Int) -> String { String(list[Range(match.range(at: i), in: list)!]) }
            found.append((group(1), group(2), "", Double(group(3)) ?? 0))
        }
        let listLine = list.split(separator: "\n").first { $0.hasPrefix("Available:") || $0.hasPrefix("Also available:") }.map(String.init) ?? ""
        for match in entry.matches(in: listLine, range: NSRange(listLine.startIndex..., in: listLine)) {
            func group(_ i: Int) -> String { String(listLine[Range(match.range(at: i), in: listLine)!]) }
            found.append((group(1), group(2), group(3), Double(group(4)) ?? 0))
        }
        for row in found {
            let family = row.family, variant = row.variant
            let alias = row.alias.isEmpty ? (families.first { $0.id == family }?.alias ?? "") : row.alias
            var item = CatalogVariant(id: "\(family):\(variant)", family: family, variant: variant, alias: alias,
                                      gigabytes: row.gigabytes)
            item.isDefault = defaults[family] == variant
            item.forSmallerMacs = smaller[family] == variant
            if let index = families.firstIndex(where: { $0.id == family }) {
                families[index].variants.append(item)
            } else {
                families.append(CatalogFamily(id: family, variants: [item]))
            }
        }
        return families.filter { !$0.variants.isEmpty }
    }

    /// What Kapitsa's catalog says about one variant beyond `kapitsa list`: the Hugging Face repository it
    /// downloads from, and the files it fetches alongside to speed it up.
    struct Details: Equatable {
        let repo: String?
        let speedups: [String]
        /// Hugging Face repositories of this family's DFlash drafters (offered to matching downloaded models).
        var drafters: [String] = []

        var modelCard: URL? { repo.flatMap { URL(string: "https://huggingface.co/\($0)") } }
    }

    /// From `kapitsa pull <spec> --dry-run --json`, which downloads nothing. A family's description says when
    /// it drafts from prompt lookup instead of companion files.
    static func details(_ variant: CatalogVariant, about: String) -> Details? {
        guard let output = try? Kapitsa.runSync(Kapitsa.binary?.path ?? "", ["pull", variant.id, "--dry-run", "--json"],
                                                env: Kapitsa.environment(), timeout: 60).output,
              let line = output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        // Kapitsa names companions by kind ("mtp", "mtp-sidecar", "dflash2", "dflash", …); any other kind is
        // still a drafter of some sort.
        var speedups: [String] = [], drafters: [String] = []
        for companion in (json["companions"] as? [[String: Any]]) ?? [] {
            guard let kind = (companion["kind"] as? String)?.lowercased() else { continue }
            let name = kind.hasPrefix("mtp") ? "MTP" : kind.contains("dflash") ? "DFlash" : "Drafter"
            if !speedups.contains(name) { speedups.append(name) }
            if kind.contains("dflash"), let repo = companion["repo"] as? String, !drafters.contains(repo) { drafters.append(repo) }
        }
        if about.localizedCaseInsensitiveContains("prompt lookup") { speedups.append("Prompt lookup") }
        return Details(repo: json["repo"] as? String, speedups: speedups, drafters: drafters)
    }

    static func fits(_ variant: CatalogVariant) -> Bool { Kapitsa.fitLabel(gigabytes: variant.gigabytes).hasPrefix("Fits") }

    /// Whether Kapitsa's own description of a family presents it for coding or agents.
    static func codingOriented(_ family: CatalogFamily) -> Bool {
        family.about.range(of: #"\b(code|coder|coding|agent|agents|agentic|tool calls?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The model to suggest first on this Mac, decided from Kapitsa's catalog rather than a fixed list: the
    /// largest variant that fits this Mac's memory (each family's default, or its variant for smaller Macs),
    /// preferring families Kapitsa describes for coding or agents.
    static func recommended(_ families: [CatalogFamily]) -> CatalogVariant? {
        let candidates = families.flatMap { family in
            ([family.defaultVariant].compactMap { $0 } + family.variants.filter(\.forSmallerMacs))
                .filter(fits).map { (variant: $0, coding: codingOriented(family)) }
        }
        let pool = candidates.contains(where: \.coding) ? candidates.filter(\.coding) : candidates
        return pool.max { $0.variant.gigabytes < $1.variant.gigabytes }?.variant
    }
}

/// Searches Hugging Face for MLX models Kapitsa can run.
enum HuggingFace {
    struct Model: Identifiable, Decodable, Hashable {
        let id: String
        let downloads: Int?
        let likes: Int?
        let tags: [String]?

        var modelType: String? { tags?.first { ModelScanner.qwenTypes.contains($0) || ModelScanner.otherTypes.contains($0) } }
        /// Kapitsa downloads Qwen3.5-family MLX repositories by name.
        var likelyCompatible: Bool { modelType.map(ModelScanner.qwenTypes.contains) ?? false }
    }

    struct Details {
        let bytes: Int64
        let problem: String?
        /// The repository ships MTP heads (multi-token prediction), which Kapitsa uses as they are.
        var hasMTP = false
        /// A DFlash drafter from Kapitsa's catalog whose shape matches this model, and its size.
        var drafter: String?
        var drafterBytes: Int64 = 0
    }

    static func search(_ query: String) async throws -> [Model] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "filter", value: "mlx"),
                                 URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"),
                                 URLQueryItem(name: "limit", value: "50")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Kapitsa.Failure(errorDescription: "Unable to reach Hugging Face. Check your internet connection.") }
        return try JSONDecoder().decode([Model].self, from: data)
    }

    /// Download size and whether the repository's config is one Kapitsa runs.
    static func details(_ id: String, drafters: [String] = []) async throws -> Details {
        let info = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true")!
        let (data, _) = try await URLSession.shared.data(from: info)
        let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let siblings = (object["siblings"] as? [[String: Any]]) ?? []
        let bytes = siblings.reduce(Int64(0)) { $0 + Int64(($1["size"] as? Int) ?? 0) }
        let configURL = URL(string: "https://huggingface.co/\(id)/resolve/main/config.json")!
        let (configData, response) = try await URLSession.shared.data(from: configURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            return Details(bytes: bytes, problem: "No config.json found. The repository may be gated (set HF_TOKEN) or not an MLX model.")
        }
        guard ModelScanner.family(config) == "qwen" else {
            return Details(bytes: bytes, problem: "Unsupported architecture: \(config["model_type"] as? String ?? "unknown"). Hugging Face downloads support Qwen3.5-family MLX models.")
        }
        var result = Details(bytes: bytes, problem: ModelScanner.quantizationError(config))
        // MTP heads live in the weights (mtp.* tensors) or in a file of their own.
        let names = siblings.compactMap { $0["rfilename"] as? String }
        if names.contains(where: { URL(fileURLWithPath: $0).lastPathComponent.lowercased().hasPrefix("mtp") }) {
            result.hasMTP = true
        } else if names.contains("model.safetensors.index.json"),
                  let index = try? await json("https://huggingface.co/\(id)/resolve/main/model.safetensors.index.json"),
                  let map = index["weight_map"] as? [String: Any] {
            result.hasMTP = map.keys.contains { $0.hasPrefix("mtp.") || $0.contains(".mtp.") }
        }
        // A drafter fits when it was built for a model of exactly this shape (layers, width, vocabulary).
        if let signature = ModelScanner.targetSignature(config) {
            for repo in drafters {
                guard let draft = try? await json("https://huggingface.co/\(repo)/resolve/main/config.json"),
                      ModelScanner.drafterSignature(draft) == signature else { continue }
                result.drafter = repo
                let info = try? await json("https://huggingface.co/api/models/\(repo)?blobs=true")
                result.drafterBytes = ((info?["siblings"] as? [[String: Any]]) ?? []).reduce(0) { $0 + Int64(($1["size"] as? Int) ?? 0) }
                break
            }
        }
        return result
    }

    private static func json(_ address: String) async throws -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// "org/name" from a repository id or a huggingface.co address.
    static func repositoryID(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "huggingface.co/") { value = String(value[range.upperBound...]) }
        let parts = value.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2, parts[0] != "models", parts[0] != "datasets", parts[0] != "spaces" else { return nil }
        let id = "\(parts[0])/\(parts[1])"
        return id.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil ? id : nil
    }
}

/// Downloads run `kapitsa pull`; progress is measured from the size of the folder it fills.
@MainActor
final class Downloads: ObservableObject {
    enum State: Equatable { case preparing, running, pausing, paused, failed(String), finished }

    struct Job: Identifiable {
        let id: String
        var title: String
        var expected: Int64
        var folder: URL?
        var done: Int64 = 0
        var state = State.preparing
        var lastLine = ""
        var fraction: Double { expected > 0 ? min(0.99, Double(done) / Double(expected)) : 0 }
        /// Busy: a second start or a pause is meaningless until this state changes.
        var busy: Bool { [.preparing, .running, .pausing].contains(state) }
        var showsProgress: Bool { state != .finished }
    }

    static let shared = Downloads()
    @Published private(set) var jobs: [String: Job] = [:]
    var finished: (String) -> Void = { _ in }
    private var processes: [String: Process] = [:]

    var active: [Job] { jobs.values.filter(\.busy).sorted { $0.title < $1.title } }

    /// Starts or resumes a download. Ignored while one for the same model is preparing, running or pausing.
    func start(_ spec: String, title: String, expectedBytes: Int64) {
        if attachments[spec] != nil { startFiles(spec, title: title, expectedBytes: expectedBytes); return }
        // A model's drafter comes along whenever the model starts or resumes.
        if let drafter = attachedDrafter(of: spec), jobs[drafter]?.state != .finished, jobs[drafter]?.busy != true {
            startFiles(drafter, title: "\(spec) drafter", expectedBytes: jobs[drafter]?.expected ?? 0)
        }
        guard processes[spec] == nil, jobs[spec]?.busy != true else { return }
        if var job = jobs[spec] {
            // Resuming: keep the progress already on disk instead of dropping back to zero.
            job.state = .preparing
            job.expected = expectedBytes > 0 ? expectedBytes : job.expected
            jobs[spec] = job
        } else {
            jobs[spec] = Job(id: spec, title: title, expected: expectedBytes)
        }
        Task {
            // Resumed without a size (after a relaunch, before Verify): ask Hugging Face for the total.
            if jobs[spec]?.expected ?? 0 <= 0, let total = await Self.repositorySize(spec) { jobs[spec]?.expected = total }
            do {
                let plan = try await Kapitsa.run(["pull", spec, "--dry-run", "--json"], timeout: 60)
                let json = plan.output.split(separator: "\n").last { $0.hasPrefix("{") }.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                guard plan.code == 0, let json else {
                    jobs[spec]?.state = .failed(plan.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "Model not found.")
                    return
                }
                if let dir = json["dir"] as? String { jobs[spec]?.folder = URL(fileURLWithPath: dir) }
                if json["downloaded"] as? Bool == true { complete(spec); return }
                // Paused while preparing: don't start the transfer.
                guard jobs[spec]?.state == .preparing else { jobs[spec]?.state = .paused; return }
                try run(spec)
            } catch {
                jobs[spec]?.state = .failed(error.localizedDescription)
            }
        }
    }

    private func run(_ spec: String) throws {
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["pull", spec]
        process.environment = Kapitsa.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let lines = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
                .map { Kapitsa.clean(String($0)) }
                .filter { !$0.isEmpty }
            guard let last = lines.last else { return }
            Task { @MainActor in self?.jobs[spec]?.lastLine = last }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.processes[spec] = nil
                if finished.terminationStatus == 0 { self.complete(spec) }
                else if self.jobs[spec]?.state == .pausing || finished.terminationReason == .uncaughtSignal || finished.terminationStatus == 130 { self.jobs[spec]?.state = .paused }
                else { self.jobs[spec]?.state = .failed(self.jobs[spec]?.lastLine ?? "Download failed (code \(finished.terminationStatus)).") }
            }
        }
        try process.run()
        processes[spec] = process
        jobs[spec]?.state = .running
        Task { [weak self] in
            while let self, self.processes[spec] != nil {
                if let folder = self.jobs[spec]?.folder {
                    let size = await Task.detached { SystemMemory.allocatedBytes(folder) }.value
                    self.jobs[spec]?.done = size
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func complete(_ spec: String) {
        jobs[spec]?.state = .finished
        jobs[spec]?.done = jobs[spec]?.expected ?? 0
        placeDrafters()
        finished(spec)
    }

    /// Drafter download → the model download it belongs to. Kept across launches, so a paused pair resumes
    /// together.
    private var attachments: [String: String] = UserDefaults.standard.dictionary(forKey: "downloadAttachments") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(attachments, forKey: "downloadAttachments") }
    }

    /// Once both are downloaded, the drafter moves into the model's folder as dflash2/, which makes it that
    /// model's own drafter (see ModelScanner.pairDrafters).
    func attach(drafter: String, to model: String) { attachments[drafter] = model }

    func attachedDrafter(of model: String) -> String? { attachments.first { $0.value == model }?.key }

    /// Downloads a repository's config and weights straight from Hugging Face with curl (resumable), checking
    /// each file's SHA-256. For drafters, which `kapitsa pull` doesn't take (it pulls Qwen3.5-family models).
    func startFiles(_ repo: String, title: String, expectedBytes: Int64) {
        guard processes[repo] == nil, jobs[repo]?.busy != true, jobs[repo]?.state != .finished else { return }
        if var job = jobs[repo] {
            job.state = .preparing
            jobs[repo] = job
        } else {
            jobs[repo] = Job(id: repo, title: title, expected: expectedBytes)
        }
        let folder = Kapitsa.downloads.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--"))
        jobs[repo]?.folder = folder
        Task { await fetchFiles(repo, into: folder) }
    }

    private func fetchFiles(_ repo: String, into folder: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Kapitsa.Failure(errorDescription: "\(repo) is not available on Hugging Face.")
            }
            // Top-level config and weights only: no README, images or other folders.
            let files: [(name: String, size: Int64, sha: String?)] = ((object["siblings"] as? [[String: Any]]) ?? []).compactMap {
                guard let name = $0["rfilename"] as? String, !name.contains("/"),
                      name.hasSuffix(".json") || name.hasSuffix(".safetensors") else { return nil }
                return (name, Int64(($0["size"] as? Int) ?? 0), ($0["lfs"] as? [String: Any])?["sha256"] as? String)
            }
            guard files.contains(where: { $0.name.hasSuffix(".safetensors") }) else {
                throw Kapitsa.Failure(errorDescription: "\(repo) has no weights to download.")
            }
            jobs[repo]?.expected = files.reduce(0) { $0 + $1.size }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard jobs[repo]?.state == .preparing else { jobs[repo]?.state = .paused; return }
            jobs[repo]?.state = .running
            track(repo)
            for file in files {
                let target = folder.appendingPathComponent(file.name)
                let size = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value
                if size == file.size { continue }  // finished and checked in an earlier run
                let partial = folder.appendingPathComponent(file.name + ".part")
                let address = "https://huggingface.co/\(repo)/resolve/main/\(file.name)"
                jobs[repo]?.lastLine = "Downloading \(file.name)…"
                let code = await runToEnd(repo, "/usr/bin/curl", ["-fsSL", "--retry", "3", "-C", "-", "-o", partial.path, address])
                if jobs[repo]?.state == .pausing { jobs[repo]?.state = .paused; return }
                guard code == 0 else { throw Kapitsa.Failure(errorDescription: "Downloading \(file.name) failed (curl \(code)). Retry to resume it.") }
                if let sha = file.sha {
                    jobs[repo]?.lastLine = "Checking \(file.name)…"
                    let path = partial.path
                    let sum = await Task.detached { (try? Kapitsa.runSync("/usr/bin/shasum", ["-a", "256", path], timeout: 1800))?.output }.value
                    guard sum?.split(separator: " ").first.map(String.init) == sha else {
                        try? FileManager.default.removeItem(at: partial)
                        throw Kapitsa.Failure(errorDescription: "\(file.name) didn’t match its checksum and was removed. Retry to download it again.")
                    }
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
            }
            complete(repo)
        } catch {
            jobs[repo]?.state = .failed(error.localizedDescription)
        }
    }

    /// Total bytes of a Hugging Face repository ("org/name"); nil for catalog names or when offline.
    static func repositorySize(_ spec: String) async -> Int64? {
        guard HuggingFace.repositoryID(spec) == spec,
              let url = URL(string: "https://huggingface.co/api/models/\(spec)?blobs=true"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let total = ((object["siblings"] as? [[String: Any]]) ?? []).reduce(Int64(0)) { $0 + Int64(($1["size"] as? Int) ?? 0) }
        return total > 0 ? total : nil
    }

    /// Runs a process as this download's current one (so Pause stops it) and waits for it to end.
    private func runToEnd(_ spec: String, _ executable: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                Task { @MainActor in
                    self.processes[spec] = nil
                    continuation.resume(returning: finished.terminationStatus)
                }
            }
            do {
                try process.run()
                processes[spec] = process
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    /// Progress from the size of the folder being filled, while the download runs.
    private func track(_ spec: String) {
        Task { [weak self] in
            while let self, [.running, .pausing].contains(self.jobs[spec]?.state) {
                if let folder = self.jobs[spec]?.folder {
                    let size = await Task.detached { SystemMemory.allocatedBytes(folder) }.value
                    self.jobs[spec]?.done = size
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func placeDrafters() {
        for (drafter, model) in attachments {
            let modelFolder = jobs[model]?.folder ?? Kapitsa.downloads.appendingPathComponent(model.replacingOccurrences(of: "/", with: "--"))
            guard jobs[drafter]?.state == .finished, jobs[model]?.state == .finished,
                  let source = jobs[drafter]?.folder else { continue }
            let target = modelFolder.appendingPathComponent("dflash2")
            attachments[drafter] = nil
            if FileManager.default.fileExists(atPath: target.path) { continue }
            do { try FileManager.default.moveItem(at: source, to: target) } catch {
                jobs[drafter]?.lastLine = "Drafter kept at \(source.path): \(error.localizedDescription)"
            }
        }
    }

    /// Pauses a download; it shows "Pausing…" until Kapitsa has stopped, then "Paused".
    func pause(_ spec: String) {
        guard let state = jobs[spec]?.state, state == .preparing || state == .running else { return }
        jobs[spec]?.state = .pausing
        processes[spec]?.interrupt()
    }

    /// Before the app quits: pauses every download and waits (up to 10 s) for Kapitsa to stop, since a child
    /// process outlives the app and would keep writing unmanaged. Each resumes from its files on the next launch.
    func pauseAllAndWait() {
        for spec in jobs.keys where jobs[spec]?.state == .preparing || jobs[spec]?.state == .running {
            jobs[spec]?.state = .pausing
            processes[spec]?.interrupt()
        }
        for _ in 0..<100 where processes.values.contains(where: \.isRunning) { usleep(100_000) }
        for process in processes.values where process.isRunning { process.terminate() }
    }

    func dismiss(_ spec: String) { if processes[spec] == nil { jobs[spec] = nil } }

    /// Deletes a model Kapitsa downloaded (`kapitsa rm`).
    func delete(_ spec: String) async throws {
        let result = try await Kapitsa.run(["rm", spec], timeout: 120)
        if result.code != 0 { throw Kapitsa.Failure(errorDescription: result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        jobs[spec] = nil
    }
}
