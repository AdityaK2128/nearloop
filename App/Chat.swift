import AppKit
import Foundation

/// How much the model reasons before it answers. Kapitsa switches a model's thinking on or off; the levels
/// above that are guidance in the system prompt (measured: High about twice Medium's reasoning on Ornith 9B)
/// plus reasoning_effort, which models that support it (Dory) read directly.
enum ThinkingLevel: String, CaseIterable, Identifiable {
    case off, auto, medium, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Answers straight away"
        case .auto: return "Thinks when the question needs it"
        case .medium: return "Thinks briefly first"
        case .high: return "Thinks it through and checks its work"
        }
    }

    /// Auto: think for questions that need reasoning, answer quick ones straight away.
    func thinks(about message: ChatMessage?) -> Bool {
        switch self {
        case .off: return false
        case .medium, .high: return true
        case .auto:
            guard let message else { return false }
            let text = message.text.lowercased()
            if !message.images.isEmpty || text.count > 280 || text.contains("```") { return true }
            if text.range(of: #"[0-9]\s*[-+*/^=]\s*[0-9(]"#, options: .regularExpression) != nil { return true }
            let reasoning = ["why", "how does", "how do", "how would", "how can", "explain", "compare", "difference between", "versus", " vs ",
                             "plan", "design", "solve", "prove", "calculate", "debug", "fix", "optimi", "analy", "step by step", "should i",
                             "pros and cons", "trade-off", "tradeoff", "write a", "code", "function", "algorithm", "reason", "evaluate"]
            return reasoning.contains { text.contains($0) }
        }
    }

    var effort: String? {
        switch self {
        case .medium: return "medium"
        case .high: return "high"
        default: return nil
        }
    }

    var guidance: String? {
        switch self {
        case .medium: return "Think briefly before answering: keep your reasoning short and focused, a few sentences."
        case .high: return "Think carefully and thoroughly before answering: work through the problem step by step, consider alternatives and check your work."
        default: return nil
        }
    }
}

struct ChatToolCall: Codable, Hashable {
    var id: String
    var name: String
    var arguments: String

    func argument(_ key: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])?[key] as? String
    }
}

/// What one tool call did, shown under the reply that made it.
struct ChatStep: Codable, Hashable {
    enum Kind: String, Codable { case search, read, images, other }
    let callID: String
    let kind: Kind
    let subject: String
    var results: [WebSearch.Result] = []
    /// Optional, so chats saved before image search still load.
    var images: [WebSearch.ImageResult]?
    var error: String?
    var done = false
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant, tool }
    var id = UUID()
    var role: Role
    var text = ""
    var reasoning = ""
    /// JPEG images the user attached.
    var images: [Data] = []
    var toolCalls: [ChatToolCall] = []
    var toolCallID: String?
    var steps: [ChatStep] = []
    var error: String?
    var thinkingSeconds: Double?
    var outputTokens: Int?
    var tokensPerSecond: Double?
    /// The reply stopped at the end of the model's context (finish_reason "length"). Optional, so older chats load.
    var cutOff: Bool?
    /// Set when earlier parts of the chat were shortened so the request fit the model's context.
    var contextNote: String?
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = "New Chat"
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage] = []
}

/// Conversations with the loaded model, kept in Application Support/Nearloop/Chats, one file each, and the
/// loop that streams a reply, runs the web tools it asks for and streams again until it answers.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedID: UUID?
    /// The conversation a reply is being written in.
    @Published private(set) var generating: UUID?
    /// The conversation the Quick Chat window shows; it stays in the history like any other.
    @Published var quickID: UUID?
    @Published var webSearch: Bool { didSet { Prefs.defaults.set(webSearch, forKey: "chatWebSearch") } }
    @Published var thinking: ThinkingLevel { didSet { Prefs.defaults.set(thinking.rawValue, forKey: "chatThinkingLevel") } }

    private var task: Task<Void, Never>?
    /// Tool rounds per reply; the last round offers no tools, so the model has to answer.
    private let maxRounds = 6

    private static var folder: URL { AppPaths.support.appendingPathComponent("Chats") }

    private init() {
        webSearch = Prefs.defaults.object(forKey: "chatWebSearch") as? Bool ?? true
        // The earlier on/off switch carries over: off stays off, on becomes Auto.
        thinking = ThinkingLevel(rawValue: Prefs.defaults.string(forKey: "chatThinkingLevel") ?? "")
            ?? ((Prefs.defaults.object(forKey: "chatThinking") as? Bool) == false ? .off : .auto)
        // Chats (with their images) are read off the main thread, so opening Chat or Quick Chat doesn't stall.
        let folder = Self.folder
        Task {
            let loaded = await Task.detached { () -> [Conversation] in
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                let decoder = JSONDecoder()
                return files.filter { $0.pathExtension == "json" }.compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: $0)) }
            }.value
            // Anything started before the files were read is kept.
            let current = Set(conversations.map(\.id))
            conversations = (conversations + loaded.filter { !current.contains($0.id) }).sorted { $0.updated > $1.updated }
        }
    }

    /// When the app quits mid-reply: keep what was written.
    func saveInProgress() {
        if let generating { save(generating) }
    }

    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    var busy: Bool { generating != nil }

    // MARK: Conversations

    func newChat() {
        if let current = selected, current.messages.isEmpty { return }
        selectedID = nil
    }

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = index(of: id) else { return }
        conversations[index].title = clean
        save(id)
    }

    func delete(_ id: UUID) {
        if generating == id { stop() }
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id.uuidString).json"))
        if selectedID == id { selectedID = conversations.first?.id }
    }

    private func index(of id: UUID) -> Int? { conversations.firstIndex { $0.id == id } }

    private func save(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(conversation) {
            try? data.write(to: Self.folder.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        }
    }

    // MARK: Sending

    /// From the Chat page: into the open conversation, or a new one that becomes the open one.
    func send(_ text: String, images: [Data]) {
        if let id = post(text, images: images, into: selectedID, quick: false) { selectedID = id }
    }

    /// From the Quick Chat window: into its conversation while that is recent, else a new one.
    func sendQuick(_ text: String, images: [Data] = []) {
        let recent = quickID.flatMap { id in conversations.first { $0.id == id } }.map { Date().timeIntervalSince($0.updated) < 15 * 60 } ?? false
        if let id = post(text, images: images, into: recent ? quickID : nil, quick: true) { quickID = id }
    }

    private func post(_ text: String, images: [Data], into target: UUID?, quick: Bool) -> UUID? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty || !images.isEmpty else { return nil }
        let id: UUID
        if let target, index(of: target) != nil {
            id = target
        } else {
            var conversation = Conversation()
            conversation.title = Self.title(for: text.isEmpty ? "Image" : text)
            conversations.insert(conversation, at: 0)
            id = conversation.id
        }
        guard let index = index(of: id) else { return nil }
        conversations[index].messages.append(ChatMessage(role: .user, text: text, images: images))
        conversations[index].updated = Date()
        moveToTop(id)
        save(id)
        reply(in: id, quick: quick)
        return id
    }

    /// Writes the last reply again: everything after the last message the user sent goes.
    func regenerate(in id: UUID? = nil) {
        guard !busy, let id = id ?? selectedID, let index = index(of: id),
              let last = conversations[index].messages.lastIndex(where: { $0.role == .user }) else { return }
        conversations[index].messages.removeSubrange((last + 1)...)
        reply(in: id, quick: id == quickID)
    }

    func stop() {
        task?.cancel()
    }

    private func moveToTop(_ id: UUID) {
        guard let index = index(of: id), index > 0 else { return }
        conversations.insert(conversations.remove(at: index), at: 0)
    }

    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 48 ? String(line.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// A Quick Chat uses the loaded model, else loads the one chosen for it in Settings › Quick Chat.
    private func reply(in id: UUID, quick: Bool) {
        generating = id
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.generating = nil; self.save(id) }
            do {
                try await AppStore.shared.ensureServer(purpose: quick ? "Quick Chat" : "Chat", context: Self.context,
                                                       model: quick ? AppStore.shared.quickChatModel : nil)
                try Task.checkCancellation()
            } catch is CancellationError {
                // Stopped while the model loaded; the model keeps loading for next time.
                self.append(ChatMessage(role: .assistant, error: "Stopped."), to: id)
                return
            } catch {
                self.append(ChatMessage(role: .assistant, error: error.localizedDescription), to: id)
                return
            }
            // Failed searches in a row: after two, the model answers with what it has instead of trying again.
            var failures = 0, finishedRetry = false
            for round in 0..<(self.maxRounds + 1) {
                let tools = self.webSearch && round < self.maxRounds - 1 && failures < 2 && !finishedRetry
                guard let messageID = self.append(ChatMessage(role: .assistant), to: id) else { return }
                let calls: [ChatToolCall]
                do {
                    calls = try await self.stream(id, into: messageID, tools: tools, finishing: self.webSearch && !tools, searchFailed: failures >= 2)
                } catch is CancellationError {
                    self.update(id, messageID) { if $0.text.isEmpty && $0.reasoning.isEmpty { $0.error = "Stopped." } }
                    return
                } catch let error as URLError where error.code == .cancelled {
                    self.update(id, messageID) { if $0.text.isEmpty && $0.reasoning.isEmpty { $0.error = "Stopped." } }
                    return
                } catch {
                    self.update(id, messageID) { $0.error = error.localizedDescription }
                    return
                }
                // A last round that wrote no answer (only a call as text, now hidden) gets one more try.
                if !tools, self.webSearch, !finishedRetry, let message = self.message(id, messageID), message.text.isEmpty, message.toolCalls.isEmpty {
                    finishedRetry = true
                    self.conversations[self.index(of: id)!].messages.removeAll { $0.id == messageID }
                    continue
                }
                guard tools, !calls.isEmpty else { return }
                for call in calls {
                    if Task.isCancelled { return }
                    if await self.run(call, in: id, from: messageID) { failures = 0 } else { failures += 1 }
                }
            }
        }
    }

    /// Chat suits 64K of context; a model with less gets its largest preset.
    nonisolated static func context(_ model: LocalModel) -> String {
        model.contexts.contains("64k") ? "64k" : model.largestPreset
    }

    @discardableResult
    private func append(_ message: ChatMessage, to id: UUID) -> UUID? {
        guard let index = index(of: id) else { return nil }
        conversations[index].messages.append(message)
        return message.id
    }

    private func message(_ id: UUID, _ messageID: UUID) -> ChatMessage? {
        conversations.first { $0.id == id }?.messages.first { $0.id == messageID }
    }

    private func update(_ id: UUID, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = index(of: id), let at = conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&conversations[index].messages[at])
    }

    // MARK: Tools

    /// Runs one tool call; true when it worked.
    @discardableResult
    private func run(_ call: ChatToolCall, in id: UUID, from messageID: UUID) async -> Bool {
        var worked = true
        let payload: String
        switch call.name {
        case "web_search":
            let query = call.argument("query") ?? ""
            update(id, messageID) { $0.steps.append(ChatStep(callID: call.id, kind: .search, subject: query)) }
            switch await WebSearch.search(query) {
            case .success(let results):
                payload = WebSearch.payload(results)
                step(id, messageID, call.id) { $0.results = results; $0.done = true }
            case .failure(let failure):
                payload = WebSearch.payload(failure)
                worked = false
                step(id, messageID, call.id) { $0.error = failure.message; $0.done = true }
            }
        case "image_search":
            let query = call.argument("query") ?? ""
            update(id, messageID) { $0.steps.append(ChatStep(callID: call.id, kind: .images, subject: query)) }
            switch await WebSearch.images(query) {
            case .success(let images):
                payload = WebSearch.payload(images)
                step(id, messageID, call.id) { $0.images = images; $0.done = true }
            case .failure(let failure):
                payload = WebSearch.payload(failure)
                worked = false
                step(id, messageID, call.id) { $0.error = failure.message; $0.done = true }
            }
        case "fetch_url":
            let address = call.argument("url") ?? ""
            update(id, messageID) { $0.steps.append(ChatStep(callID: call.id, kind: .read, subject: address)) }
            switch await WebSearch.fetch(address) {
            case .success(let page):
                payload = WebSearch.payload(page)
                step(id, messageID, call.id) { $0.done = true }
            case .failure(let failure):
                payload = WebSearch.payload(failure)
                worked = false
                step(id, messageID, call.id) { $0.error = failure.message; $0.done = true }
            }
        default:
            payload = WebSearch.payload(WebSearch.Failure(code: "unknown_tool", message: "There is no tool named \(call.name)."))
            update(id, messageID) { $0.steps.append(ChatStep(callID: call.id, kind: .other, subject: call.name, error: "Unknown tool", done: true)) }
        }
        var result = ChatMessage(role: .tool, text: payload)
        result.toolCallID = call.id
        append(result, to: id)
        save(id)
        return worked
    }

    private func step(_ id: UUID, _ messageID: UUID, _ callID: String, _ change: (inout ChatStep) -> Void) {
        update(id, messageID) { message in
            if let at = message.steps.firstIndex(where: { $0.callID == callID }) { change(&message.steps[at]) }
        }
    }

    // MARK: Streaming

    /// `finishing`: Search is on but this round offers no tools (the last round, or searching kept failing).
    private func systemPrompt(tools: Bool, finishing: Bool = false, searchFailed: Bool = false) -> String {
        let now = Self.today
        var prompt = "You are a helpful assistant running privately on the user’s Mac in Nearloop. It is \(now) (\(TimeZone.current.identifier)). Format answers in Markdown."
        if tools {
            prompt += """

            Web search is on. What you learned in training is out of date, and the world has changed since: news, versions, prices, people’s jobs, results, laws, products and figures may all be different now. So for any question that involves facts, search with web_search before you answer, even when you think you know; never present facts from memory as current. Answer without searching only when no facts are involved, such as writing, rewriting, math, or code the user gave you. Search with short keyword queries, search again if the results don’t settle it, and read the most relevant pages with fetch_url when snippets aren’t enough. If sources disagree, say so and prefer the most recent.

            Support every factual claim with its source: right after the claim, put a Markdown link to the page it came from, like ([Reuters](https://www.reuters.com/…)). Cite only URLs that came from your tool results, never invent one. Don’t add a separate list of sources at the end; Nearloop shows them under your answer.

            When a picture would help, such as what something looks like, a place, a product or a diagram, use image_search and put up to four of the most relevant images in your answer as Markdown images: ![short description](image_url), using image_url values exactly as image_search returned them.

            If a tool reports an error, tell the user what happened.
            """
        } else if finishing {
            prompt += searchFailed
                ? " Web search isn’t working right now (the searches above failed). Don’t try to search or call any tool: answer now from what you know and what any earlier results showed, and say clearly that you couldn’t check the web, so recent details may be out of date."
                : " You’ve searched enough: don’t search or call any tool again. Answer now with what you found, citing it, and say what you couldn’t confirm."
        } else {
            prompt += " You can’t search the web right now. When a question depends on recent facts, say that your information may be out of date and that turning on Search would let you check."
        }
        return prompt
    }

    private func requestMessages(_ conversation: Conversation, tools: Bool, thinks: Bool, finishing: Bool = false, searchFailed: Bool = false) -> [[String: Any]] {
        if finishing { return answerMessages(conversation, thinks: thinks, searchFailed: searchFailed) }  // fitted by the caller
        // A reply stopped between two tool calls has calls without results; the API needs each call answered,
        // so only the answered ones are sent.
        let answered = Set(conversation.messages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
        var system = systemPrompt(tools: tools, finishing: finishing, searchFailed: searchFailed)
        if thinks, let guidance = thinking.guidance { system += "\n\n" + guidance }
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for message in conversation.messages {
            switch message.role {
            case .user:
                if message.images.isEmpty {
                    messages.append(["role": "user", "content": message.text])
                } else {
                    var parts: [[String: Any]] = message.images.map {
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
                    }
                    if !message.text.isEmpty { parts.append(["type": "text", "text": message.text]) }
                    messages.append(["role": "user", "content": parts])
                }
            case .assistant:
                let calls = message.toolCalls.filter { answered.contains($0.id) }
                guard !message.text.isEmpty || !calls.isEmpty else { continue }
                var entry: [String: Any] = ["role": "assistant", "content": message.text]
                if !calls.isEmpty {
                    entry["tool_calls"] = calls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                    }
                }
                messages.append(entry)
            case .tool:
                messages.append(["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text])
            }
        }
        return messages
    }

    /// Streams one response from Kapitsa into the message; returns the tool calls it asked for.
    private func stream(_ id: UUID, into messageID: UUID, tools: Bool, finishing: Bool = false, searchFailed: Bool = false) async throws -> [ChatToolCall] {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return [] }
        let thinks = thinking.thinks(about: conversation.messages.last { $0.role == .user })
        // The whole request must fit the model's context with room left for the reply.
        let (fitted, shortened) = Self.fit(requestMessages(conversation, tools: tools, thinks: thinks, finishing: finishing, searchFailed: searchFailed),
                                           context: Self.contextTokens, tools: tools)
        if shortened {
            let size = Self.contextTokens.map { shortTokens($0) } ?? "its"
            update(id, messageID) { $0.contextNote = "Earlier parts of this chat were shortened to fit the model’s \(size)-token context." }
        }
        let server = ServerController.shared
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/chat/completions")!, timeoutInterval: 900)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nearloop/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        if !server.apiKey.isEmpty { request.setValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": server.record?.apiId ?? "local",
            "messages": fitted,
            "stream": true,
            "stream_options": ["include_usage": true],
            "chat_template_kwargs": ["enable_thinking": thinks],
        ]
        if thinks, let effort = thinking.effort { body["reasoning_effort"] = effort }
        if tools { body["tools"] = WebSearch.tools }
        // The last round sends no tools: its request has no tool traffic left in it (see answerMessages).
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 100_000 { break } }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? (object?["error"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Kapitsa.Failure(errorDescription: "The model couldn’t answer: \(message.isEmpty ? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)" : message)")
        }

        let started = Date()
        var firstText: Date?, firstToken: Date?
        var finishReason: String?
        var text = "", reasoning = "", outputTokens: Int?
        var calls: [Int: ChatToolCall] = [:]
        var lastPush = Date.distantPast, lastSave = Date()
        func push(final: Bool) {
            guard final || Date().timeIntervalSince(lastPush) > 0.06 else { return }
            lastPush = Date()
            let (t, r) = (Self.withoutWrittenToolCalls(text), reasoning)
            update(id, messageID) { $0.text = t; $0.reasoning = r }
            // Every few seconds to disk, so a reply cut off by quitting or a crash keeps what was written.
            if Date().timeIntervalSince(lastSave) > 3 { lastSave = Date(); save(id) }
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let usage = object["usage"] as? [String: Any] { outputTokens = usage["completion_tokens"] as? Int }
            if let error = object["error"] as? [String: Any] {
                throw Kapitsa.Failure(errorDescription: error["message"] as? String ?? "The model stopped with an error.")
            }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty { finishReason = reason }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let piece = delta["reasoning_content"] as? String, !piece.isEmpty {
                if firstToken == nil { firstToken = Date() }
                reasoning += piece
            }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                if firstText == nil { firstText = Date() }
                if firstToken == nil { firstToken = Date() }
                text += piece
            }
            for item in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = item["index"] as? Int ?? calls.count
                var call = calls[index] ?? ChatToolCall(id: "", name: "", arguments: "")
                if let callID = item["id"] as? String, !callID.isEmpty { call.id = callID }
                if let function = item["function"] as? [String: Any] {
                    if let name = function["name"] as? String { call.name += name }
                    if let arguments = function["arguments"] as? String { call.arguments += arguments }
                }
                calls[index] = call
            }
            push(final: false)
        }
        push(final: true)
        let ordered = calls.keys.sorted().compactMap { calls[$0] }.map { call -> ChatToolCall in
            var call = call
            if call.id.isEmpty { call.id = "call_\(UUID().uuidString.prefix(12))" }
            return call
        }
        let ended = Date()
        update(id, messageID) { message in
            message.toolCalls = ordered
            if finishReason == "length" { message.cutOff = true }
            if ordered.isEmpty && message.text.isEmpty && message.error == nil {
                message.error = searchFailed ? "Web search isn’t working right now and the model didn’t write an answer. Try again, or turn Search off."
                                             : "The model didn’t write an answer. Try again."
            }
            if !message.reasoning.isEmpty { message.thinkingSeconds = (firstText ?? ended).timeIntervalSince(started) }
            if let outputTokens, outputTokens > 1 {
                message.outputTokens = outputTokens
                // Writing speed: from the first token, so reading the prompt doesn't count against it.
                let writing = ended.timeIntervalSince(firstToken ?? started)
                if writing > 0.2 { message.tokensPerSecond = Double(outputTokens - 1) / writing }
            }
        }
        return ordered
    }

    /// The final answer's request: the conversation in plain questions and answers, and this turn's tool
    /// results handed over as text with the question. After rounds of tool use a model tends to keep
    /// writing tool calls (Clover wrote one even with tool_choice "none"); with no tool markup left in what
    /// it reads, it answers.
    private func answerMessages(_ conversation: Conversation, thinks: Bool, searchFailed: Bool) -> [[String: Any]] {
        var system = "You are a helpful assistant running privately on the user’s Mac in Nearloop. It is \(Self.today) (\(TimeZone.current.identifier)). Format answers in Markdown."
        if thinks, let guidance = thinking.guidance { system += "\n\n" + guidance }
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        let lastUser = conversation.messages.lastIndex { $0.role == .user } ?? conversation.messages.count
        // Earlier turns: what the user asked and what was answered, without the tool traffic.
        for message in conversation.messages[..<lastUser] {
            if message.role == .user {
                messages.append(["role": "user", "content": message.text.isEmpty ? "(an image)" : message.text])
            } else if message.role == .assistant, message.toolCalls.isEmpty, !message.text.isEmpty {
                messages.append(["role": "assistant", "content": message.text])
            }
        }
        // This turn's findings, from the tools' payloads.
        // Page text in proportion to the context: about a third of it, at most 24,000 characters.
        var lines: [String] = [], images: [String] = [], pageBudget = min(24_000, (Self.contextTokens ?? 72_000) * 6 / 5)
        for message in conversation.messages[lastUser...] where message.role == .tool {
            guard let payload = try? JSONSerialization.jsonObject(with: Data(message.text.utf8)) as? [String: Any], payload["ok"] as? Bool == true else { continue }
            for result in (payload["results"] as? [[String: Any]]) ?? [] {
                lines.append("- \(result["title"] as? String ?? "") (\(result["url"] as? String ?? "")): \(result["snippet"] as? String ?? "")")
            }
            if let content = payload["content"] as? String, let url = payload["url"] as? String, pageBudget > 0 {
                let excerpt = String(content.prefix(min(6_000, pageBudget)))
                pageBudget -= excerpt.count
                lines.append("\nPage \(url):\n\(excerpt)")
            }
            for image in ((payload["images"] as? [[String: Any]]) ?? []).prefix(6) {
                images.append("- \(image["title"] as? String ?? "") — image_url: \(image["image_url"] as? String ?? "") (page: \(image["page_url"] as? String ?? ""))")
            }
        }
        let question = conversation.messages.indices.contains(lastUser) ? conversation.messages[lastUser] : nil
        var ask = question?.text ?? ""
        if lines.isEmpty && images.isEmpty {
            ask += searchFailed
                ? "\n\n(Web search wasn’t working just now, so nothing could be checked online. Answer from what you know, and say clearly that recent details may be out of date.)"
                : "\n\n(Answer from what you know, and say what you couldn’t check online.)"
        } else {
            ask += "\n\nHere is what web searches and the pages read returned:\n\n" + lines.joined(separator: "\n")
            if !images.isEmpty { ask += "\n\nPictures found:\n" + images.joined(separator: "\n") }
            ask += "\n\nUsing this, answer the question above now. Cite each fact right after it with a Markdown link to its page, using only the URLs above. Don’t add a separate list of sources at the end. "
            if !images.isEmpty { ask += "If pictures help, include up to four as Markdown images: ![short description](image_url), with image_url exactly as listed. " }
            ask += "Say what these sources didn’t settle."
        }
        if let question, !question.images.isEmpty {
            var parts: [[String: Any]] = question.images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]] }
            parts.append(["type": "text", "text": ask])
            messages.append(["role": "user", "content": parts])
        } else {
            messages.append(["role": "user", "content": ask])
        }
        return messages
    }

    /// A model offered no tools sometimes writes a tool call as text (<tool_call>…</tool_call>, finished or
    /// not); that is never shown as an answer.
    nonisolated static func withoutWrittenToolCalls(_ text: String) -> String {
        guard text.contains("<tool_call") || text.contains("<function=") else { return text }
        return text.replacingOccurrences(of: #"(?s)<tool_call>.*?(</tool_call>|$)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<function=[^>]*>.*?(</function>|$)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The date for the system prompt, without the time: Kapitsa reuses a conversation's cached prompt only
    /// while its beginning is unchanged, and a clock to the minute at the top rewrote it every minute, so each
    /// message made the model read the whole conversation again. The date changes once a day.
    static var today: String { Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }

    // MARK: Fitting the context

    /// The context one conversation can use on the running server: Kapitsa's own figure for a server this app
    /// loaded (what fits in memory, at most the context it was loaded with); nil for a server it didn't load.
    static var contextTokens: Int? {
        let server = ServerController.shared
        guard server.owned else { return nil }
        if let effective = server.stats.effectiveContext { return effective }
        guard let record = server.record else { return nil }
        return AppStore.shared.model(at: record.modelPath)?.contextTokens(record.context)
    }

    /// A rough token count: about 3.3 characters a token for English and code, an attached image about 1,300.
    nonisolated static func estimate(_ message: [String: Any]) -> Int {
        var characters = 0, images = 0
        if let text = message["content"] as? String { characters += text.count }
        for part in (message["content"] as? [[String: Any]]) ?? [] {
            if let text = part["text"] as? String { characters += text.count } else { images += 1 }
        }
        for call in (message["tool_calls"] as? [[String: Any]]) ?? [] {
            characters += ((call["function"] as? [String: Any])?["arguments"] as? String)?.count ?? 0
        }
        return characters * 10 / 33 + images * 1_300 + 8
    }

    /// Fits a request into `context` tokens, keeping room for the reply: first the search results and page
    /// text of earlier turns are shortened, then this turn's page text, then the oldest turns are left out.
    /// The system prompt and the latest question always stay. Returns the messages and whether any were cut.
    nonisolated static func fit(_ messages: [[String: Any]], context: Int?, tools: Bool) -> ([[String: Any]], Bool) {
        guard let context, messages.count > 1 else { return (messages, false) }
        let reserve = min(8_192, max(2_048, context / 4)), toolDefinitions = tools ? 700 : 0
        let budget = context - reserve - toolDefinitions
        var messages = messages
        var total: Int { messages.reduce(0) { $0 + estimate($1) } }
        guard total > budget else { return (messages, false) }
        let lastUser = messages.lastIndex { $0["role"] as? String == "user" } ?? messages.count - 1
        func shorten(_ index: Int, to characters: Int, label: String) {
            guard let text = messages[index]["content"] as? String, text.count > characters + 80 else { return }
            messages[index]["content"] = "[\(label), shortened to fit the context] " + text.prefix(characters) + " …"
        }
        // 1. Earlier turns' tool results (search results, page text): keep a short excerpt.
        for index in messages.indices where index < lastUser && messages[index]["role"] as? String == "tool" {
            shorten(index, to: 400, label: "Earlier tool result")
            if total <= budget { return (messages, true) }
        }
        // 2. This turn's tool results, the longest first, down to a few thousand characters each.
        let current = messages.indices.filter { $0 > lastUser && messages[$0]["role"] as? String == "tool" }
            .sorted { ((messages[$0]["content"] as? String)?.count ?? 0) > ((messages[$1]["content"] as? String)?.count ?? 0) }
        for limit in [6_000, 3_000, 1_200] {
            for index in current { shorten(index, to: limit, label: "Tool result"); if total <= budget { return (messages, true) } }
        }
        // 3. The oldest turns, a whole turn at a time so a tool call never loses its result.
        while total > budget {
            guard let start = messages.indices.first(where: { $0 > 0 && $0 < lastUserIndex(messages) }) else { break }
            let end = messages.indices.first { $0 > start && messages[$0]["role"] as? String == "user" } ?? messages.count
            guard end <= lastUserIndex(messages) else { break }
            messages.removeSubrange(start..<end)
        }
        return (messages, true)
    }

    nonisolated private static func lastUserIndex(_ messages: [[String: Any]]) -> Int {
        messages.lastIndex { $0["role"] as? String == "user" } ?? messages.count - 1
    }

    /// Picks up a reply that stopped at the end of the context.
    func continueReply(in id: UUID?) {
        guard !busy, let id = id ?? selectedID else { return }
        if let index = index(of: id) {
            conversations[index].messages.append(ChatMessage(role: .user, text: "Continue from where you stopped."))
            conversations[index].updated = Date()
        }
        reply(in: id, quick: id == quickID)
    }

    // MARK: Sources

    /// The pages behind a final answer, from the searches and reads that led to it (since the user's
    /// message): the ones the answer links to first, then pages read, then the top search results.
    static func sources(for message: ChatMessage, in conversation: Conversation) -> [WebSearch.Result] {
        guard message.role == .assistant, message.toolCalls.isEmpty, let end = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return [] }
        let start = (conversation.messages[..<end].lastIndex { $0.role == .user } ?? -1) + 1
        let steps = conversation.messages[start...end].flatMap(\.steps)
        guard !steps.isEmpty else { return [] }
        let found = steps.flatMap(\.results)
        let read = steps.filter { $0.kind == .read && $0.error == nil }.map { step in
            found.first { $0.url == step.subject } ?? WebSearch.Result(title: URL(string: step.subject)?.host ?? step.subject, url: step.subject, snippet: "")
        }
        func key(_ url: String) -> String { url.lowercased().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "www.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let text = message.text.lowercased()
        let cited = (read + found).filter { text.contains(key($0.url)) }
        var picked: [WebSearch.Result] = []
        for result in cited + read + found.prefix(3) where !picked.contains(where: { key($0.url) == key(result.url) }) {
            picked.append(result)
        }
        return Array(picked.prefix(8))
    }

    // MARK: Images

    /// An image file as a JPEG no larger than 1600 pixels on its long side.
    nonisolated static func jpeg(from url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return jpeg(from: image)
    }

    nonisolated static func jpeg(from image: NSImage) -> Data? {
        guard let rep = image.representations.first else { return nil }
        let width = CGFloat(rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width))
        let height = CGFloat(rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height))
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, 1600 / max(width, height))
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
