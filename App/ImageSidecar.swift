import Foundation

/// The image sidecar: a small vision model (Gemma 3 4B on llama.cpp) that describes images for models that can't
/// read them. Chat runs it when the loaded model drops attachments, and the coding agents run the same tool,
/// `image_tool`, from a line in their global instructions. Everything lives in Application Support/Nearloop/
/// image-sidecar: the llama.cpp runner, the model and its projector, the server's log and pid.
enum ImageSidecar {
    static let modelName = "Gemma 3 4B"
    static var folder: URL { AppPaths.folder("image-sidecar") }

    /// llama.cpp's macOS arm64 release: llama-server and its libraries, pinned to one build.
    static let runnerBuild = "b12651"
    static let runnerURL = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(runnerBuild)/llama-\(runnerBuild)-bin-macos-arm64.tar.gz")!
    static let runnerBytes: Int64 = 16_644_358
    /// Google's quantization-aware Gemma 3 4B instruct, as ggml-org publishes it, with its vision projector.
    static let modelRepo = "ggml-org/gemma-3-4b-it-qat-GGUF"
    static let modelFile = "gemma-3-4b-it-qat-Q4_0.gguf"
    static let modelBytes: Int64 = 2_526_080_992
    static let projectorFile = "mmproj-model-f16-4B.gguf"
    static let projectorBytes: Int64 = 851_251_744
    static var totalBytes: Int64 { runnerBytes + modelBytes + projectorBytes }

    static var runner: URL { folder.appendingPathComponent("llama/llama-server") }
    static var model: URL { folder.appendingPathComponent(modelFile) }
    static var projector: URL { folder.appendingPathComponent(projectorFile) }

    static var downloaded: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: runner.path) && size(model) == modelBytes && size(projector) == projectorBytes
    }
    /// What is on disk now, for the Settings row.
    static var bytesOnDisk: Int64 { SystemMemory.allocatedBytes(folder) }

    static func size(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
    }

    /// On in Settings › Images and downloaded: Chat describes images the loaded model can't read.
    static var enabled: Bool { Prefs.imageSidecar && downloaded }

    // MARK: The command

    /// `image_tool`, as it ships inside the app.
    static var bundledTool: URL? { Bundle.main.url(forResource: "image_tool", withExtension: nil) }
    /// Where the agents find it: next to Nearloop's `kapitsa` command.
    static var toolURL: URL { Kapitsa.commandURL.deletingLastPathComponent().appendingPathComponent("image_tool") }

    /// "installed" (the bundle's copy), "outdated" (an earlier copy), "missing", or "foreign" (not Nearloop's file).
    static var toolState: String {
        guard let data = try? Data(contentsOf: toolURL) else { return "missing" }
        guard String(decoding: data.prefix(200), as: UTF8.self).contains("Installed by Nearloop") else { return "foreign" }
        guard let bundled = bundledTool, let ours = try? Data(contentsOf: bundled) else { return "installed" }
        return data == ours ? "installed" : "outdated"
    }

    static func installTool() throws {
        guard let bundled = bundledTool, let data = try? Data(contentsOf: bundled) else {
            throw Kapitsa.Failure(errorDescription: "This build of Nearloop has no image_tool to install.")
        }
        if toolState == "foreign" {
            throw Kapitsa.Failure(errorDescription: "\(toolURL.path) already exists and was not installed by Nearloop. Remove it first.")
        }
        try FileManager.default.createDirectory(at: toolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: toolURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }

    static func removeTool() {
        if ["installed", "outdated"].contains(toolState) { try? FileManager.default.removeItem(at: toolURL) }
    }

    // MARK: The agents' instructions

    static let marker = "<!-- nearloop-image-tool -->"
    /// The one line the agents get, ending in the marker so that exactly it comes out again.
    static let instruction = "When the user attaches or names an image file you cannot see (a screenshot, a chart, a photo, a diagram), run `image_tool <file> \"<the user's question>\" \"<what you are working on and what you need from the image>\"` and work from the description it prints; it runs a local vision model and needs no network. \(marker)"

    /// Each agent's global instruction file, as the agent itself reads it: Codex, Claude Code, OpenCode and Pi.
    static var instructionFiles: [(agent: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [("Codex CLI", home.appendingPathComponent(".codex/AGENTS.md")),
                ("Claude Code", home.appendingPathComponent(".claude/CLAUDE.md")),
                ("OpenCode", home.appendingPathComponent(".config/opencode/AGENTS.md")),
                ("Pi", home.appendingPathComponent(".pi/agent/AGENTS.md"))]
    }

    static func hasInstruction(_ url: URL) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(marker)
    }

    /// Adds the line to every file (making the file when there is none), or takes exactly that line out again,
    /// leaving everything else as it was. A file that held only the line is removed with it.
    static func setInstructions(_ on: Bool) throws {
        var problems: [String] = []
        for (agent, url) in instructionFiles {
            do {
                let fm = FileManager.default
                let existing = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
                var lines = (existing ?? "").components(separatedBy: "\n")
                let had = lines.contains { $0.contains(marker) }
                lines.removeAll { $0.contains(marker) }
                var text = lines.joined(separator: "\n")
                if on {
                    // Appended so that taking the line out again gives the file back byte for byte: after a
                    // final newline the line gets its own; after text with none, it follows on a new line and
                    // ends as the file did, without one.
                    text += text.isEmpty || text.hasSuffix("\n") ? instruction + "\n" : "\n" + instruction
                } else if !had {
                    continue
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if existing != nil { try fm.removeItem(at: url) }
                    continue
                }
                guard text != existing else { continue }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                problems.append("\(agent): \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty { throw Kapitsa.Failure(errorDescription: problems.joined(separator: " ")) }
    }

    /// Turns the sidecar on (the command installed, the agents told) or off (the line taken out; the command stays
    /// for anyone who runs it by hand, and says what to do when the model is gone).
    static func setEnabled(_ on: Bool) throws {
        if on { try installTool() }
        Prefs.imageSidecar = on
        try setInstructions(on)
    }

    // MARK: Describing

    /// Runs the tool on each image, with the question and the context; the descriptions come back in order.
    /// Off the main thread: a cold start loads the model (a few seconds), and an answer takes a few more.
    nonisolated static func describe(_ images: [Data], question: String, context: String) async throws -> [String] {
        let tool = bundledTool ?? toolURL
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw Kapitsa.Failure(errorDescription: "image_tool is not in this build of Nearloop.")
        }
        guard downloaded else {
            throw Kapitsa.Failure(errorDescription: "The image sidecar isn't downloaded. Download it in Settings › Images.")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nearloop-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var env = Kapitsa.environment()
        env["NEARLOOP_IMAGE_SIDECAR_DIR"] = folder.path
        var answers: [String] = []
        for (index, image) in images.enumerated() {
            let file = scratch.appendingPathComponent("image-\(index + 1).jpg")
            try image.write(to: file)
            let result = try await Task.detached {
                try Kapitsa.runSync(tool.path, [file.path, question, context], env: env, timeout: 600)
            }.value
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.code == 0 else {
                throw Kapitsa.Failure(errorDescription: text.replacingOccurrences(of: "image_tool: ", with: "").isEmpty ? "image_tool failed (exit \(result.code))." : text.replacingOccurrences(of: "image_tool: ", with: ""))
            }
            answers.append(text)
        }
        return answers
    }
}

/// Downloads the runner, the model and the projector with curl (resumable), one after the other, and shows the
/// progress as one job on the Settings page. Remove deletes the folder's files; the running vision server, if any,
/// is stopped first.
@MainActor
final class ImageSidecarDownload: ObservableObject {
    static let shared = ImageSidecarDownload()

    /// The one job, shaped like a model download so the same progress line draws it; nil when nothing is under way.
    @Published private(set) var job: Downloads.Job?
    /// Changes whenever files appear or go, so the Settings rows read the disk again.
    @Published private(set) var revision = 0
    private var process: Process?

    var busy: Bool { job?.busy == true }

    func start() {
        guard !busy else { return }
        job = Downloads.Job(id: "image-sidecar", title: "\(ImageSidecar.modelName) vision helper", expected: ImageSidecar.totalBytes)
        job?.folder = ImageSidecar.folder
        Task { await fetch() }
    }

    func cancel() {
        guard busy else { return }
        job?.state = .pausing
        process?.terminate()
    }

    func remove() {
        guard !busy else { return }
        ImageSidecar.stopServer()
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: ImageSidecar.folder.path)) ?? [] {
            try? fm.removeItem(at: ImageSidecar.folder.appendingPathComponent(name))
        }
        if Prefs.imageSidecar { try? ImageSidecar.setEnabled(false) }
        job = nil
        revision += 1
    }

    private func fetch() async {
        let folder = ImageSidecar.folder
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            job?.state = .running
            track()
            // 1. The model and its projector, straight from Hugging Face; a file already whole is kept.
            for (name, bytes) in [(ImageSidecar.modelFile, ImageSidecar.modelBytes), (ImageSidecar.projectorFile, ImageSidecar.projectorBytes)] {
                let target = folder.appendingPathComponent(name)
                if ImageSidecar.size(target) == bytes { continue }
                let partial = folder.appendingPathComponent(name + ".part")
                job?.lastLine = "Downloading \(name)…"
                let code = await run("/usr/bin/curl", ["-fsSL", "--retry", "3", "-C", "-", "-o", partial.path,
                                                      "https://huggingface.co/\(ImageSidecar.modelRepo)/resolve/main/\(name)"])
                if job?.state == .pausing { job?.state = .paused; return }
                guard code == 0 else { throw Kapitsa.Failure(errorDescription: "Downloading \(name) failed (curl \(code)). Retry to resume it.") }
                guard ImageSidecar.size(partial) == bytes else {
                    try? fm.removeItem(at: partial)
                    throw Kapitsa.Failure(errorDescription: "\(name) came down with the wrong size and was removed. Retry to download it again.")
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: partial, to: target)
                revision += 1
            }
            // 2. llama.cpp's release: the archive, unpacked into llama/, flat as it ships.
            if !fm.isExecutableFile(atPath: ImageSidecar.runner.path) {
                let archive = folder.appendingPathComponent("llama.tar.gz")
                job?.lastLine = "Downloading llama.cpp \(ImageSidecar.runnerBuild)…"
                let code = await run("/usr/bin/curl", ["-fsSL", "--retry", "3", "-C", "-", "-o", archive.path, ImageSidecar.runnerURL.absoluteString])
                if job?.state == .pausing { job?.state = .paused; return }
                guard code == 0 else { throw Kapitsa.Failure(errorDescription: "Downloading llama.cpp failed (curl \(code)). Retry to resume it.") }
                job?.lastLine = "Unpacking llama.cpp…"
                let llama = folder.appendingPathComponent("llama")
                try? fm.removeItem(at: llama)
                try fm.createDirectory(at: llama, withIntermediateDirectories: true)
                let unpacked = await run("/usr/bin/tar", ["-xzf", archive.path, "-C", llama.path, "--strip-components", "1"])
                guard unpacked == 0, fm.isExecutableFile(atPath: ImageSidecar.runner.path) else {
                    try? fm.removeItem(at: archive)
                    throw Kapitsa.Failure(errorDescription: "llama.cpp's archive could not be unpacked. Retry to download it again.")
                }
                _ = await run("/usr/bin/xattr", ["-cr", llama.path])
                try? ImageSidecar.runnerBuild.write(to: llama.appendingPathComponent("BUILD"), atomically: true, encoding: .utf8)
                try? fm.removeItem(at: archive)
            }
            job?.state = .finished
            job?.done = ImageSidecar.totalBytes
            revision += 1
        } catch {
            job?.state = .failed(error.localizedDescription)
            revision += 1
        }
    }

    private func run(_ executable: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                Task { @MainActor in
                    self.process = nil
                    continuation.resume(returning: finished.terminationStatus)
                }
            }
            do {
                try process.run()
                self.process = process
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    private func track() {
        Task { [weak self] in
            while let self, [.running, .pausing].contains(self.job?.state) {
                let folder = ImageSidecar.folder
                self.job?.done = await Task.detached { SystemMemory.allocatedBytes(folder) }.value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

extension ImageSidecar {
    /// Whether the vision server is up (answering on its port).
    nonisolated static func serverRunning() async -> Bool {
        await ServerController.healthy(8765)
    }

    /// Stops the vision server the tool started, if it is running.
    static func stopServer() {
        let pidFile = folder.appendingPathComponent("server.pid")
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }
}
