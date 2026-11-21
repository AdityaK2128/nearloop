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
    var nativeContext: Int?
    var contexts: [String] = []
    /// KV-cache memory per token of conversation, from the config (see `ModelScanner.kvBytesPerToken`).
    var kvBytesPerToken: Int?
    var targetSignature: [Int]?
    var drafterSignature: [Int]?

    var loadable: Bool { status == .verified || status == .candidate }
    var available: Bool { loadable || status == .importable }
    var verified: Bool { status == .verified }
    var sizeLabel: String { String(format: "%.2f GB", Double(size) / 1e9) }
    var statusLabel: String {
        switch status {
        case .verified: return "Verified"
        case .candidate: return "Compatible"
        case .importable: return "Requires Conversion"
        case .companion: return "Companion File"
        case .incomplete: return "Incomplete"
        case .unsupported: return "Unsupported"
        }
    }
    /// "64k" → 65,536; "max" → the model's own limit.
    func contextTokens(_ value: String) -> Int? {
        if value == "max" { return nativeContext }
        if let exact = Int(value) { return exact }   // a custom context, stored as a token count
        return Int(value.dropLast()).map { $0 * 1024 }
    }

    /// A preset, or a custom token count the model supports.
    func accepts(_ context: String) -> Bool {
        if contexts.contains(context) { return true }
        guard let tokens = Int(context), tokens >= 4096 else { return false }
        return tokens <= (nativeContext ?? 131072)
    }

    /// "200k", "200000", "1m" or "1.5m" → a token count (k = 1,000 here, as people type it), else nil.
    static func parseCustomContext(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "")
        if let n = Int(t) { return n }
        guard let unit = t.last, let n = Double(t.dropLast()) else { return nil }
        switch unit {
        case "k": return Int(n * 1_000)
        case "m": return Int(n * 1_000_000)
        default: return nil
        }
    }

    /// The largest preset context ("8k" … "128k"), the default when no other is chosen. "max" can be a
    /// million tokens, so it is only the answer for a model smaller than every preset.
    var largestPreset: String { contexts.last { $0 != "max" } ?? contexts.last ?? "max" }

    func contextLabel(_ value: String) -> String {
        if let exact = Int(value) { return exact.formatted() }
        guard value == "max" else { return value.uppercased() }
        guard let limit = nativeContext else { return "Maximum" }
        return (limit >= 1_048_576 ? "\(limit / 1_048_576)M" : "\(limit / 1024)K") + " (Max)"
    }
}

/// Classifies model folders and GGUF files the way Kapitsa 0.2.39 accepts them, without loading weights.
enum ModelScanner {
    static let qwenTypes: Set<String> = ["qwen3_5", "qwen3_5_text", "qwen3_5_moe", "qwen3_5_moe_text", "qwen4_exp", "qwen4_exp_text"]
    static let otherTypes: Set<String> = ["nemotron_h", "flint", "dory", "hy_v4_flash"]
    static let otherClasses = ["NemotronH", "Dory", "Flint", "Clover", "HYV4Flash"]
    static let ggufArchitectures: Set<String> = ["qwen35", "qwen35moe", "flint"]
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
        let fm = FileManager.default
        var found: [URL] = []
        if fm.fileExists(atPath: root.appendingPathComponent("config.json").path) { found.append(root) }
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return found }
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skipped.contains(url.lastPathComponent) || walker.level >= 6 { walker.skipDescendants(); continue }
                if fm.fileExists(atPath: url.appendingPathComponent("config.json").path) { found.append(url) }
            } else if url.pathExtension.lowercased() == "gguf" {
                found.append(url)
            }
        }
        return found
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
        let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let weights = files.filter { $0.hasSuffix(".safetensors") && !$0.hasPrefix(".") }
        row.size = weights.reduce(Int64(0)) { total, name in total + fm.sizeFollowingLinks(atPath: url.appendingPathComponent(name).path) }
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
        // Kapitsa assumes 128K when a config states no limit.
        let native = (text["max_position_embeddings"] as? Int) ?? 131072
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
        }
        let attentionHeads = (text["num_attention_heads"] as? Int) ?? 0
        guard let heads = (text["num_key_value_heads"] as? Int) ?? (attentionHeads > 0 ? attentionHeads : nil) else { return nil }
        let headDim = (text["head_dim"] as? Int) ?? (attentionHeads > 0 ? ((text["hidden_size"] as? Int) ?? 0) / attentionHeads : 0)
        return product([2, cached, heads, headDim, 2])
    }

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
