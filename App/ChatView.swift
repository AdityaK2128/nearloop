import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var chat = ChatStore.shared
    @AppStorage("chatHistoryShown") private var historyShown = true
    @State private var historyPopover = false

    var body: some View {
        GeometryReader { proxy in
            // Room for the history column only when the conversation keeps a comfortable width beside it.
            let docked = proxy.size.width >= 820
            HStack(spacing: 0) {
                if docked && historyShown {
                    ChatHistory(chat: chat).frame(width: 250)
                        .background(Color.primary.opacity(0.025))
                    Divider()
                }
                VStack(spacing: 0) {
                    ChatHeader(chat: chat) {
                        if docked { withAnimation(.snappy) { historyShown.toggle() } } else { historyPopover.toggle() }
                    }
                    .popover(isPresented: $historyPopover, arrowEdge: .bottom) {
                        ChatHistory(chat: chat) { historyPopover = false }.frame(width: 300, height: 460)
                    }
                    Divider().opacity(0.6)
                    ChatThread(chat: chat)
                }
            }
        }
    }
}

// MARK: - Header and history

private struct ChatHeader: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var server = ServerController.shared
    let toggleHistory: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleHistory) { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless).help("Show or Hide Chat History")
            Text(chat.selected?.title ?? "New Chat").font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(model).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 260, alignment: .trailing)
            .help(server.phase == .ready ? "The model answering this chat" : "Sending a message loads your default model")
            Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("New Chat (⇧⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16).frame(height: 44)
    }

    private var model: String {
        switch server.phase {
        case .ready: return server.record?.modelName ?? "Model"
        case .external: return "Server on port \(server.port)"
        case .starting: return "Loading \(server.record?.modelName ?? "model")…"
        default: return "No model loaded"
        }
    }

    private var dot: Color {
        switch server.phase {
        case .ready, .external: return .green
        case .starting: return .orange
        default: return .secondary.opacity(0.5)
        }
    }
}

/// Past chats, newest first, grouped by when they were last used, with a search field.
private struct ChatHistory: View {
    @ObservedObject var chat: ChatStore
    var picked: () -> Void = {}
    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search chats", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(12)
            if chat.conversations.isEmpty {
                Text("Your chats appear here. They stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 4)
                Spacer()
            } else if groups.isEmpty {
                Text("No chats match “\(query)”.").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.title) { group in
                            Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                            ForEach(group.chats) { row($0) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let renaming { chat.rename(renaming.id, to: newTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let selected = conversation.id == chat.selectedID
        return Button {
            chat.selectedID = conversation.id
            picked()
        } label: {
            HStack(spacing: 6) {
                Text(conversation.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if chat.generating == conversation.id { ProgressView().controlSize(.mini) }
            }
            .font(.callout)
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18)
                                                               : hovered == conversation.id ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? conversation.id : (hovered == conversation.id ? nil : hovered) }
        .contextMenu {
            Button("Rename…") { newTitle = conversation.title; renaming = conversation }
            Button("Delete", role: .destructive) { chat.delete(conversation.id) }
        }
    }

    private var groups: [(title: String, chats: [Conversation])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let matching = query.isEmpty ? chat.conversations : chat.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.messages.contains { $0.role == .user && $0.text.localizedCaseInsensitiveContains(query) }
        }
        func bucket(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            switch days {
            case ...0: return "Today"
            case 1: return "Yesterday"
            case 2...7: return "Previous 7 Days"
            case 8...30: return "Previous 30 Days"
            default: return "Older"
            }
        }
        var order: [String] = []
        var buckets: [String: [Conversation]] = [:]
        for conversation in matching {
            let key = bucket(conversation.updated)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(conversation)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

// MARK: - Thread

private struct ChatThread: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var server = ServerController.shared
    @ObservedObject var store = AppStore.shared

    var body: some View {
        if let conversation = chat.selected, !conversation.messages.isEmpty {
            VStack(spacing: 0) {
                messages(conversation)
                Composer(chat: chat)
            }
        } else {
            // A new chat: the greeting and the message box sit together in the middle, as in ChatGPT and Claude.
            VStack(spacing: 0) {
                Spacer()
                welcome
                Composer(chat: chat).padding(.top, 18)
                Spacer()
                Spacer()
            }
        }
    }

    private func messages(_ conversation: Conversation) -> some View {
        let shown = conversation.messages.filter { $0.role != .tool }
        let writing = chat.generating == conversation.id
        let lastAssistant = shown.last?.role == .assistant ? shown.last?.id : nil
        return FollowingScroll(growth: Self.growth(shown), restart: "\(conversation.id)-\(shown.filter { $0.role == .user }.count)", writing: writing) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(shown) { message in
                        if message.role == .user {
                            UserBubble(message: message)
                        } else {
                            AssistantReply(message: message, live: writing && message.id == shown.last?.id,
                                           isLast: !writing && message.id == lastAssistant, chat: chat, conversationID: conversation.id,
                                           sources: ChatStore.sources(for: message, in: conversation))
                        }
                    }
                    // A question left without an answer, say because the model stopped or the app quit while it wrote.
                    if !writing, shown.last?.role == .user {
                        HStack(spacing: 10) {
                            Label("No reply.", systemImage: "exclamationmark.bubble").foregroundStyle(.secondary)
                            Button("Retry") { chat.regenerate(in: conversation.id) }.disabled(chat.busy)
                        }.font(.callout)
                    }
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
    }

    static func growth(_ shown: [ChatMessage]) -> Int { ChatThreadGrowth.of(shown) }

    private var welcome: some View {
        VStack(spacing: 12) {
            Text("What can I help with?").font(.system(size: 28, weight: .semibold))
            Text(modelLine).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let launching = store.launching {
                ProgressView(launching).controlSize(.small)
            } else if !server.running, let model = store.agentModel {
                Button("Load \(model.name)") {
                    Task { try? await store.ensureServer(purpose: "Chat", context: ChatStore.context) }
                }.buttonStyle(.borderedProminent)
            } else if !server.running {
                Button("Find a Model") { store.page = .discover }
            }
        }
        .padding(.horizontal, 28).frame(maxWidth: .infinity)
    }

    private var modelLine: String {
        if server.phase == .ready, let record = server.record { return "Chatting with \(record.modelName) on this Mac. Nothing you send leaves it, except web searches." }
        if server.phase == .external { return "Chatting with the server already running on port \(server.port)." }
        if server.phase == .starting { return "Loading \(server.record?.modelName ?? "the model")…" }
        if let model = store.agentModel { return "Send a message to load \(model.name), or load it now." }
        return "Download a model from Discover to start chatting."
    }
}

struct UserBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                            if let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 120, height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.16)))
                }
            }
        }
    }
}

struct AssistantReply: View {
    let message: ChatMessage
    let live: Bool
    let isLast: Bool
    @ObservedObject var chat: ChatStore
    var conversationID: UUID?
    /// The pages behind this answer, shown under it.
    var sources: [WebSearch.Result] = []
    @State private var showThinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        if live && message.text.isEmpty && message.toolCalls.isEmpty { ProgressView().controlSize(.mini) }
                        Text(thinkingLabel).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(message.steps, id: \.callID) { StepRow(step: $0) }
            if !message.text.isEmpty {
                MarkdownText(text: message.text)
            } else if live && message.reasoning.isEmpty && message.steps.isEmpty {
                ProgressView().controlSize(.small)
            }
            if let note = message.contextNote, !live {
                Label(note, systemImage: "scissors").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if message.cutOff == true, !live {
                HStack(spacing: 10) {
                    Label("Cut off: the reply reached the end of the model’s \(ChatStore.contextTokens.map { shortTokens($0) + "-token " } ?? "")context.", systemImage: "text.badge.xmark")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if isLast { Button("Continue") { chat.continueReply(in: conversationID) }.disabled(chat.busy) }
                }
                if isLast {
                    Text("For longer replies, load the model with a larger context in Library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = message.error {
                Label(error, systemImage: error == "Stopped." ? "stop.circle" : "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(error == "Stopped." ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !live && !sources.isEmpty && !message.text.isEmpty {
                SourcesRow(sources: sources)
            }
            if !live && message.toolCalls.isEmpty && (!message.text.isEmpty || message.error != nil) {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thinkingLabel: String {
        if let seconds = message.thinkingSeconds { return seconds < 1 ? "Thought briefly" : "Thought for \(Int(seconds.rounded())) s" }
        return "Thinking…"
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if !message.text.isEmpty {
                Button { copy(message.text) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
            }
            if isLast {
                Button { chat.regenerate(in: conversationID) } label: { Image(systemName: "arrow.clockwise") }.help("Write the reply again").disabled(chat.busy)
            }
            if let tokens = message.outputTokens {
                Text("\(tokens.formatted()) tokens" + (message.tokensPerSecond.map { String(format: " · %.0f tok/s", $0) } ?? ""))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
    }
}

/// A web search or a page read, with what it found.
private struct StepRow: View {
    let step: ChatStep
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if !step.results.isEmpty || !(step.images ?? []).isEmpty { withAnimation(.snappy) { expanded.toggle() } } } label: {
                HStack(spacing: 7) {
                    if !step.done { ProgressView().controlSize(.mini) } else {
                        Image(systemName: step.error != nil ? "exclamationmark.triangle" : step.kind == .read ? "doc.text" : step.kind == .images ? "photo.on.rectangle" : "magnifyingglass")
                            .foregroundStyle(step.error != nil ? Color.orange : Color.secondary)
                    }
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if !step.results.isEmpty || !(step.images ?? []).isEmpty {
                        Text(step.kind == .images ? "\(step.images?.count ?? 0) images" : "\(step.results.count) results").foregroundStyle(.tertiary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }.buttonStyle(.plain)
            if let error = step.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.leading, 10).fixedSize(horizontal: false, vertical: true)
            }
            if expanded, let images = step.images, !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images, id: \.image) { image in
                            RemoteImage(address: image.thumbnail, link: image.page, help: "\(image.title) — \(image.host)")
                                .frame(width: 120, height: 86).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.padding(.leading, 12)
            }
            if expanded && !step.results.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.results, id: \.url) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            if let url = URL(string: result.url) {
                                Link(result.title, destination: url).font(.callout).lineLimit(1)
                            }
                            Text(result.host).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }.padding(.leading, 12)
            }
        }
    }

    private var title: String {
        switch step.kind {
        case .search: return (step.done ? "Searched " : "Searching ") + "“\(step.subject)”"
        case .read: return (step.done ? "Read " : "Reading ") + (URL(string: step.subject)?.host?.replacingOccurrences(of: "www.", with: "") ?? step.subject)
        case .images: return (step.done ? "Found images of " : "Finding images of ") + "“\(step.subject)”"
        case .other: return step.subject
        }
    }
}

/// The pages an answer is based on, numbered, under the answer.
private struct SourcesRow: View {
    let sources: [WebSearch.Result]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Array(sources.enumerated()), id: \.element.url) { index, source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            HStack(spacing: 5) {
                                Text("\(index + 1)").font(.caption2.weight(.semibold)).monospacedDigit()
                                    .frame(minWidth: 14).padding(.vertical, 1)
                                    .background(Circle().fill(Color.primary.opacity(0.1)))
                                Text(source.host).font(.caption).lineLimit(1)
                            }
                            .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(source.title + "\n" + source.url)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

/// Lays children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// A picture from the web, fetched only from public addresses (the name is resolved and every redirect
/// checked, like a page read); clicking it opens its page.
struct RemoteImage: View {
    let address: String
    var link: String?
    var help = ""
    var fit = false
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                if fit { Image(nsImage: image).resizable().scaledToFit() } else { Image(nsImage: image).resizable().scaledToFill() }
            } else if failed {
                placeholder(Image(systemName: "photo.badge.exclamationmark"))
            } else {
                placeholder(ProgressView().controlSize(.small))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let link, let page = URL(string: link) { NSWorkspace.shared.open(page) } }
        .help(help)
        .task(id: address) {
            image = nil
            failed = false
            if let data = await WebSearch.imageData(address), let loaded = NSImage(data: data) { image = loaded } else { failed = true }
        }
    }

    private func placeholder(_ content: some View) -> some View {
        ZStack { Color.primary.opacity(0.05); content.foregroundStyle(.tertiary) }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var server = ServerController.shared
    @State private var draft = ""
    @State private var images: [Data] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                        ZStack(alignment: .topTrailing) {
                            if let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.white, .black.opacity(0.6)).offset(x: 5, y: -5)
                        }
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                // Sizes the editor to its text, up to about ten lines. The editor, the placeholder and this sizer
                // share one inset (the text view's 5-point line padding, 6 points above), so the caret sits on
                // the placeholder's line.
                Text(draft.isEmpty ? " " : draft + " ").font(.body).padding(.horizontal, 5).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).opacity(0)
                if draft.isEmpty {
                    Text("Message").font(.body).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 6).allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.body).scrollContentBackground(.hidden).scrollIndicators(.never).focused($focused)
                    .padding(.vertical, 6)
                    .onKeyPress(.return, phases: .down) { press in
                        // Return sends; Shift-Return (or Option-Return) starts a new line.
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        send()
                        return .handled
                    }
            }
            .frame(minHeight: 34, maxHeight: 200).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { attach() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless).help("Attach Images")
                Button { chat.webSearch.toggle() } label: { Chip(title: "Search", symbol: "globe", on: chat.webSearch) }
                    .buttonStyle(.plain).help("Let the model search the web, read pages and find images (\(WebSearch.provider.title))")
                ThinkingMenu(chat: chat)
                Spacer()
                if chat.busy {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).help("Stop").keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                        .disabled(!canSend).help("Send (Return)")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        .frame(maxWidth: 780)
        .padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            for provider in providers { load(provider) }
            return true
        }
        .onAppear { focused = true }
        .onChange(of: chat.selectedID) { _, _ in focused = true }
    }

    private var canSend: Bool { !chat.busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) }

    private func send() {
        guard canSend else { return }
        chat.send(draft, images: images)
        draft = ""
        images = []
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images for the model to look at."
        guard panel.runModal() == .OK else { return }
        images += panel.urls.compactMap(ChatStore.jpeg(from:))
    }

    private func load(_ provider: NSItemProvider) {
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage, let data = ChatStore.jpeg(from: image) else { return }
                Task { @MainActor in images.append(data) }
            }
        } else {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = ChatStore.jpeg(from: url) else { return }
                Task { @MainActor in images.append(data) }
            }
        }
    }
}

/// A setting shown as a capsule: filled with the accent colour when on, quiet when off.
struct Chip: View {
    let title: String
    let symbol: String
    let on: Bool
    var trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title)
            if let trailing { Image(systemName: trailing).font(.system(size: 8, weight: .bold)).opacity(0.8) }
        }
        .font(.callout.weight(on ? .semibold : .regular))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(on ? Color.white : Color.secondary)
        .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(on ? Color.clear : Color.primary.opacity(0.1)))
        .contentShape(Capsule())
        .animation(.snappy(duration: 0.15), value: on)
    }
}

/// Off, Auto, Medium or High, from a menu on the Think chip.
struct ThinkingMenu: View {
    @ObservedObject var chat: ChatStore

    var body: some View {
        Menu {
            Picker("Thinking", selection: $chat.thinking) {
                ForEach(ThinkingLevel.allCases) { level in
                    Text("\(level.title) — \(level.detail)").tag(level)
                }
            }.pickerStyle(.inline)
        } label: {
            Chip(title: chat.thinking == .off ? "Think" : "Think: \(chat.thinking.title)", symbol: "brain", on: chat.thinking != .off, trailing: "chevron.down")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("How much the model reasons before answering")
    }
}

enum ChatThreadGrowth {
    /// Changes whenever the reply being written grows.
    static func of(_ shown: [ChatMessage]) -> Int {
        shown.count * 1_000_003 + (shown.last.map { $0.text.count + $0.reasoning.count + $0.steps.count * 7 + $0.steps.filter(\.done).count } ?? 0)
    }
}

/// A conversation's scroll view that follows a reply as it is written, as ChatGPT and Claude do: scrolling up
/// to read (the thinking, an earlier answer) stops following; scrolling back to the end, the ↓ button or
/// sending a new message resumes it.
struct FollowingScroll<Content: View>: View {
    /// Changes as the reply grows.
    let growth: Int
    /// Changes when following should start over: another conversation, or a new message from the user.
    let restart: String
    let writing: Bool
    @ViewBuilder var content: Content

    @State private var following = true
    @State private var viewport: CGRect = .zero
    @State private var monitor: Any?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                    // The end of the conversation; how far below the visible area it is says whether the
                    // reader is at the end.
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: EndOffset.self, value: geometry.frame(in: .named("conversation")).minY)
                        })
                }
            }
            .coordinateSpace(name: "conversation")
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { viewport = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in viewport = frame }
            })
            // Back at the end (within a line or two): follow again. Growth alone never stops following.
            .onPreferenceChange(EndOffset.self) { end in
                if !following && end <= viewport.height + 40 { following = true }
            }
            .onChange(of: growth) { _, _ in
                if following { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: restart) { _, _ in
                following = true
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
                watchScrolling()
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
            .overlay(alignment: .bottom) {
                if !following {
                    Button {
                        following = true
                        withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(.regularMaterial))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain).padding(.bottom, 12)
                    .help(writing ? "Follow the reply" : "Scroll to the end")
                    .transition(.opacity)
                }
            }
        }
    }

    /// A scroll toward the top over this view means the reader wants to read: stop following.
    private func watchScrolling() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.scrollingDeltaY > 0.5, let window = event.window, let content = window.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if viewport.contains(point) { following = false }
            return event
        }
    }
}

private struct EndOffset: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Markdown

/// A Markdown image: ![alt](url).
struct MarkdownImage: Hashable {
    let alt: String
    let url: String

    private static let pattern = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)

    /// The line without its images, and the images it had.
    nonisolated static func extract(_ line: String) -> (String, [MarkdownImage]) {
        guard line.contains("![") else { return (line, []) }
        let range = NSRange(line.startIndex..., in: line)
        let matches = pattern.matches(in: line, range: range)
        guard !matches.isEmpty else { return (line, []) }
        let images = matches.compactMap { match -> MarkdownImage? in
            guard let alt = Range(match.range(at: 1), in: line), let url = Range(match.range(at: 2), in: line) else { return nil }
            return MarkdownImage(alt: String(line[alt]), url: String(line[url]))
        }
        let rest = pattern.stringByReplacingMatches(in: line, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
        return (rest, images)
    }
}

/// Renders the Markdown models write: headings, paragraphs, lists, quotes, tables and code blocks, with
/// inline bold, italics, code and links.
struct MarkdownText: View {
    let text: String

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case item(String, marker: String, indent: Int)
        case quote(String)
        case code(String, language: String)
        case table([[String]])
        case images([MarkdownImage])
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text)).font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        case .item(let text, let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }.padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code, let language):
            CodeBlock(code: code, language: language)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell)).fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        case .images(let images):
            HStack(alignment: .top, spacing: 10) {
                ForEach(images, id: \.url) { image in
                    VStack(alignment: .leading, spacing: 4) {
                        RemoteImage(address: image.url, link: image.url, help: image.alt, fit: true)
                            .frame(maxWidth: images.count == 1 ? 520 : 260, maxHeight: images.count == 1 ? 340 : 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        if !image.alt.isEmpty {
                            Text(image.alt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        case .rule:
            Divider()
        }
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    nonisolated static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""
        var table: [[String]] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    flush()
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            // Images: on a line of their own they become a row of pictures; inside text they follow it.
            let (rest, pictures) = MarkdownImage.extract(line)
            if !pictures.isEmpty {
                if !rest.isEmpty { paragraph.append(rest) }
                flush()
                blocks.append(.images(Array(pictures.prefix(4))))
                continue
            }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| line under a table's header.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                table.append(cells)
                continue
            } else if !table.isEmpty {
                flush()
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                blocks.append(.heading(line[match].filter { $0 == "#" }.count, String(line[match.upperBound...])))
            } else if ["---", "***", "___"].contains(line) {
                flush(); blocks.append(.rule)
            } else if let match = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item(String(line[match.upperBound...]), marker: "•", indent: indent))
            } else if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item(String(line[match.upperBound...]), marker: line[match].trimmingCharacters(in: .whitespaces), indent: indent))
            } else if line.hasPrefix(">") {
                flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        // A code block still being written shows as code.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"), language: language)) }
        flush()
        return blocks
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(12).fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Settings

/// Settings › Chat: where web searches go.
struct ChatSettings: View {
    @AppStorage("searchProvider") private var provider = WebSearch.Provider.duckduckgo.rawValue
    @AppStorage("searchResults") private var results = 5
    @AppStorage("pageCharacters") private var pageCharacters = 12_000
    @AppStorage("searxngURL") private var searxng = ""
    @State private var braveKey = Keychain.read("braveSearchKey") ?? ""
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        Form {
            Picker("Web Search", selection: $provider) {
                ForEach(WebSearch.Provider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            switch WebSearch.Provider(rawValue: provider) ?? .duckduckgo {
            case .duckduckgo:
                Text("Free, with no key: DuckDuckGo first; when it refuses, Wikipedia, then the open Mwmbl index. Pictures come from DuckDuckGo or Wikimedia Commons. An engine that refuses is skipped for 30 minutes. For the steadiest results, use Brave Search (its API has a free tier) or your own SearXNG.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .brave:
                SecureField("API Key", text: $braveKey, prompt: Text("From api-dashboard.search.brave.com"))
                    .onChange(of: braveKey) { _, key in Keychain.write("braveSearchKey", key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                Text("Kept in your login keychain.").font(.caption).foregroundStyle(.secondary)
            case .searxng:
                TextField("Server Address", text: $searxng, prompt: Text("http://localhost:8888"))
                Text("A SearXNG server with the JSON format turned on in its settings.yml.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Results per Search: \(results)", value: $results, in: 1...10)
            Picker("Page Length the Model Reads", selection: $pageCharacters) {
                Text("Short (6,000 characters)").tag(6_000)
                Text("Medium (12,000 characters)").tag(12_000)
                Text("Long (24,000 characters)").tag(24_000)
            }
            HStack {
                Button(testing ? "Searching…" : "Test Search") {
                    testing = true
                    Task {
                        switch await WebSearch.search("Apple silicon") {
                        case .success(let found): testResult = found.isEmpty ? "No results came back." : "Works: \(found.count) results."
                        case .failure(let failure): testResult = failure.message
                        }
                        testing = false
                    }
                }.disabled(testing)
                Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Searches and pages are fetched by Nearloop, not the model; only the search words leave this Mac. Pages on this Mac or a private network are never read. The web search design follows oMLX’s, under the Apache License 2.0.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}
