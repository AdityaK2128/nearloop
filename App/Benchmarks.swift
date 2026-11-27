import Foundation

/// One `kapitsa bench` result file.
struct BenchResult: Identifiable, Hashable {
    let id: String
    let file: URL
    let modelName: String
    var modelPath: String?
    let date: Date?
    let writing: Double?
    let greedy: Double?
    let reading: Double?
    let firstToken: Double?
    let followUp: Double?
    let toolCalls: String
    let peakGB: Double?
    let decoding: String
    let flags: [String]
    let invalid: [String]

    var toolsPass: Bool { toolCalls == "pass" }
    var contention: Bool { flags.contains { $0.contains("CONTENTION") } }
    var repetition: Bool { flags.contains { $0.contains("repetition") } }
    var usesDrafter: Bool { decoding.contains("DFlash") }
    /// Why the generation speed is missing: every decode run was thrown out (the median is null in the file).
    var noGeneration: String? {
        guard writing == nil else { return nil }
        let why = invalid.first { $0.hasPrefix("decode: ") }.map { String($0.dropFirst("decode: ".count)) }
        return "No valid generation run" + (why.map { ": " + $0 } ?? "")
    }

    init?(file: URL, modelPath: String?) {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["kind"] as? String == "kapitsa-bench" else { return nil }
        let results = json["results"] as? [String: Any] ?? [:]
        let model = json["model"] as? [String: Any] ?? [:]
        let prefill = (results["prefill"] as? [[String: Any]])?.first ?? [:]
        id = file.path
        self.file = file
        self.modelPath = modelPath
        modelName = model["name"] as? String ?? file.deletingPathExtension().lastPathComponent
        date = (json["time_utc"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        writing = (results["decode"] as? [String: Any])?["median_tps"] as? Double
        greedy = (results["decode_greedy"] as? [String: Any])?["median_tps"] as? Double
        reading = prefill["tps"] as? Double
        firstToken = prefill["ttft_s"] as? Double
        followUp = prefill["followup_median_s"] as? Double
        toolCalls = results["tool_calls"] as? String ?? "—"
        peakGB = results["peak_memory_gb"] as? Double
        decoding = model["decoding_detail"] as? String ?? model["decoding"] as? String ?? ""
        flags = json["flags"] as? [String] ?? []
        invalid = json["invalid"] as? [String] ?? []
    }
}

enum BenchmarkStore {
    static var folder: URL { AppPaths.folder("benchmarks") }
    private static var indexURL: URL { folder.appendingPathComponent("index.json") }

    static func index() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: indexURL))) ?? [:]
    }

    static func remember(_ file: URL, for path: String) {
        var all = index()
        all[file.lastPathComponent] = path
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: indexURL, options: .atomic) }
    }

    static func move(from old: String, to new: String) {
        let all = index().mapValues { $0 == old ? new : $0 }
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: indexURL, options: .atomic) }
    }

    /// Results this app ran, plus any `kapitsa bench` JSON copied into the folder (matched by model name).
    static func load(models: [LocalModel]) -> [BenchResult] {
        let known = index()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }.compactMap { file in
            guard var result = BenchResult(file: file, modelPath: known[file.lastPathComponent]) else { return nil }
            if result.modelPath == nil {
                result.modelPath = models.first { result.modelName == $0.name || result.modelName.hasPrefix($0.name + "-") }?.path
            }
            return result
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// The fastest result for a model (with its drafter, if one was used).
    static func best(_ results: [BenchResult], for model: LocalModel) -> BenchResult? {
        results.filter { $0.modelPath == model.path }.max { ($0.writing ?? 0) < ($1.writing ?? 0) }
    }
}

/// Runs `kapitsa bench --quick` on one model, only when it fits in free memory, with a watchdog that stops it
/// before macOS starts swapping.
@MainActor
final class BenchmarkRunner: ObservableObject {
    static let shared = BenchmarkRunner()
    @Published private(set) var running: LocalModel?
    @Published private(set) var lines: [String] = []
    @Published private(set) var outcome: String?
    private var process: Process?
    private var stopReason: String?

    func run(_ model: LocalModel, finished: @escaping () -> Void) throws {
        guard running == nil else { throw Kapitsa.Failure(errorDescription: "A benchmark is already running.") }
        guard !ServerController.shared.running else {
            throw Kapitsa.Failure(errorDescription: "Stop the running model first. Benchmarks start a dedicated server.")
        }
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        if let problem = Kapitsa.storageProblem() { throw Kapitsa.Failure(errorDescription: problem) }
        // The same rule as a load (Settings › Memory): with Memory Protection on, the model must fit in what other
        // apps leave; off, the benchmark starts whatever is free, as a load does.
        if Prefs.protectMemory {
            let need = SystemMemory.estimatedNeedGB(model)
            let budget = SystemMemory.safeBudgetGB()
            guard need <= budget else {
                throw Kapitsa.Failure(errorDescription: String(format: "Not enough free memory: %@ needs about %.0f GB and %.0f GB is free now, keeping %.0f GB for other apps. Close some apps, or turn off Memory Protection in Settings › Memory.", model.name, need, budget, Prefs.memoryMargin))
            }
        }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let out = BenchmarkStore.folder.appendingPathComponent("\(model.name)-\(stamp).json")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["bench", "--model", Kapitsa.benchView(for: model), "--quick", "--json", "--out", out.path]
        // `kapitsa bench` leaves NI_MEM_BUDGET out of the server it starts, so safety comes from the
        // free-memory check above and the watchdog below.
        process.environment = Kapitsa.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let parts = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
                .map { Kapitsa.clean(String($0)) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { return }
            Task { @MainActor in self?.lines.append(contentsOf: parts) }
        }
        process.terminationHandler = { [weak self] ended in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                if let reason = self.stopReason {
                    self.outcome = "Benchmark stopped: \(reason)."
                } else if BenchResult(file: out, modelPath: model.path) != nil {
                    BenchmarkStore.remember(out, for: model.path)
                    let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
                    Registry.record(model.path, RegistryEntry(note: "Benchmarked on this Mac", date: day, context: "bench", reply: "benchmark"))
                    self.outcome = "Benchmark complete."
                } else {
                    self.outcome = Kapitsa.reason(in: self.lines)
                        ?? "Benchmark ended without a result (code \(ended.terminationStatus))."
                    // "The server stopped while loading the model. Its log: <path>": the refusal is in that log.
                    if let range = self.outcome?.range(of: "Its log: "), let logPath = self.outcome?[range.upperBound...].trimmingCharacters(in: .whitespaces),
                       let text = try? String(contentsOfFile: (logPath as NSString).expandingTildeInPath, encoding: .utf8) {
                        ModelScanner.rememberRefusal(of: model.path, from: text.components(separatedBy: "\n"))
                        Task { await AppStore.shared.scan() }
                    }
                }
                self.process = nil
                self.running = nil
                finished()
            }
        }
        lines = []
        outcome = nil
        stopReason = nil
        try process.run()
        self.process = process
        running = model
        watch(process)
    }

    private func markStopped(_ reason: String) { stopReason = reason }

    func cancel() {
        guard let process else { return }
        stopReason = "cancelled"
        Self.stopTree(process.processIdentifier)
    }

    /// Stops the benchmark before macOS starts swapping heavily. With Memory Protection off only critical memory
    /// pressure stops it: a model that barely fits is allowed to swap a little, as it is when it is loaded.
    private func watch(_ process: Process) {
        let swapStart = SystemMemory.swapUsedGB()
        let started = Date()
        let protect = Prefs.protectMemory
        Task.detached { [weak self] in
            while process.isRunning {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let free = SystemMemory.availableGB(), swap = SystemMemory.swapUsedGB() - swapStart
                var reason: String?
                if SystemMemory.pressure() >= 4 { reason = "critical memory pressure" }
                else if protect, swap > 1 { reason = String(format: "swap activity (%.1f GB)", swap) }
                else if protect, free < 1.5 { reason = String(format: "low free memory (%.1f GB)", free) }
                else if Date().timeIntervalSince(started) > 2400 { reason = "exceeded the 40-minute time limit" }
                if let reason {
                    await self?.markStopped(reason)
                    Self.stopTree(process.processIdentifier)
                    return
                }
            }
        }
    }

    /// The benchmark starts its own server; stop the whole process tree.
    nonisolated static func stopTree(_ root: Int32) {
        let table = (try? Kapitsa.runSync("/bin/ps", ["-axo", "pid=,ppid="], timeout: 3))?.output ?? ""
        var children: [Int32: [Int32]] = [:]
        for row in table.split(separator: "\n") {
            let parts = row.split(separator: " ").compactMap { Int32($0) }
            if parts.count == 2 { children[parts[1], default: []].append(parts[0]) }
        }
        var tree: [Int32] = [], stack = [root]
        while let pid = stack.popLast() { tree.append(pid); stack += children[pid] ?? [] }
        for pid in tree { kill(pid, SIGINT) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}
