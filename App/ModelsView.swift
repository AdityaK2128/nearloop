import SwiftUI

struct ModelsView: View {
    @ObservedObject var store = AppStore.shared
    @State private var query = ""
    @State private var showAll = false

    var visible: [LocalModel] {
        store.models.filter { (showAll || $0.available) && (query.isEmpty || ($0.name + $0.folder + $0.architecture).localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                    Picker("Show", selection: $showAll) {
                        Text("Compatible").tag(false)
                        Text("All Files").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                }.padding(12)
                List(selection: $store.selectedModelID) {
                    ForEach(store.allLibraries, id: \.self) { library in
                        let rows = visible.filter { $0.library == library }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { ModelRow(model: $0, store: store).tag($0.id) }
                            } header: {
                                Text(store.libraryTitle(library)).help(library).contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: library)) }
                                    if library != store.downloadsPath { Button("Remove from Library") { store.removeLibrary(library) } }
                                }
                            }
                        }
                    }
                    if visible.isEmpty && !store.scanning {
                        Text(store.models.isEmpty ? "No models. Add a folder or download from Discover." : "No compatible models. Select All Files for details.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Divider()
                HStack(spacing: 12) {
                    Button { store.addLibrary() } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                    Spacer()
                    if store.scanning { ProgressView().controlSize(.small) }
                    Button { Task { await store.scan() } } label: { Image(systemName: "arrow.clockwise") }.help("Rescan")
                }.buttonStyle(.borderless).padding(12)
            }.frame(width: 300).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollView {
                if let model = store.selected {
                    ModelDetail(model: model, store: store, server: ServerController.shared)
                        .frame(maxWidth: 780, alignment: .leading)
                        .padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 44)
                        .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView("No Model Selected", systemImage: "square.stack.3d.up", description: Text("Select a model, add a folder, or download from Discover."))
                        .padding(.top, 80)
                }
            }.frame(maxWidth: .infinity)
        }
    }
}

private struct ModelRow: View {
    let model: LocalModel
    @ObservedObject var store: AppStore

    var tint: Color {
        switch model.status {
        case .verified: return .green
        case .candidate: return .accentColor
        case .importable: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(model.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if store.server.record?.modelPath == model.path { Image(systemName: "bolt.fill").foregroundStyle(.green).font(.caption) }
            }
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(model.statusLabel).foregroundStyle(.secondary)
                if let result = store.benchmark(for: model), let speed = result.writing {
                    Text(String(format: "· %.0f tok/s", speed)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(model.sizeLabel).monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(.vertical, 3)
    }
}

private struct ModelDetail: View {
    let model: LocalModel
    @ObservedObject var store: AppStore
    @ObservedObject var server: ServerController
    @ObservedObject var bench = BenchmarkRunner.shared
    @State private var confirmDelete = false

    var isLoaded: Bool { server.record?.modelPath == model.path }
    var relocating: Bool { store.relocations[model.path] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.name).font(.system(size: 26, weight: .bold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Badge(text: model.statusLabel, color: model.verified ? .green : model.loadable ? .accentColor : .secondary,
                          symbol: model.verified ? "checkmark.seal.fill" : nil)
                    Badge(text: model.format + " · " + model.architecture)
                    if !model.drafter.isEmpty { Badge(text: "DFlash2", color: .purple, symbol: "bolt") }
                    if isLoaded { Badge(text: "Loaded", color: .green, symbol: "bolt.fill") }
                }
                Text(model.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.loadable { loadCard; performanceCard }
            else if model.status == .importable { convertCard }
            infoCard
        }
        .sheet(item: $store.importTarget) { ImportSheet(model: $0) }
        .confirmationDialog("Move \(model.name) to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { store.trash(model) }
        } message: { Text(model.library == store.downloadsPath ? "You can restore it from the Trash or download it again from Discover." : "You can restore it from the Trash.") }
    }

    private var loadCard: some View {
        let tokens = model.contextTokens(store.context)
        let need = tokens.flatMap { SystemMemory.estimatedNeedGB(model, tokens: $0) } ?? SystemMemory.estimatedNeedGB(model)
        let fit = SystemMemory.fit(needGB: need)
        let warns = fit == .tight || (fit == .reclaims && Prefs.protectMemory)
        return VStack(alignment: .leading, spacing: 14) {
            // The action sits beside the title and the context control on its own row, so neither is
            // squeezed at narrow window widths.
            HStack {
                Text("Run").font(.headline)
                Spacer()
                if isLoaded {
                    Button("Stop", role: .destructive) { server.stop() }.controlSize(.large)
                } else {
                    Button { store.load(model) } label: { Label("Load Model", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(server.running || relocating || bench.running != nil)
                        .help(bench.running != nil ? "A benchmark is running" : "")
                }
            }
            HStack(spacing: 14) {
                Text("Context").foregroundStyle(.secondary)
                Picker("Context", selection: $store.context) {
                    ForEach(model.contexts, id: \.self) { Text(model.contextLabel($0).replacingOccurrences(of: " (Max)", with: "")).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(server.running)
                .help("Tokens per conversation. Larger contexts use more memory.")
                Spacer(minLength: 0)
            }
            // A small context suits a short chat, not an agent: Claude Code alone sends about 20K tokens before
            // anything is typed. Suggest the size agents need when the model has it and it fits in memory.
            if let selected = model.contextTokens(store.context), selected < 65_536 {
                let suggestion = model.contexts.contains("128k") ? "128k" : model.contexts.contains("64k") ? "64k" : nil
                let fits = suggestion.flatMap { model.contextTokens($0) }.flatMap { tokens in
                    SystemMemory.estimatedNeedGB(model, tokens: tokens).map { SystemMemory.fit(needGB: $0) != .tight } } ?? true
                if let suggestion, fits {
                    HStack(spacing: 8) {
                        Label("Coding agents need 64K or more, and Claude Code works best at 128K; on \(model.contextLabel(store.context)) their replies get cut off within a few steps.",
                              systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Use \(model.contextLabel(suggestion).replacingOccurrences(of: " (Max)", with: ""))") { store.context = suggestion }
                            .controlSize(.small).disabled(server.running)
                    }
                }
            }
            Label(String(format: "Estimated memory%@: %.1f GB of %.0f GB",
                         tokens != nil && SystemMemory.kvBytesPerToken(model) != nil ? " at " + model.contextLabel(store.context).replacingOccurrences(of: " (Max)", with: "") : "",
                         need, SystemMemory.totalGB) + {
                switch fit {
                case .comfortable: return ""
                case .reclaims: return Prefs.protectMemory ? "  ·  More than is free now: close apps, or turn off Memory Protection in Settings"
                                                           : "  ·  macOS will compress idle app memory to make room"
                case .tight: return "  ·  May not fit on this Mac"
                }
            }(), systemImage: warns ? "exclamationmark.triangle" : "memorychip")
                .font(.caption).foregroundStyle(warns ? .orange : .secondary)
            contextEstimates
            if isLoaded, let usable = server.stats.usableContext {
                let limited = usable < (server.stats.context ?? usable)
                Label("Usable context: \(usable.formatted()) tokens" +
                      (server.stats.kvPerTokenKB.map { " (\($0) KB of memory per token)" } ?? "") +
                      (limited ? ". The memory budget limits it below the context chosen; close other apps or relax memory protection in Settings for more." : "."),
                      systemImage: limited ? "info.circle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if server.running && !isLoaded {
                Text("Another model is running. Stop it to load this one.").font(.caption).foregroundStyle(.secondary)
            }
            if isLoaded && server.phase == .ready && !model.verified {
                Button("Verify Model") { Task { await store.verify(model) } }
            }
        }.card()
    }

    /// The estimate for every context option, so the cost of a larger one is visible before loading.
    @ViewBuilder private var contextEstimates: some View {
        if let kv = SystemMemory.kvBytesPerToken(model) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    ForEach(model.contexts, id: \.self) { context in
                        if let tokens = model.contextTokens(context), let need = SystemMemory.estimatedNeedGB(model, tokens: tokens) {
                            let fit = SystemMemory.fit(needGB: need)
                            Text(model.contextLabel(context).replacingOccurrences(of: " (Max)", with: "") + String(format: "  %.1f GB", need))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(fit == .tight ? Color.red : fit == .reclaims && Prefs.protectMemory ? Color.orange : Color.secondary)
                                .fontWeight(context == store.context ? .semibold : .regular)
                        }
                    }
                }
                let selected = model.contextTokens(store.context) ?? 0
                let fits = SystemMemory.tokensThatFit(model)
                Text("\(kv.bytes / 1024) KB of memory per token of context, " + (kv.measured ? "measured when this model last loaded." : "estimated from the model’s configuration until it loads.") +
                     (fits.map { $0 < selected ? " About \(shortTokens($0)) tokens fit in the memory free now; Kapitsa limits the context to that." : "" } ?? ""))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var performanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Performance").font(.headline)
                Spacer()
                if bench.running?.path == model.path {
                    ProgressView().controlSize(.small)
                    Button("View Progress") { store.page = .benchmarks }
                } else {
                    Button("Run Benchmark") { store.runBenchmark(model) }.disabled(bench.running != nil || server.running)
                        .help(server.running ? "Stop the running model to benchmark" : "Takes 3–8 minutes. Stops automatically if memory runs low.")
                }
            }
            if let result = store.benchmark(for: model) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Tile("Generation", result.writing.map { String(format: "%.1f", $0) }, "tok/s")
                    Tile("Prefill", result.reading.map { String(format: "%.0f", $0) }, "tok/s · 4K prompt")
                    Tile("Time to First Token", result.firstToken.map { String(format: "%.1f s", $0) }, "4K prompt")
                    Tile("Tool Calling", result.toolsPass ? "Pass" : "Fail", result.toolsPass ? "Agent-ready" : "Not agent-ready")
                }
                Text("Peak memory \(result.peakGB.map { String(format: "%.1f GB", $0) } ?? "—") · \(result.decoding)" +
                     (result.repetition ? " · Repetition detected" : "") + (result.contention ? " · GPU contention during run" : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No benchmark yet. Measures generation speed, prefill speed, time to first token, tool calling and peak memory.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.card()
    }

    private var convertCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Convert to Kapitsa Format").font(.headline)
            Text("Creates a new model folder. The original file remains unchanged, and a preview validates the format first.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Convert…") { store.importTarget = model }.disabled(server.running)
        }.card()
    }

    private var infoCard: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
            GridRow { Text("Size").foregroundStyle(.secondary); Text(model.sizeLabel).monospacedDigit() }
            if let native = model.nativeContext { GridRow { Text("Context Length").foregroundStyle(.secondary); Text("\(native.formatted()) tokens") } }
            if !model.drafter.isEmpty { GridRow { Text("Drafter").foregroundStyle(.secondary); Text(URL(fileURLWithPath: model.drafter).lastPathComponent) } }
            GridRow { Text("Location").foregroundStyle(.secondary); Text((model.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(3) }
            GridRow {
                Text("")
                VStack(alignment: .leading, spacing: 10) {
                    if let fraction = store.relocations[model.path] {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: fraction)
                            Text(String(format: "Moving…  %.0f%%", fraction * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }.frame(maxWidth: 360)
                    }
                    HStack(spacing: 10) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)]) }
                        let busy = store.busyReason(model)
                        Button("Move To…") { store.relocate(model) }
                            .disabled(busy != nil)
                            .help(busy ?? "Move this model to another folder or drive; it stays in your library")
                        Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                            .disabled(busy != nil).help(busy ?? "")
                    }
                }
            }
        }.font(.callout).card()
    }
}
