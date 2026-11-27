import CryptoKit
import Foundation

enum ModelStatus: String, Codable {
    case verified, candidate, importable = "import", unsupported, incomplete, companion

    var order: Int { [.verified, .candidate, .importable, .unsupported, .incomplete, .companion].firstIndex(of: self)! }
}

struct LocalModel: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let folder: String
    let library: String
    var format = "MLX"
    var architecture = "unknown"
    var size: Int64 = 0
    var status = ModelStatus.unsupported
    var reason = ""
    var drafter = ""
    /// A model Kapitsa supports whose type the engine in use doesn't run yet: another engine (Settings › Engine) can.
    var needsEngine = false
    /// The folder keeps the model's vision tower (vision_config in config.json), so the chat can take images.
    var vision = false
    var nativeContext: Int?
    var contexts: [String] = []
    /// KV-cache memory per token of conversation, from the config (see `ModelScanner.kvBytesPerToken`).
    var kvBytesPerToken: Int?
    var targetSignature: [Int]?
    var drafterSignature: [Int]?

    var loadable: Bool { status == .verified || status == .candidate }
    /// Listed under Compatible: loadable, convertible, or loadable with another engine.
    var available: Bool { loadable || status == .importable || needsEngine }
    var verified: Bool { status == .verified }
    var sizeLabel: String { String(format: "%.2f GB", Double(size) / 1e9) }
    var statusLabel: String {
        if needsEngine { return "Needs Newer Engine" }
        switch status {
        case .verified: return "Verified"
        case .candidate: return "Compatible"
        case .importable: return "Requires Conversion"
        case .companion: return "Companion File"
        case .incomplete: return "Incomplete"
        case .unsupported: return "Unsupported"
        }
    }
    /// "64k" → 65,536; "max" → the model's own limit; "200000" (a custom context) → itself.
    func contextTokens(_ value: String) -> Int? {
        if value == "max" { return nativeContext }
        if let exact = Int(value) { return exact }
        return Int(value.dropLast()).map { $0 * 1024 }
    }

    /// A preset, or a custom token count within the model's own limit (only when that limit is known).
    func accepts(_ context: String) -> Bool {
        if contexts.contains(context) { return true }
        guard let limit = nativeContext, let tokens = Int(context) else { return false }
        return tokens >= Self.smallestCustom && tokens <= limit
    }

    static let smallestCustom = 4096

    /// "200k", "200000", "1m" or "1.5m" → a token count, else nil. k and m are 1,024 and 1,048,576, as in the
    /// presets and Kapitsa's own `--context`, so "128k" here is the 128K preset.
    static func parseCustomContext(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "")
        if let n = Int(t) { return n }
        guard let unit = t.last, let n = Double(t.dropLast()), n > 0 else { return nil }
        switch unit {
        case "k": return Int(n * 1024)
        case "m": return Int(n * 1_048_576)
        default: return nil
        }
    }

    /// The context value for a typed token count: the preset (or "max") of that size when there is one, the
    /// count itself when the model accepts it, else nil.
    func customContext(_ tokens: Int) -> String? {
        if let preset = contexts.first(where: { contextTokens($0) == tokens }) { return preset }
        return accepts(String(tokens)) ? String(tokens) : nil
    }

    /// The context options to show: the presets, plus the chosen custom size in its place among them.
    func contextOptions(including chosen: String) -> [String] {
        guard !contexts.contains(chosen), accepts(chosen) else { return contexts }
        return (contexts + [chosen]).sorted { (contextTokens($0) ?? .max) < (contextTokens($1) ?? .max) }
    }

    /// The default when no other context is chosen: the largest preset up to 128K. Larger ones (256K, "max",
    /// which can be a million tokens) take far more memory, so they are chosen on purpose; "max" is the answer
    /// only for a model smaller than every preset.
    var largestPreset: String {
        contexts.last { $0 != "max" && (contextTokens($0) ?? 0) <= 131_072 } ?? contexts.last ?? "max"
    }

    func contextLabel(_ value: String) -> String {
        if let exact = Int(value) { return exact % 1_048_576 == 0 ? "\(exact / 1_048_576)M" : shortTokens(exact) }
        guard value == "max" else { return value.uppercased() }
        guard let limit = nativeContext else { return "Maximum" }
        return (limit >= 1_048_576 ? "\(limit / 1_048_576)M" : "\(limit / 1024)K") + " (Max)"
    }
}

/// Classifies model folders and GGUF files the way the bundled Kapitsa (0.2.40) accepts them, without loading weights.
enum ModelScanner {
    static let qwenTypes: Set<String> = ["qwen3_5", "qwen3_5_text", "qwen3_5_moe", "qwen3_5_moe_text", "qwen4_exp", "qwen4_exp_text"]
    static let otherTypes: Set<String> = ["nemotron_h", "flint", "dory", "hy_v4_flash", "inkling2_loop"]
    static let otherClasses = ["NemotronH", "Dory", "Flint", "Clover", "HYV4Flash", "Inkling2Loop"]
    static let ggufArchitectures: Set<String> = ["qwen35", "qwen35moe", "flint"]
    /// A model type with its text-only suffix dropped: qwen3_5_text runs as qwen3_5 does.
    static func familyType(_ type: String) -> String { type.hasSuffix("_text") ? String(type.dropLast(5)) : type }
    static let contexts: [(String, Int)] = [("8k", 8192), ("32k", 32768), ("64k", 65536), ("128k", 131072), ("256k", 262144)]
    static let skipped: Set<String> = ["hf-cache", "kapitsa-runtime", "node_modules", "__pycache__", "prefix-cache", "huggingface"]

    static func identity(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func scan(libraries: [String], verified: [String: RegistryEntry]) -> [LocalModel] {
        var seen = Set<String>(), rows: [LocalModel] = []
        for library in libraries {
            for url in candidates(in: URL(fileURLWithPath: library)) {
                let key = url.resolvingSymlinksInPath().path
                guard seen.insert(key).inserted else { continue }
                rows.append(describe(url, library: library, verified: verified))
            }
        }
        pairDrafters(&rows)
        return rows.sorted { ($0.status.order, $0.name.lowercased()) < ($1.status.order, $1.name.lowercased()) }
    }

    static func candidates(in root: URL) -> [URL] {
        var visited = Set<String>(), found: [URL] = []
        collect(root, depth: 0, visited: &visited, into: &found)
        return found
    }

    /// A folder with a config.json is a model; the rest of the tree is walked at most 6 levels deep. A symbolic link to
    /// a folder is walked too, under the link's own path, so a library of links into model folders kept elsewhere
    /// lists them by the links' names, with the drafters inside them. The enumerator lists nothing under a link and
    /// never enters one, so the real folder is walked and what it holds is named under the link. Every real folder
    /// is walked once, so links back up the tree or two links to one model cannot loop or repeat.
    private static func collect(_ root: URL, depth: Int, visited: inout Set<String>, into found: inout [URL]) {
        let fm = FileManager.default
        let real = root.resolvingSymlinksInPath()
        guard visited.insert(real.path).inserted else { return }
        if fm.fileExists(atPath: root.appendingPathComponent("config.json").path) { found.append(root) }
        guard let walker = fm.enumerator(at: real, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for case let item as URL in walker {
            // The item's path may spell the real folder differently (/private/tmp against /tmp), so the part under
            // it is taken by depth, not by prefix.
            let url = item.pathComponents.suffix(walker.level).reduce(root) { $0.appendingPathComponent($1) }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) || depth + walker.level >= 6 { walker.skipDescendants(); continue }
                guard visited.insert(item.resolvingSymlinksInPath().path).inserted else { walker.skipDescendants(); continue }
                if fm.fileExists(atPath: url.appendingPathComponent("config.json").path) { found.append(url) }
            } else if values?.isSymbolicLink == true {
                var isFolder: ObjCBool = false
                if !skipped.contains(url.lastPathComponent), depth + walker.level < 6,
                   fm.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                    collect(url, depth: depth + walker.level, visited: &visited, into: &found)
                } else if url.pathExtension.lowercased() == "gguf" {
                    found.append(url)
                }
            } else if url.pathExtension.lowercased() == "gguf" {
                found.append(url)
            }
        }
    }

    /// Kapitsa's `is_complete`: the manifest is there and every file it lists has the listed size. Kapitsa measures
    /// with stat(), which follows symbolic links, so a listed file that is a link counts by the file it points to.
    static func kapitsaComplete(_ url: URL) -> Bool {
        guard let manifest = readJSON(url.appendingPathComponent(".kapitsa/manifest.json")),
              let files = manifest["files"] as? [[String: Any]] else { return false }
        let fm = FileManager.default
        return files.allSatisfy { file in
            guard let path = file["path"] as? String, let size = file["size"] as? NSNumber else { return false }
            let attributes = try? fm.attributesOfItem(atPath: url.appendingPathComponent(path).resolvingSymlinksInPath().path)
            return (attributes?[.size] as? NSNumber)?.int64Value == size.int64Value
        }
    }

    static func describe(_ url: URL, library: String, verified: [String: RegistryEntry]) -> LocalModel {
        let rootPath = URL(fileURLWithPath: library).standardizedFileURL.path
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(rootPath) { relative = String(relative.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        var row = LocalModel(id: identity(url.path), name: url.lastPathComponent, path: url.path,
                             folder: relative.isEmpty ? url.lastPathComponent : relative, library: library)
        let fm = FileManager.default
        if url.pathExtension.lowercased() == "gguf" {
            row.format = "GGUF"
            row.size = fm.sizeFollowingLinks(atPath: url.path)
            let lower = url.lastPathComponent.lowercased()
            if lower.contains("mmproj") || lower.contains("imatrix") {
                row.status = .companion
                row.reason = "Vision projector or calibration data, not a standalone model."
                return row
            }
            do { row.architecture = try GGUFHeader.architecture(of: url) } catch {
                row.status = .incomplete; row.reason = error.localizedDescription; return row
            }
            if ggufArchitectures.contains(row.architecture) {
                row.status = .importable
                row.reason = "Requires a one-time conversion. The preview validates the GGUF format first."
            } else {
                row.reason = "Architecture not supported by Kapitsa."
            }
            return row
        }
        let config = readJSON(url.appendingPathComponent("config.json")) ?? [:]
        row.architecture = config["model_type"] as? String ?? "unknown"
        row.vision = config["vision_config"] != nil
        let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let weights = files.filter { $0.hasSuffix(".safetensors") && !$0.hasPrefix(".") }
        row.size = weights.reduce(Int64(0)) { total, name in total + fm.sizeFollowingLinks(atPath: url.appendingPathComponent(name).path) }
        // A folder Kapitsa downloads is complete by Kapitsa's own rule (`is_complete` in src/hub/fetch.cpp, what
        // `kapitsa list` goes by): .kapitsa/manifest.json is there (a pull removes it when it starts and writes it
        // when it finishes) and every file it lists has the listed size. Short of that the download is not finished
        // (paused, or still running), whatever the model's own files look like (Flint ships no
        // model.safetensors.index.json, so a missing shard goes unnoticed by the shard check), and whatever the model
        // is: a folder still being filled is neither a drafter, nor unsupported, nor one for another engine yet.
        if fm.fileExists(atPath: url.appendingPathComponent(".kapitsa").path), !kapitsaComplete(url) {
            row.status = .incomplete
            // (No `kapitsa pull <folder>` hint: for an org--name folder Kapitsa reads the name as a local folder and
            // downloads nothing, and a terminal may not share Nearloop's KAPITSA_HOME.)
            row.reason = "Download not finished: resume it in Discover."
            return row
        }
        let classes = (config["architectures"] as? [String]) ?? []
        if classes.contains(where: { $0.contains("Draft") }) || url.lastPathComponent.lowercased().contains("dflash") {
            row.status = .companion
            row.reason = "Speculative-decoding drafter for a matching model."
            row.drafterSignature = drafterSignature(config)
            return row
        }
        guard let kind = family(config) else {
            row.reason = "Architecture not supported by Kapitsa."
            return row
        }
        // The type the engine looks at is the language model's: llm_config (Nemotron Omni releases such as 3.5
        // Super VL, whose top-level model_type is nemotron_h_omni) or text_config when there is one, else the file's.
        let textType = ((config["llm_config"] as? [String: Any])?["model_type"] as? String)
            ?? ((config["text_config"] as? [String: Any])?["model_type"] as? String)
            ?? (config["model_type"] as? String)
        if let type = textType, engineRuns(type) == false {
            row.reason = "The Kapitsa engine in use doesn’t run \(type) models yet. A newer engine can: choose one in Settings › Engine, such as Kapitsa built from source."
            row.needsEngine = true
            return row
        }
        let index = readJSON(url.appendingPathComponent("model.safetensors.index.json"))
        let shards = Set(((index?["weight_map"] as? [String: String]) ?? [:]).values)
        let missing = shards.filter { !fm.fileExists(atPath: url.appendingPathComponent($0).path) }.sorted()
        if weights.isEmpty || !files.contains("tokenizer.json") || !missing.isEmpty {
            row.status = .incomplete
            row.reason = "Missing weights, tokenizer or indexed shards" + (missing.isEmpty ? "." : ": " + missing.prefix(2).joined(separator: ", "))
            return row
        }
        if kind == "qwen", let problem = quantizationError(config) {
            row.reason = problem
            return row
        }
        row.status = .candidate
        row.reason = kind == "qwen" ? "Supported architecture and quantization. Verified on first load."
                                    : "Supported architecture. Tensor formats are validated on load."
        if let entry = verified[url.path] {
            row.status = .verified
            row.reason = "Verified on this Mac" + (entry.date.map { " · \($0)" } ?? "")
        }
        let text = (config["text_config"] as? [String: Any]) ?? config
        // The limit the config states (`model_max_length` where it has no `max_position_embeddings`); Kapitsa assumes
        // 128K when it states none.
        let native = (text["max_position_embeddings"] as? Int) ?? (text["model_max_length"] as? Int) ?? 131072
        row.nativeContext = native
        row.kvBytesPerToken = kvBytesPerToken(text)
        // "Max" only when it is more than the largest preset; a 128K model would otherwise list 128K twice.
        let presets = contexts.filter { $0.1 <= native }
        row.contexts = presets.map(\.0) + (presets.last?.1 == native ? [] : ["max"])
        row.targetSignature = targetSignature(config)
        return row
    }

    /// Memory each token of a conversation takes in the KV cache: keys and values (2) × layers that keep a cache
    /// × KV heads × head size × 2 bytes. Hybrid models (Qwen3.5/3.6, Nemotron) cache only their attention layers,
    /// which is most of the difference between them and dense models. Matches what Kapitsa reports on load.
    /// Every value comes from the model's config, so anything not positive or that overflows means unknown (nil).
    static func kvBytesPerToken(_ text: [String: Any]) -> Int? {
        func product(_ values: [Int]) -> Int? {
            guard values.allSatisfy({ $0 > 0 }) else { return nil }
            return values.reduce(Optional(1)) { total, value in
                total.flatMap { let (result, overflow) = $0.multipliedReportingOverflow(by: value); return overflow ? nil : result }
            }
        }
        guard let layers = text["num_hidden_layers"] as? Int, layers > 0 else { return nil }
        if let rank = text["kv_lora_rank"] as? Int {
            // Multi-head latent attention caches one compressed vector per layer instead of keys and values.
            let rope = max(0, (text["qk_rope_head_dim"] as? Int) ?? 0)
            guard rank > 0, rope <= Int.max - rank else { return nil }
            return product([layers, rank + rope, 2])
        }
        var cached = layers
        if let types = text["layer_types"] as? [String], !types.isEmpty {
            cached = types.filter { $0 == "full_attention" || $0 == "attention" }.count
        } else if let interval = text["full_attention_interval"] as? Int, interval > 0 {
            cached = layers / interval
        } else if let pattern = text["hybrid_override_pattern"] as? String {
            cached = pattern.filter { $0 == "*" }.count
        } else {
            // Layers that attend only within a sliding window (`local_layer_ids`) keep a fixed-size cache, not one
            // per token. A looped model (`loop_config`) runs its core layers `num_passes` times, each pass with a
            // cache of its own. A config with neither caches every layer once.
            let local = Set((text["local_layer_ids"] as? [Int]) ?? [])
            let loop = (text["loop_config"] as? [String: Any]) ?? [:]
            let start = (loop["core_start"] as? Int) ?? 0, end = (loop["core_end"] as? Int) ?? 0
            let passes = max(1, (loop["num_passes"] as? Int) ?? 1)
            cached = (0..<layers).filter { !local.contains($0) }.reduce(0) { $0 + ($1 >= start && $1 < end ? passes : 1) }
        }
        let attentionHeads = (text["num_attention_heads"] as? Int) ?? 0
        guard let heads = (text["num_key_value_heads"] as? Int) ?? (attentionHeads > 0 ? attentionHeads : nil) else { return nil }
        let headDim = (text["head_dim"] as? Int) ?? (attentionHeads > 0 ? ((text["hidden_size"] as? Int) ?? 0) / attentionHeads : 0)
        return product([2, cached, heads, headDim, 2])
    }

    /// Whether the engine in use runs a model type: Kapitsa recognises a config by its literal `model_type`, so an
    /// engine whose binary doesn't contain the name can't load it (a model added to Kapitsa after the engine was
    /// released). nil when there is no engine to ask. Each engine file is mapped, not read, and kept per file and date.
    static func engineRuns(_ type: String) -> Bool? {
        guard !type.isEmpty, let engine = Kapitsa.binary?.resolvingSymlinksInPath() else { return nil }
        let date = (try? engine.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = engine.path + "|" + String(date?.timeIntervalSince1970 ?? 0)
        engineLock.lock(); defer { engineLock.unlock() }
        if engineFile?.key != key {
            guard let data = try? Data(contentsOf: engine, options: .alwaysMapped) else { return nil }
            engineFile = (key, data)
        }
        return engineFile?.data.range(of: Data(type.utf8)) != nil
    }
    private static let engineLock = NSLock()
    nonisolated(unsafe) private static var engineFile: (key: String, data: Data)?

    static func family(_ config: [String: Any]) -> String? {
        let type = config["model_type"] as? String ?? ""
        if qwenTypes.contains(type) { return "qwen" }
        let classes = ((config["architectures"] as? [String]) ?? []).joined(separator: " ")
        if otherTypes.contains(type) || otherClasses.contains(where: { classes.contains($0) }) { return "other" }
        return nil
    }

    /// MLX affine layouts Kapitsa's Qwen kernels accept.
    static func quantizationError(_ config: [String: Any]) -> String? {
        let q = (config["quantization"] ?? config["quantization_config"]) as? [String: Any] ?? [:]
        func format(_ values: [String: Any], over base: (Int, Int, String)) -> (Int, Int, String) {
            ((values["bits"] as? Int) ?? base.0, (values["group_size"] as? Int) ?? base.1, (values["mode"] as? String) ?? base.2)
        }
        let base = format(q, over: (16, 64, "affine"))
        let allowed: [Int: Set<Int>] = [3: [64], 4: [32, 64], 5: [64, 128], 6: [64], 8: [64, 128], 16: [64]]
        let overrides = q.values.compactMap { $0 as? [String: Any] }.filter { $0["bits"] != nil }
        for (bits, group, mode) in [base] + overrides.map({ format($0, over: base) }) {
            if mode != "affine" { return "Unsupported quantization mode: \(mode)" }
            if !(allowed[bits]?.contains(group) ?? false) { return "Unsupported \(bits)-bit / group-\(group) layout" }
        }
        let prefixes = Set(q.keys.filter { $0.hasSuffix(".gate_proj") || $0.hasSuffix(".up_proj") }.map { String($0[..<$0.lastIndex(of: ".")!]) })
        for prefix in prefixes {
            let gate = format(q[prefix + ".gate_proj"] as? [String: Any] ?? [:], over: base)
            let up = format(q[prefix + ".up_proj"] as? [String: Any] ?? [:], over: base)
            if gate != up { return "Dense gate/up projections have different quantization formats" }
        }
        return nil
    }

    static func targetSignature(_ config: [String: Any]) -> [Int]? {
        let text = (config["text_config"] as? [String: Any]) ?? config
        let values = [text["num_hidden_layers"], text["hidden_size"], text["vocab_size"] ?? config["vocab_size"]].compactMap { $0 as? Int }
        return values.count == 3 ? values : nil
    }

    /// A DFlash drafter names the target's layer count; width and vocabulary must match too.
    static func drafterSignature(_ config: [String: Any]) -> [Int]? {
        guard config["dflash_config"] != nil else { return nil }
        let values = [config["num_target_layers"], config["hidden_size"], config["vocab_size"]].compactMap { $0 as? Int }
        return values.count == 3 ? values : nil
    }

    /// A model's own drafter (in its folder, such as dflash2/) comes first, when its shape matches the model's
    /// (or a shape is unknown). A drafter on its own is paired only when it is the one loose drafter of that
    /// shape: models of one architecture share the shape, so another model's bundled drafter is never borrowed.
    static func pairDrafters(_ rows: inout [LocalModel]) {
        let drafterRows = rows.filter { $0.drafterSignature != nil }
        let modelPaths = rows.filter(\.loadable).map(\.path)
        func inside(_ path: String, _ folder: String) -> Bool { path.hasPrefix(folder + "/") }
        var loose: [[Int]: [String]] = [:]
        for row in drafterRows where !modelPaths.contains(where: { inside(row.path, $0) }) {
            loose[row.drafterSignature!, default: []].append(row.path)
        }
        for index in rows.indices where rows[index].loadable {
            let path = rows[index].path, signature = rows[index].targetSignature
            if let own = drafterRows.first(where: { inside($0.path, path) && (signature == nil || $0.drafterSignature == signature) }) {
                rows[index].drafter = own.path
            } else if let sig = rows[index].targetSignature, let matches = loose[sig], matches.count == 1 {
                rows[index].drafter = matches[0]
            }
        }
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Reads a GGUF file's general.architecture without touching tensor data.
extension FileManager {
    /// A file's size, measured at the target when the path is a symbolic link (weights are often linked in).
    func sizeFollowingLinks(atPath path: String) -> Int64 {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return ((try? attributesOfItem(atPath: target)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

enum GGUFHeader {
    struct Failure: LocalizedError { let errorDescription: String? }

    static func architecture(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Every length and count below comes from the file, so arithmetic is checked and seeks stay inside it.
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let invalid = Failure(errorDescription: "Invalid GGUF metadata")
        func bytes(_ count: Int) throws -> Data {
            let data = try handle.read(upToCount: count) ?? Data()
            if data.count != count { throw Failure(errorDescription: "Incomplete GGUF header") }
            return data
        }
        func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u64() throws -> UInt64 { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian }
        func skip(_ count: UInt64) throws {
            let (target, overflow) = try handle.offset().addingReportingOverflow(count)
            guard !overflow, target <= length else { throw invalid }
            try handle.seek(toOffset: target)
        }
        func string(keep: Bool = true) throws -> String {
            let size = try u64()
            if size > 128 * 1024 * 1024 { throw Failure(errorDescription: "Invalid GGUF metadata length") }
            if !keep { try skip(size); return "" }
            return String(decoding: try bytes(Int(size)), as: UTF8.self)
        }
        let sizes: [UInt32: UInt64] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        func skipValue(_ kind: UInt32) throws {
            switch kind {
            case 8: _ = try string(keep: false)
            case 9:
                let subtype = try u32(), count = try u64()
                if let size = sizes[subtype] {
                    let (total, overflow) = size.multipliedReportingOverflow(by: count)
                    guard !overflow else { throw invalid }
                    try skip(total)
                }
                else if subtype == 8 && count < 1_000_000 { for _ in 0..<count { _ = try string(keep: false) } }
                else { throw Failure(errorDescription: "Unsupported GGUF metadata array") }
            default:
                guard let size = sizes[kind] else { throw Failure(errorDescription: "Unknown GGUF metadata type") }
                try skip(size)
            }
        }
        guard try bytes(4) == Data("GGUF".utf8), [2, 3].contains(try u32()) else {
            throw Failure(errorDescription: "Not a supported GGUF header")
        }
        _ = try u64()  // tensor count
        let count = try u64()
        if count > 100_000 { throw Failure(errorDescription: "Invalid GGUF metadata count") }
        for _ in 0..<count {
            let key = try string(), kind = try u32()
            if key == "general.architecture" && kind == 8 { return try string() }
            try skipValue(kind)
        }
        return "unknown"
    }
}

struct RegistryEntry: Codable {
    var note: String
    var date: String?
    var context: String?
    var reply: String?
}

/// Models that passed the in-app reply check on this Mac.
enum Registry {
    static var url: URL { AppPaths.support.appendingPathComponent("registry.json") }

    static func load() -> [String: RegistryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: RegistryEntry].self, from: data)) ?? [:]
    }

    static func move(from old: String, to new: String) {
        var all = load()
        guard let entry = all.removeValue(forKey: old) else { return }
        all[new] = entry
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    static func record(_ path: String, _ entry: RegistryEntry) {
        var all = load()
        all[path] = entry
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }
}
