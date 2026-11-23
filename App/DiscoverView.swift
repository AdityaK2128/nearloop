import SwiftUI

struct DiscoverView: View {
    @ObservedObject var store = AppStore.shared
    @State private var source = 0

    var body: some View {
        PageScaffold(title: "Discover", subtitle: "Models optimized for Kapitsa. Downloads include speculative-decoding companions and resume automatically.") {
            Picker("Source", selection: $source) {
                Text("Kapitsa Catalog").tag(0)
                Text("Hugging Face").tag(1)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            ActiveDownloads()
            if source == 0 { CatalogSection(store: store) } else { HuggingFaceSection() }
        }
        .task { await store.loadCatalogDetails() }
    }
}

/// The downloads under way or paused, one line each, above whichever list is shown: a download started from a
/// search is otherwise lost from view as soon as the search changes.
private struct ActiveDownloads: View {
    @ObservedObject var downloads = Downloads.shared

    private var shown: [Downloads.Job] {
        downloads.jobs.values.filter { $0.state != .finished }.sorted { $0.title < $1.title }
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloads").font(.headline)
                ForEach(shown) { job in
                    HStack(spacing: 12) {
                        Text(job.title).font(.callout).lineLimit(1).truncationMode(.middle).frame(minWidth: 120, alignment: .leading)
                        ProgressView(value: job.fraction).frame(maxWidth: .infinity)
                        Text(status(job)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                        action(job)
                    }
                }
            }.card()
        }
    }

    private func status(_ job: Downloads.Job) -> String {
        switch job.state {
        case .preparing: return "Preparing…"
        case .pausing: return "Pausing…"
        case .failed(let why): return why.isEmpty ? "Failed" : why
        default:
            let done = String(format: "%.1f", Double(job.done) / 1e9), total = String(format: "%.1f GB", Double(job.expected) / 1e9)
            return job.expected > 0 ? String(format: "%.0f%% · %@ of %@", job.fraction * 100, done, total) : "\(done) GB"
        }
    }

    @ViewBuilder private func action(_ job: Downloads.Job) -> some View {
        switch job.state {
        case .preparing, .running:
            Button("Pause") {
                downloads.pause(job.id)
                if let drafter = downloads.attachedDrafter(of: job.id) { downloads.pause(drafter) }
            }
        case .pausing:
            Button("Pausing…") {}.disabled(true)
        case .paused:
            Button("Resume") { downloads.start(job.id, title: job.title, expectedBytes: job.expected) }
        case .failed:
            Button("Retry") { downloads.start(job.id, title: job.title, expectedBytes: job.expected) }
        case .finished:
            EmptyView()
        }
    }
}

private struct CatalogSection: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.section) {
            if let error = store.catalogError {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { Task { await store.loadCatalog() } }
                }
            } else if store.catalog.isEmpty {
                ProgressView("Loading catalog…").frame(maxWidth: .infinity).padding(40)
            }
            if let pick = store.recommended, let family = store.catalog.first(where: { $0.id == pick.family }) {
                RecommendedCard(family: family, variant: pick)
            }
            if !store.catalog.isEmpty {
                // Split by Kapitsa's own description of each family, so a new catalog sorts itself.
                let coding = store.catalog.filter(Catalog.codingOriented)
                let others = store.catalog.filter { !Catalog.codingOriented($0) }
                if !coding.isEmpty {
                    familyGrid("For Coding Agents", detail: "Models Kapitsa describes for coding, agents or tool calls · sizes shown on disk", coding)
                }
                if !others.isEmpty {
                    familyGrid(coding.isEmpty ? "All Models" : "More Models", detail: "\(others.count) model families · sizes shown on disk", others)
                }
                Text("Download location: \((Kapitsa.downloads.path as NSString).abbreviatingWithTildeInPath). Change in Settings › Storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension CatalogSection {
    func familyGrid(_ title: String, detail: String, _ families: [CatalogFamily]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, detail: detail)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(families) { FamilyCard(family: $0) }
            }
        }
    }
}

private struct FamilyCard: View {
    let family: CatalogFamily
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var store = AppStore.shared
    @State private var expanded = false

    var details: Catalog.Details? { store.catalogDetails[family.id] }

    var visible: [CatalogVariant] {
        expanded ? family.variants
            : family.variants.filter { $0.isDefault || $0.forSmallerMacs || $0.downloaded || downloads.jobs[$0.id] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(family.title).font(.headline)
                if family.isMoE { Badge(text: "MoE", color: .purple) }
                ForEach(details?.speedups ?? [], id: \.self) { name in
                    Badge(text: name, color: .blue).help("Kapitsa drafts ahead with this, so replies come faster")
                }
                Spacer()
                Text(family.alias).font(.caption.monospaced()).foregroundStyle(.tertiary).help("CLI alias: \(family.alias)")
            }
            Text(family.about.prefix(1).uppercased() + family.about.dropFirst())
                .font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            if let card = details?.modelCard {
                Link("Model card ↗", destination: card).font(.caption).help(card.absoluteString)
            }
            Divider()
            VStack(spacing: 12) {
                ForEach(visible) { variant in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(variant.variant).font(.callout.monospaced())
                                    if variant.forSmallerMacs { Text("low-memory").font(.caption2).foregroundStyle(.tertiary) }
                                }
                                HStack(spacing: 10) {
                                    Text(String(format: "%.1f GB", variant.gigabytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    FitBadge(gigabytes: variant.gigabytes)
                                }
                            }
                            Spacer(minLength: 8)
                            VariantAction(variant: variant)
                        }
                        if let job = downloads.jobs[variant.id], job.showsProgress { DownloadProgressLine(job: job) }
                    }
                }
            }
            if family.variants.count > visible.count || expanded {
                Button(expanded ? "Show Less" : "Show All Variants (\(family.variants.count))") { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.link).font(.caption)
            }
        }.card()
    }
}

private struct HuggingFaceSection: View {
    @ObservedObject var store = AppStore.shared
    @State private var query = "MLX"
    @State private var results: [HuggingFace.Model] = []
    @State private var searching = false
    @State private var error = ""
    @State private var onlyCompatible = true
    @State private var sort = HuggingFace.Sort.downloads
    /// The Hub only sorts descending, so ascending turns the page it returns around: the same 50 results, smallest first.
    @State private var ascending = false

    /// The search the results belong to: a later one (a new sort chosen while a search runs) replaces an earlier one
    /// whatever order they finish in.
    @State private var latest = 0

    var shown: [HuggingFace.Model] {
        let rows = results.filter { !onlyCompatible || store.compatible($0.modelType) }
        guard sort == .size else { return ascending ? rows.reversed() : rows }
        // By the files' size once read (the estimate assumes the config's default bits, which a mixed quantization
        // does not keep); rows with no size at all go last either way.
        func size(_ model: HuggingFace.Model) -> Int64? { store.hubFiles[model.id]?.bytes ?? model.estimatedBytes }
        let sized = rows.filter { size($0) != nil }.sorted { size($0)! > size($1)! }
        return (ascending ? sized.reversed() : sized) + rows.filter { size($0) == nil }
    }

    /// Reads every result's files, a few at a time, so the size sort has the exact sizes rather than estimates.
    private func readSizes(_ models: [HuggingFace.Model]) async {
        await withTaskGroup(of: Void.self) { group in
            var queue = models[...]
            func next() { if let model = queue.popFirst() { group.addTask { _ = await HuggingFace.files(model.id) } } }
            for _ in 0..<4 { next() }
            for await _ in group { next() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search MLX models, or paste a Hugging Face link", text: $query).textFieldStyle(.plain).onSubmit(search)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                Button("Search", action: search).controlSize(.large).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 16) {
                Toggle("Kapitsa-compatible only", isOn: $onlyCompatible).toggleStyle(.checkbox)
                Picker("Sort by", selection: $sort) {
                    ForEach(HuggingFace.Sort.allCases) { Text($0.title).tag($0) }
                }.fixedSize().onChange(of: sort) { _, _ in search() }
                Picker("Order", selection: $ascending) {
                    Label("Descending", systemImage: "arrow.down").tag(false)
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                }.labelsHidden().fixedSize().help("Ascending turns the Hub's page around: the same results, smallest first.")
                Spacer()
                if !results.isEmpty { Text("\(shown.count) of \(results.count) results").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Compatible means Kapitsa can download it: a Qwen3.5-family MLX model (4- to 8-bit or BF16) from any repository, or another family the engine in use has in its Kapitsa Catalog, from the repository the catalog names, as the catalog's own build.")
                .font(.caption).foregroundStyle(.secondary)
            if searching { ProgressView().frame(maxWidth: .infinity).padding() }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            LazyVStack(spacing: 10) {
                ForEach(shown) { HuggingFaceRow(model: $0) }
            }
        }
        .task { if results.isEmpty { search() } }
    }

    func search() {
        searching = true
        error = ""
        latest += 1
        let id = latest, sort = sort
        Task {
            // A pasted model address or org/name shows that repository itself, whatever it is tagged; if there is
            // none by that name, the words are searched for.
            let repository = HuggingFace.repositoryID(query)
            do {
                var found: [HuggingFace.Model] = []
                if let repository, let model = try await HuggingFace.model(repository) { found = [model] }
                else { found = try await HuggingFace.search(repository ?? query, sort: sort) }
                guard id == latest else { return }
                results = found
                if sort == .size { Task { await readSizes(found) } }
            } catch {
                guard id == latest else { return }
                self.error = error.localizedDescription
            }
            searching = false
        }
    }
}

private struct HuggingFaceRow: View {
    let model: HuggingFace.Model
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var store = AppStore.shared
    @State private var details: HuggingFace.Details?
    @State private var checking = false
    @State private var withDrafter = true
    /// The repository's files, read when the row appears: their sizes added up (until then the listing's
    /// estimate shows, marked ~) and whether the vision tower came along.
    @State private var files: HuggingFace.Files?

    /// Where `kapitsa pull` puts this repository: a catalog repository downloads as the catalog's build, into its folder.
    var folder: URL {
        store.catalogVariant(forRepo: model.id)?.folder
            ?? Kapitsa.downloads.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "--"))
    }
    var compatible: Bool { store.compatible(model.modelType) }
    var owner: String { String(model.id.split(separator: "/").first ?? "") }
    var name: String { String(model.id.split(separator: "/").last ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                summary
                Spacer(minLength: 12)
                action.controlSize(.regular).fixedSize()
            }
            if let job = downloads.jobs[model.id], job.showsProgress { DownloadProgressLine(job: job) }
            if let drafter = details?.drafter ?? downloads.attachedDrafter(of: model.id),
               let job = downloads.jobs[drafter], job.showsProgress { DownloadProgressLine(job: job) }
        }.card(padding: 16)
        .task(id: model.id) { files = await HuggingFace.files(model.id) }
    }

    /// Verified size first, then the files' sizes, then the listing's estimate.
    /// Bits per weight as the files have them: their size over the Hub's parameter count. Nil until the files are read.
    private var effectiveBits: Double? {
        // This repository's own files: a catalog build's size (details for one) is another set of files.
        let own = details?.catalogBuild == true ? nil : (details?.bytes).flatMap { $0 > 0 ? $0 : nil }
        let bytes = own ?? files?.bytes
        guard let bytes, let total = model.safetensors?.total, total > 0 else { return nil }
        return Double(bytes) * 8 / Double(total)
    }

    private var sizeText: (text: String, gigabytes: Double)? {
        if let details, details.bytes > 0 { return (String(format: "%.1f GB", Double(details.bytes) / 1e9), Double(details.bytes) / 1e9) }
        if let files { return (String(format: "%.1f GB", Double(files.bytes) / 1e9), Double(files.bytes) / 1e9) }
        if let estimate = model.estimatedBytes { return (String(format: "~%.1f GB", Double(estimate) / 1e9), Double(estimate) / 1e9) }
        return nil
    }

    /// Bytes this download needs: the model, plus its drafter when that is included.
    private var neededBytes: Int64 {
        guard let details else { return 0 }
        return details.bytes + (withDrafter && details.drafter != nil ? details.drafterBytes : 0)
    }

    private var freeBytes: Int64 {
        var folder = Kapitsa.downloads
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 { folder.deleteLastPathComponent() }
        return (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
    }

    private var spaceProblem: String? {
        let need = neededBytes, free = freeBytes
        guard need > 0, free < need + 2_000_000_000 else { return nil }
        return String(format: "Needs %.1f GB and %.1f GB is free on the disk that holds downloads (Settings › Storage).",
                      Double(need) / 1e9, Double(free) / 1e9)
    }

    /// The two ways Kapitsa drafts tokens ahead, as pills: the model's own MTP heads (in the upload or not) and a
    /// DFlash2 drafter from the catalog, a separate small network that fits any model of this shape. With both
    /// present Kapitsa runs the drafter, which accepts more tokens per step.
    /// For a catalog build, what the catalog itself runs the model with (its companions): "MTP", "DFlash",
    /// "Prompt lookup"; empty when the engine runs that family without speculative decoding.
    private var catalogSpeedups: [String]? {
        guard details?.catalogBuild == true else { return nil }
        return store.catalogDetails.first { $0.value.repo?.caseInsensitiveCompare(model.id) == .orderedSame }?.value.speedups ?? []
    }

    @ViewBuilder private var speedups: some View {
        if let details, details.problem == nil, let used = catalogSpeedups {
            // The catalog's own build: what counts is what Kapitsa runs it with, not what the upload holds.
            HStack(spacing: 10) {
                Text("Speculative decoding").foregroundStyle(.secondary)
                ForEach(used, id: \.self) { name in
                    Badge(text: name, color: name == "MTP" ? .green : .purple, symbol: "bolt.fill")
                        .help("Downloaded with the model by Kapitsa's catalog and used when it runs.")
                }
                if used.isEmpty {
                    Badge(text: details.hasMTP ? "MTP not used" : "None", color: .secondary, symbol: "bolt.slash")
                        .help(details.hasMTP ? "The upload ships multi-token-prediction heads (mtp.safetensors), and the catalog downloads them, but Kapitsa's engine for this family does not draft with them yet: it decodes without speculative decoding."
                                             : "Kapitsa runs this family without speculative decoding: the upload has no MTP heads and the catalog adds no drafter.")
                }
            }.font(.caption)
        } else if let details, details.problem == nil {
            HStack(spacing: 10) {
                Text("Speculative decoding").foregroundStyle(.secondary)
                if let drafter = details.drafter {
                    Badge(text: "DFlash2", color: .purple, symbol: "bolt")
                        .help("\(drafter): a drafter built for a model of exactly this shape, from Kapitsa’s catalog; placed in the model’s folder as dflash2/.")
                    Toggle(isOn: $withDrafter) {
                        Text(String(format: "Add drafter (%.1f GB)", Double(details.drafterBytes) / 1e9))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(downloads.jobs[model.id]?.busy == true)
                    .help("Downloaded with the model. On a fine-tuned model fewer drafted tokens are accepted, so the gain can be smaller.")
                    if let card = URL(string: "https://huggingface.co/\(drafter)") { Link("Drafter ↗", destination: card) }
                }
                if details.hasMTP {
                    Badge(text: "MTP", color: .green, symbol: "bolt.fill")
                        .help("The upload keeps the model’s own multi-token-prediction heads; Kapitsa drafts with them when no drafter is used.")
                } else {
                    Badge(text: "No MTP", color: .secondary, symbol: "bolt.slash")
                        .help("This upload left out the model’s multi-token-prediction heads. A DFlash2 drafter does not need them.")
                }
            }.font(.caption)
        }
    }

    private func startDownload(expected: Int64) {
        downloads.start(model.id, title: model.id, expectedBytes: expected)
        if withDrafter, let drafter = details?.drafter {
            downloads.attach(drafter: drafter, to: model.id)
            downloads.start(drafter, title: "\(name) drafter", expectedBytes: details?.drafterBytes ?? 0)
        }
    }

    private var summary: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Text(owner).font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 14) {
                    if let type = model.modelType { Text(type).font(.caption.monospaced()).foregroundStyle(compatible ? .green : .secondary) }
                    if let bits = model.bits {
                        let mixed = effectiveBits.map { $0 < Double(bits) - 0.5 }
                        Text(mixed == true ? String(format: "mixed, %.1f bpw", effectiveBits!) : model.groupSize.map { "\(bits)-bit g\($0)" } ?? "\(bits)-bit")
                            .foregroundStyle(.secondary)
                            .help(mixed == true ? "The config's default is \(bits)-bit, but most layers are quantized lower: bits per weight from the files' size over the parameter count."
                                                : "Quantization from the repository's config.json")
                    }
                    if let size = sizeText {
                        Text(size.text).monospacedDigit().foregroundStyle(.secondary)
                            .help(size.text.hasPrefix("~") ? "Estimated from the Hub's parameter counts and the bits per weight; the files' sizes replace it in a moment." : "The files of the current revision, added up.")
                        FitBadge(gigabytes: size.gigabytes)
                    }
                    Label((model.downloads ?? 0).formatted(.number.notation(.compactName)), systemImage: "arrow.down").foregroundStyle(.secondary)
                    Label("\(model.likes ?? 0)", systemImage: "heart").foregroundStyle(.secondary)
                    if let updated = model.updated {
                        Text(updated.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary).help("Last updated on the Hub")
                    }
                    if let card = URL(string: "https://huggingface.co/\(model.id)") { Link("Model card ↗", destination: card) }
                }.font(.caption).labelStyle(.titleAndIcon)
                if model.handlesTools || model.handlesThinking || model.baseModel != nil || files != nil || details != nil {
                    HStack(spacing: 14) {
                        if let vision = details?.vision ?? files?.vision {
                            Label(vision ? "Vision" : "Text only", systemImage: vision ? "eye" : "text.alignleft")
                                .help(vision ? "The upload keeps the model’s vision tower (vision_config and the image preprocessor), so it is downloaded with the model and the chat can take images."
                                             : "A text-only conversion: the vision tower was left out, so images are not understood.")
                        }
                        if model.handlesTools {
                            Label("Tools", systemImage: "wrench.and.screwdriver").help("The chat template renders tool definitions and tool calls.")
                        }
                        if model.handlesThinking {
                            Label("Thinking", systemImage: "lightbulb").help("The chat template has a thinking switch or a thinking block.")
                        }
                        if let base = model.baseModel {
                            Text("from \(base)").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help("The model this one was quantized or tuned from, as the repository declares it.")
                        }
                    }.font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
                if let problem = details?.problem ?? spaceProblem { Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if details?.catalogBuild == true, details?.problem == nil {
                    Text("Downloaded as Kapitsa's catalog build of this repository: its pinned revision and files, with the companions the catalog adds.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                speedups
            }
    }

    @ViewBuilder private var action: some View {
        let job = downloads.jobs[model.id]
        let expected = details?.bytes ?? job?.expected ?? 0
        // A job's state wins over the folder: a paused download already has some files on disk.
        switch job?.state {
        case .preparing?, .running?:
            Button("Pause") {
                downloads.pause(model.id)
                if let drafter = downloads.attachedDrafter(of: model.id) { downloads.pause(drafter) }
            }
        case .pausing?:
            Button("Pausing…") {}.disabled(true)
        case .paused?:
            Button("Resume") { downloads.start(model.id, title: model.id, expectedBytes: expected) }
        case .failed?:
            Button("Retry") { downloads.start(model.id, title: model.id, expectedBytes: expected) }
        default:
            // The folder may hold an MLX model or GGUF files; either counts once the scan finds it usable.
            let usable = store.models.contains { ($0.path == folder.path || $0.path.hasPrefix(folder.path + "/")) && $0.available }
            if let drafter = downloads.attachedDrafter(of: model.id), let state = downloads.jobs[drafter]?.state,
               state != .finished, !(downloads.jobs[drafter]?.busy ?? false) {
                Button(state == .paused ? "Resume Drafter" : "Retry Drafter") {
                    downloads.startFiles(drafter, title: "\(name) drafter", expectedBytes: downloads.jobs[drafter]?.expected ?? 0)
                }
            } else if job?.state == .finished || usable {
                Label("Downloaded", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            } else if FileManager.default.fileExists(atPath: folder.path) {
                // An unfinished download from an earlier session: its job is gone, its files remain.
                Button("Resume") { downloads.start(model.id, title: model.id, expectedBytes: expected) }
                    .help("This download didn’t finish; resume it")
            } else if let details {
                Button("Download") { startDownload(expected: details.bytes) }
                    .disabled(details.problem != nil || spaceProblem != nil)
            } else {
                verifyButton
            }
        }
    }

    private var verifyButton: some View {
            Button(checking ? "Verifying…" : "Verify") {
                checking = true
                Task {
                    let drafters = Array(Set(store.catalogDetails.values.flatMap(\.drafters))).sorted()
                    // The repositories the catalog downloads from, with the size of the build it takes there.
                    var catalog: [String: Int64] = [:]
                    for (family, item) in store.catalogDetails {
                        guard let repo = item.repo else { continue }
                        let gigabytes = store.catalog.first { $0.id == family }?.defaultVariant?.gigabytes ?? 0
                        catalog[repo] = Int64(gigabytes * 1_000_000_000)
                    }
                    details = try? await HuggingFace.details(model.id, drafters: drafters, catalog: catalog, types: store.catalogTypes)
                    if details == nil { details = HuggingFace.Details(bytes: 0, problem: "Repository unavailable.") }
                    checking = false
                }
            }.disabled(checking || !compatible).help("Checks size and compatibility before downloading")
    }
}
