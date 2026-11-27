import SwiftUI

struct BenchmarksView: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var runner = BenchmarkRunner.shared
    @ObservedObject var server = ServerController.shared
    @State private var pick = ""
    @State private var sort = Sort.writing

    enum Sort: String, CaseIterable, Identifiable {
        case writing = "Generation", reading = "Prefill", memory = "Memory", name = "Name"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let id: String
        let name: String
        let writing: Double?
        let note: String?
        let reading: Double
        let firstToken: Double
        let toolsPass: Bool
        let peak: Double
        let decoding: String
        let date: Date
    }

    var rows: [Row] {
        let all = store.benchmarks.map { result in
            Row(id: result.id, name: store.model(at: result.modelPath ?? "")?.name ?? result.modelName,
                writing: result.writing, note: result.noGeneration, reading: result.reading ?? 0, firstToken: result.firstToken ?? 0,
                toolsPass: result.toolsPass, peak: result.peakGB ?? 0,
                decoding: result.usesDrafter ? "DFlash2" : result.decoding.contains("MTP") ? "MTP" : "Standard",
                date: result.date ?? .distantPast)
        }
        switch sort {
        case .writing: return all.sorted { ($0.writing ?? -1) > ($1.writing ?? -1) }
        case .reading: return all.sorted { $0.reading > $1.reading }
        case .memory: return all.sorted { $0.peak < $1.peak }
        case .name: return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        PageScaffold(title: "Benchmarks", subtitle: "Measured with Kapitsa’s benchmark protocol: generation speed, prefill speed, time to first token, tool calling and peak memory.") {
            runCard
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Results", detail: rows.isEmpty ? nil : rows.count == 1 ? "1 run" : "\(rows.count) runs") {
                    Picker("Sort by", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if rows.isEmpty {
                    ContentUnavailableView("No Benchmarks", systemImage: "gauge.with.dots.needle.33percent",
                                           description: Text("Run a benchmark to measure model performance on this Mac."))
                        .frame(maxWidth: .infinity).padding(.vertical, 30).card()
                } else {
                    // Drop the Decoding column rather than squeezing the others when the window is narrow.
                    ViewThatFits(in: .horizontal) {
                        resultsTable(compact: false)
                        resultsTable(compact: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Link("Compare with other Macs and engines in Kapitsa’s published results ↗", destination: URL(string: "https://github.com/nace-ai/kapitsa#benchmarks")!)
                    .font(.callout)
                Text((Prefs.protectMemory
                      ? "Benchmarks start only when the model fits in available memory, and stop automatically under critical memory pressure, swap activity or low free memory."
                      : "Memory Protection is off (Settings › Memory): benchmarks start whatever memory is free, and stop only under critical memory pressure.")
                     + " Results: \((BenchmarkStore.folder.path as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resultsTable(compact: Bool) -> some View {
        let fastest = max(1, rows.compactMap(\.writing).max() ?? 1)
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                Text("Model")
                Text("Generation (tok/s)").gridColumnAlignment(.trailing)
                Text("Prefill (tok/s)").gridColumnAlignment(.trailing)
                Text("TTFT").gridColumnAlignment(.trailing).help("Time to first token at a 4K-token prompt")
                Text("Tool Calling")
                Text("Peak Memory").gridColumnAlignment(.trailing)
                if !compact { Text("Decoding") }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.bottom, 10)
            ForEach(rows) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Capsule().fill(Color.accentColor.opacity(0.55))
                            .frame(width: row.writing.map { max(4, 150 * $0 / fastest) } ?? 4, height: 3)
                    }
                    // The name column takes the room the numbers leave, so names truncate only when it runs out.
                    .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                    Text(row.writing.map { String(format: "%.1f", $0) } ?? "—").fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(row.writing == nil ? .secondary : .primary).help(row.note ?? "")
                    Text(String(format: "%.0f", row.reading)).monospacedDigit()
                    Text(String(format: "%.1f s", row.firstToken)).monospacedDigit()
                    Label(row.toolsPass ? "Pass" : "Fail", systemImage: row.toolsPass ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(row.toolsPass ? .green : .secondary)
                    Text(String(format: "%.1f GB", row.peak)).monospacedDigit()
                    if !compact { Text(row.decoding).foregroundStyle(.secondary).lineLimit(1) }
                }
                .font(.callout).padding(.vertical, 10)
            }
        }.card()
    }

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model = runner.running {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Benchmarking \(model.name)…").font(.headline)
                    Spacer()
                    Button("Cancel", role: .destructive) { runner.cancel() }
                }
                Text(runner.lines.suffix(4).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        runDescription.fixedSize()
                        Spacer(minLength: 16)
                        runControls
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        runDescription
                        runControls
                    }
                }
                if let outcome = runner.outcome {
                    Label(outcome, systemImage: outcome == "Benchmark complete." ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(outcome == "Benchmark complete." ? .green : .orange)
                }
            }
        }.card()
    }

    private var runDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Benchmark").font(.headline)
            Text(server.running ? "Stop the loaded model first; a benchmark needs the memory to itself." : "Typically 3–8 minutes. Requires no model to be running.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var runControls: some View {
        HStack(spacing: 10) {
            Picker("Model", selection: $pick) {
                Text("Select Model").tag("")
                ForEach(store.runnable) { Text($0.name).tag($0.path) }
            }.labelsHidden().fixedSize()
            Button("Run") {
                if let model = store.model(at: pick) { store.runBenchmark(model) }
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(pick.isEmpty || server.running)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
