import AppKit
import Combine
import SwiftUI

/// "44.6K" for 44,573 tokens, "900" below a thousand; context sizes (multiples of 1,024) as "8K", "128K".
func shortTokens(_ count: Int) -> String {
    if count >= 1024, count % 1024 == 0 { return "\(count / 1024)K" }
    return count >= 1000 ? String(format: "%.1fK", Double(count) / 1000).replacingOccurrences(of: ".0K", with: "K") : "\(count)"
}

/// Spacing and widths shared by every page, so the layout reads as one system.
enum Metrics {
    static let column: CGFloat = 960
    static let gutter: CGFloat = 40
    static let section: CGFloat = 32
    static let cardPadding: CGFloat = 20
}

extension View {
    func card(padding: CGFloat = Metrics.cardPadding) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// A scrolling page: one centered column with room on both sides.
struct PageScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.section) {
                PageHeader(title: title, subtitle: subtitle)
                content
            }
            .frame(maxWidth: Metrics.column, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 28)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary)
                .frame(maxWidth: 620, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium)).foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// A quiet dot-and-word fit indicator; the full sentence is in the tooltip.
struct FitBadge: View {
    let gigabytes: Double
    var body: some View {
        let label = Kapitsa.fitLabel(gigabytes: gigabytes)
        let color: Color = label.hasPrefix("Fits") ? .green : label.hasPrefix("Tight") ? .orange : .red
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label.hasPrefix("Fits") ? "Fits" : label.hasPrefix("Tight") ? "Tight Fit" : "Too Large")
                .font(.caption).foregroundStyle(.secondary)
        }
        .help(label + String(format: " (%.0f GB memory)", SystemMemory.totalGB))
    }
}

struct AgentIcon: View {
    let agent: AgentInfo
    var active = true
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: agent.symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill((active ? Color.accentColor : Color.secondary).opacity(0.13)))
    }
}

struct StatusDot: View {
    @ObservedObject var server: ServerController
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    var color: Color {
        switch server.phase {
        case .ready, .external: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .secondary.opacity(0.5)
        }
    }
}

struct Tile: View {
    let title: String, value: String?, detail: String
    init(_ title: String, _ value: String?, _ detail: String) { self.title = title; self.value = value; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CopyRow: View {
    let label: String
    let value: String?
    var placeholder = "Not loaded"
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            if let value {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            } else {
                Text(placeholder).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { if let value { AppStore.shared.copy(value, "\(label) copied.") } } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy \(label)").disabled(value == nil)
        }
    }
}

struct LiveStats: View {
    @ObservedObject var server: ServerController

    var body: some View {
        let stats = server.stats
        let last = stats.requests.last
        VStack(alignment: .leading, spacing: 18) {
            if let warning = server.memoryWarning {
                Label(warning, systemImage: "memorychip").font(.callout).foregroundStyle(.orange)
            }
            if server.phase == .starting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(stats.lastLine.replacingOccurrences(of: "[kapitsa] ", with: "")).font(.caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                LiveStrip(live: server.live)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
                Tile("Last Response", last.map { String(format: "%.1f", $0.tokensPerSecond) }, "tok/s writing")
                Tile("Prompt Reading", last?.promptSpeed.map { String(format: "%.0f", $0) }, "tok/s · uncached tokens")
                Tile("Prompt Cache", last.map { String(format: "%.0f%%", $0.cachePercent) }, last.map { "\($0.cached.formatted()) of \($0.prompt.formatted()) tokens" } ?? "reused tokens")
                Tile("Context Usage", last.flatMap { r in stats.effectiveContext.map { String(format: "%.1f%%", Double(r.prompt) / Double($0) * 100) } },
                     stats.effectiveContext.map { "of \($0.formatted()) usable tokens" } ?? "of context")
                Tile("Average Writing", stats.meanSpeed.map { String(format: "%.1f", $0) }, "tok/s · \(stats.requests.count) responses")
                Tile("Tokens Written", stats.outputTokens > 0 ? stats.outputTokens.formatted() : nil, "this session")
                Tile("Draft Step", last?.draftYield.map { String(format: "%.2f", $0) }, stats.drafter.isEmpty ? "tokens per step" : stats.drafter)
                Tile("Memory", server.live.memory ?? (stats.allocated.isEmpty ? nil : stats.allocated),
                     server.live.memory == nil ? (stats.budget.isEmpty ? "allocated" : "of \(stats.budget) budget") : "used by Kapitsa")
            }
            if !stats.requests.isEmpty { RequestsTable(requests: Array(stats.requests.suffix(6).reversed())) }
            Text(server.processLabel.isEmpty ? "Live figures come from Kapitsa’s dashboard; the table lists finished requests."
                 : server.processLabel + "  ·  Live figures come from Kapitsa’s dashboard; the table lists finished requests.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// The request in progress, as Kapitsa's dashboard shows it.
private struct LiveStrip: View {
    let live: LiveActivity

    var title: String {
        switch live.state {
        case .writing: return "Writing"
        case .reading: return "Reading Prompt"
        case .waiting: return "Waiting for the Engine"
        case .idle: return "Idle"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            HStack(spacing: 8) {
                Circle().fill(live.state == .idle ? Color.secondary.opacity(0.5) : .green).frame(width: 8, height: 8)
                Text(title).font(.headline)
            }.frame(width: 190, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(live.speed.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text("tok/s").foregroundStyle(.secondary)
            }.frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if live.state == .idle {
                    Text("No request in progress").foregroundStyle(.secondary)
                } else {
                    Text([live.tokens.map { "\($0.formatted()) tokens" }, live.elapsed.map { String(format: "%.1fs", $0) }]
                        .compactMap { $0 }.joined(separator: "  ·  ")).monospacedDigit()
                    Text([live.client.isEmpty ? nil : live.client, live.prompt.map { "\($0.formatted()) prompt" },
                          live.cachedPercent.map { "\($0)% cached" }].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .animation(.snappy, value: live.speed)
    }
}

/// Finished requests, with the columns of Kapitsa's Requests table.
private struct RequestsTable: View {
    let requests: [RequestStat]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requests").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Time", "Client", "Prompt", "Cache", "First", "Read/s", "Out", "Tok/s", "Step", "Finish"], id: \.self) {
                        Text($0).foregroundStyle(.secondary)
                    }
                }
                ForEach(requests) { r in
                    GridRow {
                        Text(r.time.formatted(date: .omitted, time: .standard)).gridColumnAlignment(.leading)
                        Text(r.client).lineLimit(1).gridColumnAlignment(.leading)
                        Text(r.prompt.formatted())
                        Text(String(format: "%.0f%%", r.cachePercent))
                        Text(r.prefillMs.map { $0 >= 1000 ? String(format: "%.1fs", $0 / 1000) : String(format: "%.0fms", $0) } ?? "—")
                        Text(r.promptSpeed.map { String(format: "%.0f", $0) } ?? "—")
                        Text(r.output.formatted())
                        Text(String(format: "%.1f", r.tokensPerSecond)).fontWeight(.semibold)
                        Text(r.draftYield.map { String(format: "%.2f", $0) } ?? "—")
                        Text(r.finish).gridColumnAlignment(.leading)
                    }
                }
            }.font(.caption.monospacedDigit())
        }
    }
}

struct MemoryGauge: View {
    @State private var free = SystemMemory.availableGB()
    @State private var pressure = SystemMemory.pressure()
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        let total = SystemMemory.totalGB
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Memory", systemImage: "memorychip").font(.headline)
                Spacer()
                Text(pressure >= 4 ? "Critical" : pressure >= 2 ? "Elevated" : "Normal")
                    .font(.caption.weight(.medium)).foregroundStyle(pressure >= 4 ? .red : pressure >= 2 ? .orange : .green)
            }
            ProgressView(value: max(0, min(1, (total - free) / total)))
                .tint(pressure >= 4 ? .red : pressure >= 2 ? .orange : .accentColor)
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f GB", free)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(String(format: "available of %.0f GB", total)).foregroundStyle(.secondary)
            }
            Text(Prefs.protectMemory
                 ? String(format: "Models can use up to %.0f GB right now, with %.0f GB reserved for other apps.", max(0, SystemMemory.safeBudgetGB()), Prefs.memoryMargin)
                 : "Memory protection is off. Large models may cause swapping.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(timer) { _ in
            free = SystemMemory.availableGB()
            pressure = SystemMemory.pressure()
        }
    }
}

/// The button for one catalog variant: Download, Pause, Resume, Retry, or Load once it is on disk.
/// Progress is shown separately, under the row, by `DownloadProgressLine`, so the two never compete for space.
struct VariantAction: View {
    let variant: CatalogVariant
    var prominent = false
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var store = AppStore.shared

    var body: some View {
        let job = downloads.jobs[variant.id]
        Group {
            switch job?.state {
            case .preparing?, .running?:
                Button("Pause") { downloads.pause(variant.id) }
            case .pausing?:
                Button("Pausing…") {}.disabled(true)
            case .paused?:
                action("Resume", symbol: "arrow.clockwise.circle.fill")
            case .failed?:
                action("Retry", symbol: "arrow.clockwise.circle.fill")
            default:
                // Download jobs live only in memory; after a restart an unfinished folder is found by the scan.
                if let model = store.localModel(for: variant), model.loadable {
                    HStack(spacing: 8) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                            .help("Downloaded")
                        Button(store.server.record?.modelPath == model.path ? "Loaded" : "Load") {
                            store.load(model, context: model.contexts.contains("64k") ? "64k" : nil)
                        }.disabled(store.server.running)
                    }
                } else if store.localModel(for: variant) != nil {
                    action("Resume", symbol: "arrow.clockwise.circle.fill").help("This download didn’t finish; resume it")
                } else {
                    action("Download", symbol: "arrow.down.circle.fill")
                }
            }
        }
        .controlSize(prominent ? .large : .small)
        .fixedSize()
    }

    @ViewBuilder private func action(_ title: String, symbol: String) -> some View {
        if prominent {
            Button { start() } label: { Label(title, systemImage: symbol) }.buttonStyle(.borderedProminent)
        } else {
            Button(title) { start() }
        }
    }

    private func start() { downloads.start(variant.id, title: variant.id, expectedBytes: variant.bytes) }
}

/// A full-width progress line for a download that has started, paused or failed.
struct DownloadProgressLine: View {
    let job: Downloads.Job

    var caption: String {
        let done = ByteCountFormatter.string(fromByteCount: job.done, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: job.expected, countStyle: .file)
        let percent = String(format: "%.0f%%", job.fraction * 100)
        switch job.state {
        case .preparing: return job.done > 0 ? "Resuming at \(percent)…" : "Preparing download…"
        case .running: return job.expected > 0 ? "\(percent)  ·  \(done) of \(total)" : done
        case .pausing: return "Pausing at \(percent)…"
        case .paused: return "Paused at \(percent)  ·  resumes where it stopped"
        case .failed(let reason): return reason
        case .finished: return "Downloaded"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Without a known total a filled fraction would be wrong, so the bar only shows activity.
            if (job.state == .preparing && job.done == 0) || (job.state == .running && job.expected <= 0) {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: job.fraction).tint(job.state == .running ? .accentColor : .secondary)
            }
            Text(caption).font(.caption).monospacedDigit().lineLimit(2)
                .foregroundStyle({ if case .failed = job.state { return Color.orange } else { return Color.secondary } }())
        }
    }
}

struct LogSheet: View {
    @ObservedObject var server = ServerController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Server Log").font(.title2.weight(.semibold))
                Spacer()
                if let log = server.record?.log { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)]) } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(server.logLines.isEmpty ? "No log output." : server.logLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.background(Color(nsColor: .textBackgroundColor))
        }.padding(22).frame(width: 880, height: 540)
    }
}

struct ImportSheet: View {
    let model: LocalModel
    @StateObject private var conversion = StreamingCommand()
    @Environment(\.dismiss) private var dismiss
    @State private var preview = ""
    @State private var ok = false

    var name: String {
        let stem = URL(fileURLWithPath: model.path).deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "import-" + stem.prefix(70) + "-" + model.id.prefix(6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert GGUF Model").font(.title2.weight(.semibold))
            Text("Output: \((Kapitsa.downloads.appendingPathComponent(name).path as NSString).abbreviatingWithTildeInPath). The original file remains unchanged.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(conversion.lines.isEmpty ? (preview.isEmpty ? "Validating format…" : preview) : conversion.lines.suffix(40).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.background(Color(nsColor: .textBackgroundColor))
            HStack {
                Button("Close") { conversion.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if conversion.running { ProgressView().controlSize(.small) }
                Button("Convert") { convert() }.buttonStyle(.borderedProminent).disabled(!ok || conversion.running || conversion.exitCode == 0)
            }
        }
        .padding(22).frame(width: 720, height: 460)
        .task {
            if FileManager.default.fileExists(atPath: Kapitsa.downloads.appendingPathComponent(name).path) {
                preview = "Already converted. Available under Downloaded in Library."
                return
            }
            do {
                let result = try await Kapitsa.run(["import", model.path, "--name", name, "--dry-run"], timeout: 120)
                preview = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                ok = result.code == 0
                if !ok { preview = "This file can’t be converted.\n\n" + preview }
            } catch { preview = error.localizedDescription }
        }
    }

    func convert() {
        let target = Kapitsa.downloads.appendingPathComponent(name).path, source = model.path
        AppStore.shared.converting.insert(source)
        do {
            try conversion.start(["import", source, "--name", name]) { code in
                Task {
                    AppStore.shared.converting.remove(source)
                    await AppStore.shared.scan()
                    if code == 0 { AppStore.shared.selectedModelID = ModelScanner.identity(target) }
                }
            }
        } catch {
            AppStore.shared.converting.remove(source)
            preview = error.localizedDescription
        }
    }
}

/// A short, collapsible explanation at the top of a page, for people new to it. Open the first time;
/// collapsing it is remembered, and the header row stays so it can be opened again.
struct HowItWorks<Footer: View>: View {
    struct Step: Identifiable {
        let symbol: String
        let title: String
        let text: String
        var id: String { title }
    }

    let title: String
    let steps: [Step]
    @ViewBuilder var footer: Footer
    @AppStorage private var collapsed: Bool

    init(_ title: String, key: String, steps: [Step], @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.steps = steps
        self.footer = footer()
        _collapsed = AppStorage(wrappedValue: false, "howItWorks.\(key).collapsed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() } } label: {
                HStack {
                    Label(title, systemImage: "questionmark.circle").font(.headline)
                    Spacer()
                    Text(collapsed ? "Show" : "Hide").font(.callout).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").rotationEffect(.degrees(collapsed ? -90 : 0)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !collapsed {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: step.symbol).foregroundStyle(Color.accentColor)
                                    .frame(width: 28, height: 28).background(Circle().fill(Color.accentColor.opacity(0.12)))
                                Text("\(index + 1). \(step.title)").font(.callout.weight(.semibold))
                            }
                            Text(step.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                footer
            }
        }.card()
    }
}

extension HowItWorks where Footer == EmptyView {
    init(_ title: String, key: String, steps: [Step]) { self.init(title, key: key, steps: steps) { EmptyView() } }
}
