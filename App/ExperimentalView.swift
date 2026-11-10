import AppKit
import SwiftUI

/// Experimental › iPhone Offload: set up, run and measure prefill shared with an iPhone.
struct ExperimentalView: View {
    @ObservedObject var offload = Offload.shared
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @State private var showReplies = false
    @State private var showLog = false

    var body: some View {
        PageScaffold(title: "iPhone Offload",
                     subtitle: "Experimental. Your iPhone runs the last layers of the model while your Mac runs the first, so long prompts are read faster. Replies are still written by the Mac.") {
            HowItWorks("How It Works", key: "offload", steps: [
                .init(symbol: "cable.connector", title: "Connect",
                      text: "Plug the iPhone in with a USB‑C cable, unlock it, and open the Tail Worker app once."),
                .init(symbol: "square.stack.3d.up", title: "Pick a Model",
                      text: "Any MLX model in your Library whose layers the iPhone worker can run. Nearloop checks it for you."),
                .init(symbol: "scissors", title: "Start",
                      text: "Nearloop asks the iPhone how much it can hold, copies it that share of the layers, and starts the engine."),
                .init(symbol: "bolt.horizontal", title: "Use It",
                      text: "Chat and Coding Agents use it like any loaded model. Prompts over the threshold are split between the Mac and the iPhone."),
            ])
            devicesCard
            modelCard
            if offload.running || offload.state == .starting { liveCard }
            benchmarkCard
            if !offload.phoneFiles.isEmpty { phoneStorageCard }
            logCard
        }
        .onAppear {
            if !offload.checkedOnce { offload.refresh() }
            offload.inspectAll()
        }
        .onChange(of: store.models.count) { _, _ in offload.inspectAll() }
        .onChange(of: offload.modelPath) { _, _ in
            if let model = offload.model { offload.inspect(model) }
        }
    }

    // MARK: - Devices

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Devices", detail: "What the iPhone offload needs on this Mac and on the phone") {
                Button {
                    offload.refresh()
                } label: {
                    if offload.checking { ProgressView().controlSize(.small) } else { Label("Check Again", systemImage: "arrow.clockwise") }
                }.disabled(offload.checking || offload.busy)
            }
            VStack(spacing: 0) {
                requirement("Engine", ok: offload.engine != nil,
                            value: offload.engine.map { "oMLX \($0.version)" },
                            missing: "oMLX not installed",
                            help: "Nearloop runs your installed oMLX with the iPhone hook added in memory. oMLX itself isn’t modified.")
                Divider()
                requirement("iPhone", ok: offload.phone != nil,
                            value: offload.phone.map { "\($0.model) · \($0.name) · \($0.transport == "wired" ? "USB" : "Wi‑Fi")" },
                            missing: offload.toolsProblem != nil ? "Xcode needed" : "Not connected",
                            help: "Found with Xcode’s devicectl. A cable is much faster than Wi‑Fi.")
                Divider()
                requirement("Tail Worker App", ok: offload.worker != nil,
                            value: offload.worker.map { "\($0.name) \($0.version)" },
                            missing: offload.phone == nil ? "—" : "Not installed",
                            help: "getFaster’s iOS app, which runs the model’s last layers on the iPhone’s GPU.")
                Divider()
                requirement("USB Network Link", ok: offload.usbAddress != nil,
                            value: offload.usbAddress.map { address in
                                offload.linkSpeed.map { String(format: "Up · %.0f MB/s", $0) } ?? "Up · \(address.split(separator: "%").last.map(String.init) ?? "")"
                            },
                            missing: "Not up",
                            help: "The iPhone and the Mac talk over the network link a USB cable creates. It comes up when the phone is unlocked and trusts this Mac.")
            }
            if let blocker = offload.blocker, offload.checkedOnce, !offload.checking {
                Label(blocker, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.card()
    }

    private func requirement(_ title: String, ok: Bool, value: String?, missing: String, help: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : (offload.checkedOnce ? "xmark.circle" : "circle.dotted"))
                .foregroundStyle(ok ? .green : .secondary)
            Text(title).frame(width: 150, alignment: .leading)
            Text(ok ? (value ?? "") : (offload.checkedOnce ? missing : "Checking…"))
                .foregroundStyle(ok ? .primary : .secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .font(.callout).padding(.vertical, 8).help(help)
    }

    // MARK: - Model

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Model", detail: "Decode stays on the Mac, so the Mac still holds the whole model")
            if offload.candidates.isEmpty {
                Text(store.models.isEmpty ? "No models in your Library. Add a model folder in Library, or connect the drive that holds your models."
                     : "None of your Library models are MLX folders, which oMLX needs.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Picker("Model", selection: Binding(get: { offload.model?.path ?? "" }, set: { offload.modelPath = $0 })) {
                        ForEach(offload.candidates) { model in
                            let known = offload.inspections[model.path]
                            Text(model.name + (known.map { $0.supported ? "" : " — can’t be split" } ?? "")).tag(model.path)
                        }
                    }.labelsHidden().frame(maxWidth: 360).disabled(offload.busy || offload.running)
                    if let model = offload.model { Text(model.sizeLabel).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                }
                inspectionLine
                if let model = offload.model, let inspection = offload.inspections[model.path], inspection.supported {
                    layersRow(model, inspection)
                }
            }
            Divider()
            startRow
        }.card()
    }

    @ViewBuilder private var inspectionLine: some View {
        if let model = offload.model {
            if offload.inspecting == model.path {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking whether the iPhone can run this model’s layers…") }
                    .font(.callout).foregroundStyle(.secondary)
            } else if let inspection = offload.inspections[model.path] {
                if inspection.supported {
                    Label("\(inspection.numLayers) layers · \(inspection.modelType) · the iPhone worker can run them", systemImage: "checkmark.seal")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Label("Can’t be split: " + inspection.reasons.joined(separator: "; "), systemImage: "xmark.octagon")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else if offload.engine != nil {
                Button("Check This Model") { offload.inspect(model) }.disabled(offload.inspecting != nil)
            }
        }
    }

    private func layersRow(_ model: LocalModel, _ inspection: Offload.Inspection) -> some View {
        let planned = offload.plannedLayers(for: model) ?? 1
        let limit = min(offload.fit(for: model) ?? inspection.numLayers - 1, inspection.numLayers - 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Layers on the iPhone").frame(width: 150, alignment: .leading)
                Picker("", selection: Binding(get: { offload.layerChoice == 0 ? 0 : 1 },
                                              set: { offload.layerChoice = $0 == 0 ? 0 : planned })) {
                    Text("Auto").tag(0)
                    Text("Custom").tag(1)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(offload.busy || offload.running)
                if offload.layerChoice > 0 {
                    Stepper(value: Binding(get: { max(1, min(offload.layerChoice, limit)) }, set: { offload.layerChoice = $0 }),
                            in: 1...max(1, limit)) { EmptyView() }.labelsHidden().disabled(offload.busy || offload.running)
                }
                Text("\(planned) of \(inspection.numLayers) · \(Offload.gigabytes(inspection.tailBytes(planned))) on the iPhone")
                    .monospacedDigit()
                Spacer()
            }.font(.callout)
            if offload.layerChoice == 0, let why = offload.autoExplanation {
                Text(why).font(.caption).foregroundStyle(.secondary).padding(.leading, 162)
            } else if offload.fit(for: model) != nil {
                Text("The iPhone can hold up to \(limit) layers of this model.").font(.caption).foregroundStyle(.secondary).padding(.leading, 162)
            }
        }
    }

    @ViewBuilder private var startRow: some View {
        HStack(spacing: 12) {
            if offload.running {
                Label("Running \(offload.saved.modelName) on port \(String(offload.saved.port))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                Spacer()
                Button("Open Chat") { store.page = .chat }
                Button("Stop", role: .destructive) { offload.stop() }.disabled(offload.benchmarking != nil)
            } else if offload.busy, offload.benchmarking == nil {
                ProgressView().controlSize(.small)
                Text(offload.activity ?? "Working…").font(.callout).lineLimit(2)
                Spacer()
                Button("Cancel") { offload.stop() }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if server.owned, let name = server.record?.modelName {
                        Text("Starting stops \(name), which Kapitsa is serving now.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Serves on port \(String(Prefs.port)) like a loaded model. The first start for a model takes a few minutes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if case .failed(let message) = offload.state {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Start with iPhone") { offload.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(offload.blocker != nil || offload.model == nil || server.phase == .external
                              || offload.model.flatMap { offload.inspections[$0.path] }.map { !$0.supported } == true)
            }
        }
        if server.phase == .external && !offload.running && !offload.busy {
            Text("Another server is using port \(String(server.externalPort)). Stop it first.").font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: - Live

    private var liveCard: some View {
        let status = offload.status
        let start = offload.saved.numLayers - offload.saved.tailLayers
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Live", detail: "Updated as prompts arrive")
            HStack(alignment: .top, spacing: 16) {
                Tile("Split", "\(start) + \(offload.saved.tailLayers)",
                     "Mac layers 0–\(max(0, start - 1)) · iPhone \(start)–\(max(0, offload.saved.numLayers - 1))")
                Tile("iPhone", phoneStateTitle(status), status.device ?? phoneStateDetail(status))
                Tile("Prompts Helped", "\(status.completed)", "\(shortTokens(status.tokens)) tokens · \(status.fallbacks) fell back")
                Tile("Last Prompt", lastRunValue(status), lastRunDetail(status))
            }
            if status.state == "running", status.activeTokens > 0 {
                ProgressView(value: Double(status.activeProcessed), total: Double(status.activeTokens)) {
                    Text("Reading a \(shortTokens(status.activeTokens))-token prompt with the iPhone…").font(.callout)
                }
            }
            if !status.hookApplied, !status.hookDetail.isEmpty, offload.state == .running {
                Label(status.hookDetail, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Divider()
            HStack(spacing: 14) {
                Toggle("Use the iPhone for prompts longer than", isOn: $offload.usePhone).toggleStyle(.switch)
                Picker("", selection: $offload.minTokens) {
                    ForEach([1024, 2048, 4096, 8192, 16384], id: \.self) { Text("\(shortTokens($0)) tokens").tag($0) }
                }.labelsHidden().fixedSize().disabled(!offload.usePhone)
                Spacer()
            }.font(.callout)
            if let reason = status.lastFallback ?? status.lastSkip, offload.usePhone {
                Text("Last time the Mac read a prompt alone: \(reason)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.card()
    }

    private func phoneStateTitle(_ status: Offload.Status) -> String {
        switch status.state {
        case "running": return "Working"
        case "ready": return "Ready"
        case "unavailable": return "Unavailable"
        case "disabled": return "Off"
        case "unsupported": return "Unsupported"
        default: return "Waiting"
        }
    }

    private func phoneStateDetail(_ status: Offload.Status) -> String {
        status.detail.isEmpty ? "Connects on the first long prompt" : status.detail
    }

    private func lastRunValue(_ status: Offload.Status) -> String? {
        guard let run = status.lastRun, let rate = run["tokens_per_second"] as? Double else { return nil }
        return String(format: "%.0f tok/s", rate)
    }

    private func lastRunDetail(_ status: Offload.Status) -> String {
        guard let run = status.lastRun else { return "No long prompt yet" }
        return String(format: "%@ tokens in %.1f s", shortTokens(run["tokens"] as? Int ?? 0), run["seconds"] as? Double ?? 0)
    }

    // MARK: - Benchmark

    private var benchmarkCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Benchmark", detail: "Reads the same long prompt twice, new to the cache each time: by the Mac alone, then with the iPhone") {
                HStack(spacing: 10) {
                    Picker("Prompt", selection: $offload.benchTokens) {
                        ForEach([4096, 8192, 16384], id: \.self) { Text("\(shortTokens($0)) tokens").tag($0) }
                    }.labelsHidden().fixedSize().disabled(offload.benchmarking != nil)
                    if offload.benchmarking != nil {
                        Button("Cancel") { offload.cancelBenchmark() }
                    } else {
                        Button("Run Benchmark") { offload.runBenchmark() }
                            .buttonStyle(.borderedProminent).disabled(!offload.running)
                    }
                }
            }
            if let step = offload.benchmarking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step).font(.callout) }
            } else if !offload.running && offload.benchRuns.isEmpty {
                Text("Start the engine with the iPhone first. A run takes about a minute for a mid-size model at 8K tokens.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !offload.benchRuns.isEmpty { benchmarkTable }
            if let verdict = offload.benchVerdict {
                let good = verdict.contains("faster")
                Label(verdict, systemImage: good ? "bolt.fill" : "info.circle")
                    .font(.callout.weight(good ? .semibold : .regular)).foregroundStyle(good ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offload.benchRuns.contains(where: { !$0.reply.isEmpty }) {
                DisclosureGroup("Replies", isExpanded: $showReplies) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(offload.benchRuns) { run in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.label).font(.caption.weight(.semibold))
                                Text(run.reply.isEmpty ? "(no text)" : run.reply).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Text("Both should be sensible answers about the notes; the iPhone changes speed, not the result.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }.padding(.top, 6)
                }.font(.callout)
            }
        }.card()
    }

    private var benchmarkTable: some View {
        let slowest = max(0.001, offload.benchRuns.map(\.firstToken).max() ?? 1)
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                Text("Run")
                Text("Prompt").gridColumnAlignment(.trailing)
                Text("Time to First Token").gridColumnAlignment(.trailing)
                Text("Prefill").gridColumnAlignment(.trailing)
                Text("Generation").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(offload.benchRuns) { run in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.label).font(.callout.weight(.medium))
                        Capsule().fill(run.usedPhone ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: max(4, 180 * run.firstToken / slowest), height: 4)
                        if let note = run.note { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                    Text(shortTokens(run.promptTokens)).monospacedDigit()
                    Text(String(format: "%.1f s", run.firstToken)).fontWeight(.semibold).monospacedDigit()
                    Text(String(format: "%.0f tok/s", run.prefill)).monospacedDigit()
                    Text(run.generation.map { String(format: "%.1f tok/s", $0) } ?? "—").monospacedDigit()
                }.font(.callout).padding(.vertical, 10)
            }
        }
    }

    // MARK: - Phone storage

    private var phoneStorageCard: some View {
        let total = offload.phoneFiles.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "On the iPhone", detail: "Layer files in the Tail Worker app · \(Offload.gigabytes(total))")
            ForEach(offload.phoneFiles) { file in
                HStack {
                    Image(systemName: file.name == Offload.shardName ? "iphone" : "doc").foregroundStyle(.secondary).frame(width: 18)
                    Text(file.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    if file.name == Offload.shardName { Badge(text: "Nearloop", color: .accentColor) }
                    Spacer()
                    Text(Offload.gigabytes(file.size)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("Nearloop keeps one file on the phone and replaces it when you switch models. Remove older files in Finder › your iPhone › Files › Tail Worker.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.card()
    }

    // MARK: - Log

    private var logCard: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(offload.log.isEmpty ? "Nothing yet." : offload.log.joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 160)
                HStack {
                    Button("Open Engine Log") { NSWorkspace.shared.open(Offload.logURL) }
                        .disabled(!FileManager.default.fileExists(atPath: Offload.logURL.path))
                    Button("Show Files in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Offload.folder]) }
                }
            }.padding(.top, 8)
        } label: {
            Text("Activity").font(.headline)
        }.card()
    }
}
