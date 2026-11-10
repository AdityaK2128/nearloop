import Foundation

/// One completed request, from Kapitsa's per-request log summary (the rows of its Requests table).
struct RequestStat: Identifiable {
    let id: Int
    var time = Date()
    var client = ""
    let prompt: Int
    let cached: Int
    let prefillMs: Double?
    let output: Int
    let decodeMs: Double
    let tokensPerSecond: Double
    let finish: String
    let draftYield: Double?

    var promptSpeed: Double? {
        guard let prefillMs, prefillMs > 0 else { return nil }
        return Double(max(0, prompt - cached)) * 1000 / prefillMs
    }
    var cachePercent: Double { prompt > 0 ? Double(cached) / Double(prompt) * 100 : 0 }
}

/// Parses the lines Kapitsa writes to its log; mirrors kapitsa_metrics.py.
struct LogStats {
    var model = ""
    var context: Int?
    var decoding = ""
    var allocated = ""
    var budget = ""
    var drafter = ""
    /// The longest conversation that fits in Kapitsa's memory budget, and what each token of it costs.
    var usableContext: Int?
    var kvPerTokenKB: Int?
    /// Kapitsa's SSD prompt cache: its size cap, conversations restored at load, and whether the disk is too full.
    var promptCacheLimit: String?
    var promptCacheRestored = 0
    var promptCacheNoRoom = false
    var lastLine = ""

    /// The context a conversation can actually use: Kapitsa's fit, else the configured context.
    var effectiveContext: Int? { usableContext.map { min($0, context ?? $0) } ?? context }
    var requests: [RequestStat] = []
    /// Request IDs keep counting after old rows drop off the 50-row history.
    private var nextID = 1
    var outputTokens = 0
    var decodeTokens = 0
    var decodeMs = 0.0

    var meanSpeed: Double? { decodeMs > 0 ? Double(decodeTokens) * 1000 / decodeMs : nil }

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let request = regex(#"\[kapitsa\] (?:chat|messages|responses): prompt (\d+) \(cached (\d+)\) in ([\d.]+|[-–]) ms.*?, (\d+) tokens in ([\d.]+) ms \(([\d.]+) tok/s\), ([^,]+)"#)
    private static let engine = regex(#"engine ready: ([^,]+), context (\d+), [^,]+, ([^,]+)"#)
    private static let memory = regex(#"memory: ([\d.]+ GB) allocated.*?budget ([\d.]+ GB)"#)
    private static let promptCache = regex(#"SSD prefix cache: .*?, up to ([\d.]+ [KMGT]iB).*?: (\d+) conversations? taken back"#)
    private static let cycle = regex(#"([\d.]+) tok/cycle"#)
    private static let fit = regex(#"one conversation up to (\d+) of (\d+) tokens"#)
    private static let perToken = regex(#"\((\d+) KB per token\)"#)

    private static func groups(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// Reads one log line; true when it was a finished request.
    @discardableResult
    mutating func consume(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        lastLine = line
        if let g = Self.groups(Self.engine, line) { model = g[0]; context = Int(g[1]); decoding = g[2] }
        if let g = Self.groups(Self.memory, line) { allocated = g[0]; budget = g[1] }
        if let g = Self.groups(Self.fit, line) { usableContext = Int(g[0]) }
        if let g = Self.groups(Self.perToken, line) { kvPerTokenKB = Int(g[0]) }
        if let g = Self.groups(Self.promptCache, line) { promptCacheLimit = g[0]; promptCacheRestored = Int(g[1]) ?? 0 }
        if line.contains("SSD prefix cache: no room") { promptCacheNoRoom = true }
        if let range = line.range(of: "drafter: ") { drafter = String(line[range.upperBound...].prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces) }
        guard let g = Self.groups(Self.request, line) else { return false }
        let stat = RequestStat(id: nextID, prompt: Int(g[0]) ?? 0, cached: Int(g[1]) ?? 0,
                               prefillMs: Double(g[2]), output: Int(g[3]) ?? 0, decodeMs: Double(g[4]) ?? 0,
                               tokensPerSecond: Double(g[5]) ?? 0, finish: g[6].trimmingCharacters(in: .whitespaces),
                               draftYield: Self.groups(Self.cycle, line).flatMap { Double($0[0]) })
        nextID += 1
        requests.append(stat)
        if requests.count > 50 { requests.removeFirst() }
        outputTokens += stat.output
        // Kapitsa's decode interval starts after the first output token.
        decodeTokens += max(0, stat.output - 1)
        decodeMs += stat.decodeMs
        return true
    }
}

/// Matches finished requests in the log, which don't name their client, to the client the dashboard showed
/// while each was in progress. Requests are paired by prompt size. Requests can finish in any order, so a
/// match uses up only its own observation; when two apps had requests of that size pending, nobody is credited.
struct ClientMatcher {
    private var seen: [(client: String, prompt: Int, at: Date)] = []
    /// Every client seen since the server started.
    private var everyone: Set<String> = []

    /// A request in progress, from a dashboard frame; each one is noted once and refreshed while on screen.
    mutating func saw(client: String, prompt: Int, at now: Date = Date()) {
        guard !client.isEmpty, client != "—" else { return }
        everyone.insert(client)
        if let index = seen.lastIndex(where: { $0.client == client && $0.prompt == prompt }) {
            seen[index].at = now
            return
        }
        seen.append((client, prompt, now))
        if seen.count > 64 { seen.removeFirst(seen.count - 64) }
    }

    /// The client of a finished request with this prompt size, or "" when it can't be told.
    mutating func client(forPrompt prompt: Int, at now: Date = Date()) -> String {
        // A request last on screen half an hour ago finished unlogged (cancelled, say) or was matched already.
        seen.removeAll { now.timeIntervalSince($0.at) > 1800 }
        // The exact size, else within 5%, since the dashboard shortens counts ("5.4K").
        var candidates = seen.indices.filter { seen[$0].prompt == prompt }
        if candidates.isEmpty { candidates = seen.indices.filter { abs(seen[$0].prompt - prompt) <= max(2, prompt / 20) } }
        guard !candidates.isEmpty else {
            // Never on screen: only when a single app has used this server is it safe to say which.
            return everyone.count == 1 ? everyone.first! : ""
        }
        let clients = Set(candidates.map { seen[$0].client })
        guard clients.count == 1, let client = clients.first else { return "" }
        let closest = candidates.min { abs(seen[$0].prompt - prompt) < abs(seen[$1].prompt - prompt) }!
        seen.remove(at: closest)
        return client
    }

    mutating func reset() { seen = []; everyone = [] }
}

/// What Kapitsa's terminal dashboard shows at this moment: the request in progress, if any.
struct LiveActivity: Equatable {
    enum State: Equatable { case idle, waiting, reading, writing }
    var state = State.idle
    var client = ""
    var prompt: Int?
    var cachedPercent: Int?
    var speed: Double?
    var tokens: Int?
    var elapsed: Double?
    var memory: String?
}

/// Reads Kapitsa's dashboard from the pseudo-terminal it draws on. Each redraw is wrapped in the terminal's
/// synchronized-update markers, so a complete frame is the text between them.
final class DashboardReader {
    private let queue = DispatchQueue(label: "kapitsa.dashboard")
    private var buffer = ""
    private var lastPublish = Date.distantPast
    private var last = LiveActivity()
    private var memory: String?
    private let publish: (LiveActivity) -> Void

    init(publish: @escaping (LiveActivity) -> Void) { self.publish = publish }

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    /// "pi  ·  5.4K prompt, 0% cached": Kapitsa shortens counts from 1,000 up (5.4K, 27K, 1.2M).
    private static let promptLine = regex(#"(\S.*?)\s+·\s+([\d.,]+)\s*([KkMm]?)\s+prompt,\s*(\d+)% cached"#)
    private static let writing = regex(#"writing ([\d.]+) tok/s"#)
    private static let reading = regex(#"reading ([\d.]+) tok/s"#)
    private static let progress = regex(#"([\d,]+) tokens\s+·\s+([\d.]+)s"#)
    private static let memory = regex(#"Memory\s+\S*\s*([\d.]+ of [\d.]+ GB)"#)

    private static func groups(_ pattern: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    func feed(_ data: Data) {
        queue.async { [self] in
            buffer += String(decoding: data, as: UTF8.self)
            // The status card, with memory, is printed once as plain text outside the redraw frames.
            let outside = buffer.components(separatedBy: "\u{1B}[?2026h").first ?? ""
            if outside.contains("Memory"), let value = Self.parse(outside).memory, value != memory {
                memory = value
                last.memory = value
                publish(last)
            }
            guard let end = buffer.range(of: "\u{1B}[?2026l", options: .backwards) else {
                if buffer.count > 400_000 { buffer.removeFirst(buffer.count - 100_000) }
                return
            }
            let frames = buffer[..<end.lowerBound].components(separatedBy: "\u{1B}[?2026h")
            buffer = String(buffer[end.upperBound...])
            var activity = Self.parse(frames.last ?? "")
            activity.memory = activity.memory ?? memory
            // About four updates a second, plus every change of state.
            if activity.state != last.state || Date().timeIntervalSince(lastPublish) > 0.25 {
                last = activity
                lastPublish = Date()
                publish(activity)
            }
        }
    }

    /// "5.4K" → 5,400; "12,345" → 12,345; "1.2M" → 1,200,000. Shortened counts are within half a unit.
    static func count(_ number: String, unit: String) -> Int? {
        guard let value = Double(number.replacingOccurrences(of: ",", with: "")) else { return nil }
        let scale: Double = ["k": 1_000, "m": 1_000_000][unit.lowercased()] ?? 1
        return Int((value * scale).rounded())
    }

    static func parse(_ frame: String) -> LiveActivity {
        let text = frame.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]|\x{1B}\][^\x{07}]*\x{07}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\x{2800}-\x{28FF}│╭╮╰╯]"#, with: " ", options: .regularExpression)
        var live = LiveActivity()
        live.memory = groups(memory, text)?[0]
        if let g = groups(promptLine, text) {
            live.client = g[0].trimmingCharacters(in: .whitespaces)
            live.prompt = count(g[1], unit: g[2])
            live.cachedPercent = Int(g[3])
            live.state = .reading
        }
        if let g = groups(reading, text) { live.speed = Double(g[0]); live.state = .reading }
        if let g = groups(writing, text) { live.speed = Double(g[0]); live.state = .writing }
        if let g = groups(progress, text) {
            live.tokens = count(g[0], unit: "")
            live.elapsed = Double(g[1])
        }
        if live.state == .idle && text.contains("waiting for the engine") { live.state = .waiting }
        return live
    }
}

/// What this app needs to recognise its own server after a relaunch or crash.
struct ServerRecord: Codable {
    var pid: Int32
    var executable: String
    var modelPath: String
    var modelName: String
    var apiId: String
    var context: String
    var port: Int
    var log: String
    var offset: UInt64 = 0
    /// Where this run's lines begin in the log, which keeps earlier runs' lines above them.
    var logStart: UInt64?
    /// The key the server was started with; it stays in force until the next load.
    var apiKey: String?
}

@MainActor
final class ServerController: ObservableObject {
    static let shared = ServerController()

    enum Phase: Equatable { case stopped, starting, ready, stopping, failed(String), external }

    @Published private(set) var phase = Phase.stopped
    @Published private(set) var record: ServerRecord?
    @Published private(set) var stats = LogStats()
    @Published private(set) var logLines: [String] = []
    @Published private(set) var processLabel = ""
    @Published private(set) var externalPort = 0
    @Published private(set) var memoryWarning: String?
    @Published private(set) var live = LiveActivity()
    private var swapAtStart = 0.0
    private var terminal: FileHandle?
    private var clients = ClientMatcher()
    /// An agent just launched by the app: its first sizeable request is recorded as its prompt size.
    private var measuring: (agent: String, since: Date)?

    func measurePrompt(of agent: String) { measuring = (agent, Date()) }

    private var process: Process?
    private var logOffset: UInt64 = 0
    private var monitor: Task<Void, Never>?
    private static var recordURL: URL { AppPaths.support.appendingPathComponent("server.json") }

    var owned: Bool { record != nil && [.starting, .ready, .stopping].contains(phase) }
    var running: Bool { owned || phase == .external }
    var port: Int { record?.port ?? Prefs.port }

    init() {
        adoptExisting()
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.refresh(tick: tick)
                tick += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// The key clients must send: the one the running server started with, else the current setting.
    var apiKey: String { record?.apiKey ?? Prefs.apiKey }

    func start(_ model: LocalModel, context: String) throws {
        guard !running else { throw Kapitsa.Failure(errorDescription: "A model is already running. Stop it before loading another.") }
        // A benchmark runs its own server; two models at once would defeat both memory checks and the measurement.
        guard BenchmarkRunner.shared.running == nil else {
            throw Kapitsa.Failure(errorDescription: "A benchmark is running. Wait for it to finish or cancel it before loading a model.")
        }
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        if let problem = Kapitsa.storageProblem() { throw Kapitsa.Failure(errorDescription: problem) }
        let port = Prefs.port
        if Self.listener(port) != 0 {
            if Offload.shared.owns(port: port) {
                throw Kapitsa.Failure(errorDescription: "iPhone Offload (Experimental) is serving \(Offload.shared.saved.modelName) on port \(port). Stop it there first.")
            }
            throw Kapitsa.Failure(errorDescription: "Port \(port) is in use by another application. Free the port or change it in Settings.")
        }
        let apiId = model.name.replacingOccurrences(of: #"[^A-Za-z0-9_.-]+"#, with: "-", options: .regularExpression) + "-" + model.id.prefix(6)
        var arguments = ["serve", "--model", Kapitsa.loadPath(for: model.path), "--model-id", apiId,
                         "--port", String(port), "--context", context,
                         "--disk-cache", Prefs.diskCache]
        if let slots = Prefs.slots { arguments += ["--slots", String(slots)] }
        if !Prefs.shareOnNetwork { arguments.append("--private") }
        let key = Prefs.apiKey
        if !key.isEmpty { arguments += ["--api-key", key] }
        if Prefs.protectMemory {
            let budget = SystemMemory.safeBudgetGB(), need = SystemMemory.estimatedNeedGB(model)
            if budget < 2 { throw Kapitsa.Failure(errorDescription: "Insufficient memory: less than 2 GB available. Close other apps and try again.") }
            if need > budget {
                throw Kapitsa.Failure(errorDescription: String(format: "Not enough free memory: %@ needs about %.0f GB and %.0f GB is free now, keeping %.0f GB for other apps. Close some apps, or turn off Memory Protection in Settings › Memory.", model.name, need, budget, Prefs.memoryMargin))
            }
            arguments += ["--mem-budget", String(format: "%.1f", budget)]
        }
        if !model.drafter.isEmpty { arguments += ["--dflash", Kapitsa.loadPath(for: model.drafter)] }

        // Kapitsa writes its own log under its data folder; the app reads finished requests from it.
        let log = Kapitsa.home.appendingPathComponent("logs/serve-\(port).log")
        let existing = ((try? FileManager.default.attributesOfItem(atPath: log.path)[.size]) as? NSNumber)?.uint64Value ?? 0

        // A pseudo-terminal, so Kapitsa draws its live dashboard; the app reads the live figures from it.
        var master: Int32 = 0, slave: Int32 = 0
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Kapitsa.Failure(errorDescription: "Could not open a terminal for Kapitsa.") }
        let terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let device = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let reader = DashboardReader { [weak self] activity in
            Task { @MainActor in self?.update(activity) }
        }
        terminal.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.feed(data) }
        }
        var environment = Kapitsa.environment()
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = "120"
        environment["LINES"] = "40"
        // /usr/bin/script gives Kapitsa a terminal of its own as its controlling terminal (sized from this
        // one); without that, Kapitsa draws a one-line status instead of its full dashboard.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", binary.path] + arguments
        process.environment = environment
        process.standardInput = device
        process.standardOutput = device
        process.standardError = device
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.processEnded(finished.terminationStatus) }
        }
        stats = LogStats()
        logLines = []
        logOffset = existing
        clients.reset()
        live = LiveActivity()
        try process.run()
        try? device.close()
        self.process = process
        self.terminal = terminal
        record = ServerRecord(pid: process.processIdentifier, executable: binary.path, modelPath: model.path,
                              modelName: model.name, apiId: apiId, context: context, port: port, log: log.path,
                              logStart: existing, apiKey: key)
        save()
        phase = .starting
        trackEngine(of: process.processIdentifier)
        memoryWarning = nil
        swapAtStart = SystemMemory.swapUsedGB()
        Prefs.lastModel = model.path
        Prefs.lastContext = context
    }

    func stop() {
        guard let record, owned else { return }
        phase = .stopping
        kill(record.pid, SIGINT)
        let pid = record.pid
        Task {
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if kill(pid, 0) != 0 { return }
            }
            kill(pid, SIGTERM)
        }
    }

    /// Stops an owned server and waits briefly; used when the app quits.
    func stopAndWait() {
        guard let record, owned else { return }
        kill(record.pid, SIGINT)
        for _ in 0..<60 where kill(record.pid, 0) == 0 { usleep(100_000) }
        if kill(record.pid, 0) == 0 { kill(record.pid, SIGTERM); usleep(300_000) }
        // The main thread was blocked above, so the exit handler hasn't read the last requests: read them
        // now, or the next load starts after them and they never reach Usage.
        readLog(record.log)
        clear()
    }

    /// Signals and statistics go to Kapitsa itself, the child of the terminal wrapper.
    private func trackEngine(of wrapper: Int32) {
        Task {
            for _ in 0..<40 {
                let output = await Task.detached { (try? Kapitsa.runSync("/usr/bin/pgrep", ["-P", String(wrapper)], timeout: 2))?.output ?? "" }.value
                if let child = output.split(separator: "\n").compactMap({ Int32($0) }).first {
                    if record?.pid == wrapper { record?.pid = child; save() }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func update(_ activity: LiveActivity) {
        guard owned else { return }
        if let prompt = activity.prompt { clients.saw(client: activity.client, prompt: prompt) }
        live = activity
    }

    private func processEnded(_ code: Int32) {
        process = nil
        terminal?.readabilityHandler = nil
        try? terminal?.close()
        terminal = nil
        live = LiveActivity()
        if let log = record?.log { readLog(log) }  // pick up the final lines before reporting
        let wasStopping = phase == .stopping, neverReady = phase == .starting
        clear()
        // The terminal wrapper may exit cleanly even when Kapitsa fails, so a server that never became ready failed.
        if wasStopping || (!neverReady && [0, 2, 15, 130, 143].contains(code)) {
            phase = .stopped
        } else {
            let hint = Kapitsa.reason(in: logLines) ?? logLines.last ?? ""
            phase = .failed(hint.isEmpty ? "Kapitsa exited with code \(code)." : hint.replacingOccurrences(of: "[kapitsa] ", with: ""))
        }
    }

    private func clear() {
        record = nil
        try? FileManager.default.removeItem(at: Self.recordURL)
    }

    private func save() {
        guard var record else { return }
        record.offset = logOffset
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: Self.recordURL, options: .atomic) }
    }

    /// Re-attach to a server this app started before it was quit or crashed.
    private func adoptExisting() {
        guard let data = try? Data(contentsOf: Self.recordURL),
              let saved = try? JSONDecoder().decode(ServerRecord.self, from: data) else { return }
        let expected = URL(fileURLWithPath: saved.executable).resolvingSymlinksInPath().path
        guard kill(saved.pid, 0) == 0, Self.executable(of: saved.pid) == expected else { clear(); return }
        record = saved
        // Lines before this were already counted; reading them again would record their usage twice.
        logOffset = saved.offset
        // A record from before logStart was saved: this run's settings are near the end of what was read.
        replaySettings(saved.log, from: saved.logStart ?? (saved.offset > 8_000_000 ? saved.offset - 8_000_000 : 0), to: saved.offset)
        phase = .starting
    }

    private func refresh(tick: Int) async {
        if let record {
            readLog(record.log)
            if kill(record.pid, 0) != 0 && process == nil {
                // An adopted server has no termination handler.
                processEnded(0)
                return
            }
            if phase == .starting, await Self.healthy(record.port) { phase = .ready }
            if phase == .ready, tick % 6 == 0, !(await Self.healthy(record.port)) { phase = .starting }
            if tick % 4 == 0 {
                processLabel = await Task.detached { Self.usage(record.pid) }.value
                let (level, swap) = await Task.detached { (SystemMemory.pressure(), SystemMemory.swapUsedGB()) }.value
                memoryWarning = level >= 4 ? "Critical memory pressure. Close other apps or load a smaller model."
                    : swap - swapAtStart > 1 ? String(format: "Swap increased by %.1f GB since load. Performance may degrade.", swap - swapAtStart)
                    : level >= 2 ? "Elevated memory pressure." : nil
            }
        } else if tick % 6 == 0 {
            let port = Prefs.port
            let pid = await Task.detached { Self.listener(port) }.value
            if pid != 0 {
                externalPort = port
                if case .failed = phase {} else { phase = .external }
                processLabel = await Task.detached { Self.usage(pid) }.value
            } else if phase == .external {
                phase = .stopped
            }
        }
    }

    private func readLog(_ path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < logOffset { logOffset = 0; stats = LogStats(); logLines = [] }
        guard size > logOffset else { return }
        try? handle.seek(toOffset: logOffset)
        let data = handle.readData(ofLength: Int(min(size - logOffset, 2_000_000)))
        guard let end = data.lastIndex(of: 10) else { return }  // wait for a whole line
        logOffset += UInt64(end + 1)
        let lines = String(decoding: data[...end], as: UTF8.self).split(separator: "\n").map(String.init)
        for line in lines {
            if stats.consume(line), var last = stats.requests.popLast() {
                let client = clients.client(forPrompt: last.prompt)
                last.client = client.isEmpty ? "—" : client
                stats.requests.append(last)
                UsageStore.shared.record(prompt: last.prompt, cached: last.cached, output: last.output,
                                         model: record?.modelName ?? stats.model, client: last.client)
                measure(last)
            }
        }
        // Kapitsa's own per-token figure replaces the config-based estimate for this model from now on.
        if let kilobytes = stats.kvPerTokenKB, let path = record?.modelPath, Prefs.kvMeasured[path] != kilobytes * 1024 {
            var measured = Prefs.kvMeasured
            measured[path] = kilobytes * 1024
            Prefs.kvMeasured = measured
        }
        save()
        logLines.append(contentsOf: lines)
        if logLines.count > 800 { logLines.removeFirst(logLines.count - 800) }
    }

    /// Records the launched agent's first sizeable request as its prompt size. Only a request the dashboard
    /// showed as that agent's counts, so another app's conversation finishing meanwhile isn't taken for it.
    private func measure(_ request: RequestStat) {
        guard let (agent, since) = measuring else { return }
        guard Date().timeIntervalSince(since) < 900 else { measuring = nil; return }
        // A title or summary request is small; the agent's real first turn carries its whole prompt.
        // Kapitsa names clients from their User-Agent ("claude", "opencode", "pi", "codex…").
        guard request.prompt >= 2_000, request.client.lowercased().hasPrefix(agent.lowercased()) else { return }
        var seen = Prefs.agentPrompts
        seen[agent] = request.prompt
        Prefs.agentPrompts = seen
        measuring = nil
    }

    /// After re-attaching, the lines of this run before the saved offset were counted already, but the
    /// engine's settings (context, memory budget, drafter, prompt cache) are in them too. Read them again
    /// for those and for the request history, without recording any usage twice.
    private func replaySettings(_ path: String, from start: UInt64, to end: UInt64) {
        guard end > start, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        // The settings come first in a run; a long run's later requests aren't needed for them.
        let data = handle.readData(ofLength: Int(min(end - start, 8_000_000)))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        var replayed = LogStats()
        for line in lines {
            if replayed.consume(line), var last = replayed.requests.popLast() {
                last.client = "—"
                replayed.requests.append(last)
            }
        }
        stats = replayed
        logLines = Array(lines.suffix(800))
    }

    // MARK: - System queries

    nonisolated static func healthy(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["status"] as? String == "ok"
    }

    nonisolated static func listener(_ port: Int) -> Int32 {
        let output = (try? Kapitsa.runSync("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"], timeout: 3))?.output ?? ""
        return output.split(separator: "\n").compactMap { Int32($0) }.first ?? 0
    }

    nonisolated static func executable(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    nonisolated static func usage(_ pid: Int32) -> String {
        let output = (try? Kapitsa.runSync("/bin/ps", ["-p", String(pid), "-o", "%cpu=,rss=,comm="], timeout: 2))?.output ?? ""
        let parts = output.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let rss = Double(parts[1]) else { return "" }
        let name = URL(fileURLWithPath: String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
        return "\(name) · PID \(pid) · CPU \(parts[0])% · RAM \(String(format: "%.1f", rss / 1_048_576)) GiB"
    }

    /// Ask the running model for a short reply; records it as tested when it answers.
    func verify(_ model: LocalModel) async throws -> String {
        guard let record, phase == .ready else { throw Kapitsa.Failure(errorDescription: "The model is still loading.") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(record.port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": record.apiId, "max_tokens": 48, "temperature": 0,
            "messages": [["role": "user", "content": "Reply with exactly the word OK."]],
            "chat_template_kwargs": ["enable_thinking": false],
        ])
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Kapitsa.Failure(errorDescription: "Verification request failed.")
        }
        let message = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        let text = ((message["content"] as? String) ?? (message["reasoning_content"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = ((object["usage"] as? [String: Any])?["completion_tokens"] as? Int) ?? 0
        guard tokens > 0 || !text.isEmpty else { throw Kapitsa.Failure(errorDescription: "Verification failed: the model returned no output.") }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        Registry.record(model.path, RegistryEntry(note: "Verified on this Mac",
                                                  date: day, context: record.context, reply: String(text.prefix(80))))
        return String(format: "%.2f s", Date().timeIntervalSince(started))
    }
}
