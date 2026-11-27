import CryptoKit
import Foundation

/// The image sidecar: a small vision model (Gemma 3 4B on llama.cpp) that describes images for models that can't
/// read them. Chat runs it when the loaded model drops attachments, and the coding agents run the same tool,
/// `image_tool`, from a line in their global instructions. Everything lives in Application Support/Nearloop/
/// image-sidecar: the llama.cpp runner, the model and its projector, the server's log and pid.
enum ImageSidecar {
    static let modelName = "Gemma 3 4B"
    static var folder: URL { AppPaths.folder("image-sidecar") }

    // Everything the sidecar downloads, in one place: the build, the files, their sizes and the SHA-256 each must
    // match (the archive's as GitHub's release lists it, the models' as Hugging Face's LFS records them). A file
    // runs only once it matched; the record of that is a .sha256 file beside it (llama/SHA256 for the runner).

    /// llama.cpp's macOS arm64 release: llama-server and its libraries, pinned to one build.
    static let runnerBuild = "b12651"
    static let runnerURL = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(runnerBuild)/llama-\(runnerBuild)-bin-macos-arm64.tar.gz")!
    static let runnerBytes: Int64 = 16_644_358
    static let runnerSHA256 = "264fd872de61679c45ad57e1e21c2a2a54e29b35734ecf3d50f24166447ab8d2"
    /// Google's quantization-aware Gemma 3 4B instruct, as ggml-org publishes it, with its vision projector, at the
    /// repository commit the hashes below belong to (a later re-upload would otherwise fail the check until a new build).
    static let modelRepo = "ggml-org/gemma-3-4b-it-qat-GGUF"
    static let modelRevision = "bbcac0d065076c47042838c0675c602411b0dd4c"
    static let modelFile = "gemma-3-4b-it-qat-Q4_0.gguf"
    static let modelBytes: Int64 = 2_526_080_992
    static let modelSHA256 = "ee91c3e7a4ab95d8c95672f9fcb58bf236b257e9f217966bcf53a5a6df4ab49a"
    static let projectorFile = "mmproj-model-f16-4B.gguf"
    static let projectorBytes: Int64 = 851_251_744
    static let projectorSHA256 = "c5271cab492e27cd123f808e9115a677b2ecfdb21c8152c1ad45cc455f3b592b"
    static var totalBytes: Int64 { runnerBytes + modelBytes + projectorBytes }

    static var runner: URL { folder.appendingPathComponent("llama/llama-server") }
    static var model: URL { folder.appendingPathComponent(modelFile) }
    static var projector: URL { folder.appendingPathComponent(projectorFile) }
    /// The two model files with their sizes and hashes, in download order.
    static var modelFiles: [(name: String, bytes: Int64, sha256: String)] {
        [(modelFile, modelBytes, modelSHA256), (projectorFile, projectorBytes, projectorSHA256)]
    }

    /// Where the record of a file's verified SHA-256 is kept.
    static func record(for url: URL) -> URL { url.appendingPathExtension("sha256") }
    static var runnerRecord: URL { folder.appendingPathComponent("llama/SHA256") }
    static func verified(_ record: URL, _ sha256: String) -> Bool {
        (try? String(contentsOf: record, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == sha256
    }

    /// Every file on disk, whole, and recorded as matching its pinned SHA-256.
    static var downloaded: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: runner.path) && verified(runnerRecord, runnerSHA256)
            && modelFiles.allSatisfy { size(folder.appendingPathComponent($0.name)) == $0.bytes && verified(record(for: folder.appendingPathComponent($0.name)), $0.sha256) }
    }
    /// The files are whole but one or more was never checked (downloaded by an earlier build): Settings offers Verify.
    static var unverified: Bool {
        !downloaded && FileManager.default.isExecutableFile(atPath: runner.path)
            && modelFiles.allSatisfy { size(folder.appendingPathComponent($0.name)) == $0.bytes }
    }

    /// The SHA-256 of a file, streamed; slow for the model (seconds), so off the main thread.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// Each agent's global instruction file, as the agent itself reads it, and the folder that says the agent is
    /// installed on this Mac: Codex, Claude Code, OpenCode and Pi. Only an installed agent can be told.
    struct InstructionFile: Identifiable {
        let agent: String
        let url: URL
        let home: URL
        var id: String { agent }
        var installed: Bool { FileManager.default.fileExists(atPath: home.path) }
    }
    static var instructionFiles: [InstructionFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [InstructionFile(agent: "Codex CLI", url: home.appendingPathComponent(".codex/AGENTS.md"), home: home.appendingPathComponent(".codex")),
                InstructionFile(agent: "Claude Code", url: home.appendingPathComponent(".claude/CLAUDE.md"), home: home.appendingPathComponent(".claude")),
                InstructionFile(agent: "OpenCode", url: home.appendingPathComponent(".config/opencode/AGENTS.md"), home: home.appendingPathComponent(".config/opencode")),
                InstructionFile(agent: "Pi", url: home.appendingPathComponent(".pi/agent/AGENTS.md"), home: home.appendingPathComponent(".pi"))]
    }

    static func hasInstruction(_ url: URL) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(marker)
    }

    /// Adds the line to one agent's file (made when there is none, inside the agent's own folder), or takes exactly
    /// that line out again, leaving everything else as it was. A file Nearloop itself made is removed again once
    /// only the line was in it; a file that was there before stays, whatever is left in it.
    static func setInstruction(_ on: Bool, for file: InstructionFile) throws {
        let fm = FileManager.default
        let url = file.url
        if on, !file.installed { throw Kapitsa.Failure(errorDescription: "\(file.agent) isn't installed (no \(file.home.path)).") }
        let existing = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
        var lines = (existing ?? "").components(separatedBy: "\n")
        let had = lines.contains { $0.contains(marker) }
        lines.removeAll { $0.contains(marker) }
        var text = lines.joined(separator: "\n")
        if on {
            // Appended so that taking the line out again gives the file back byte for byte: after a final newline
            // the line gets its own; after text with none, it follows on a new line and ends as the file did,
            // without one.
            text += text.isEmpty || text.hasSuffix("\n") ? instruction + "\n" : "\n" + instruction
        } else if !had {
            return
        }
        var created = Prefs.imageToolCreated
        if !on, text.isEmpty, existing != nil, created.contains(url.path) {
            try fm.removeItem(at: url)
            created.removeAll { $0 == url.path }
            Prefs.imageToolCreated = created
            return
        }
        guard text != existing else { return }
        if existing == nil {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            created.append(url.path)
            Prefs.imageToolCreated = created
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Takes the line out of every agent's file.
    static func clearInstructions() throws {
        var problems: [String] = []
        for file in instructionFiles {
            do { try setInstruction(false, for: file) } catch { problems.append("\(file.agent): \(error.localizedDescription)") }
        }
        if !problems.isEmpty { throw Kapitsa.Failure(errorDescription: problems.joined(separator: " ")) }
    }

    /// Turns the sidecar on (the command installed; each agent is told from its own switch in Settings) or off
    /// (the line taken out of every agent's file; the command stays for anyone who runs it by hand, and says what
    /// to do when the model is gone).
    static func setEnabled(_ on: Bool) throws {
        if on { try installTool() }
        Prefs.imageSidecar = on
        if !on { try clearInstructions() }
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
            // 1. The model and its projector, straight from Hugging Face; a file already whole and checked is kept,
            //    one whole but never checked is checked now, and one that fails its SHA-256 is removed.
            for file in ImageSidecar.modelFiles {
                let (name, bytes, sha256) = file
                let target = folder.appendingPathComponent(name), record = ImageSidecar.record(for: target)
                if ImageSidecar.size(target) == bytes, ImageSidecar.verified(record, sha256) { continue }
                if ImageSidecar.size(target) != bytes {
                    let partial = folder.appendingPathComponent(name + ".part")
                    job?.lastLine = "Downloading \(name)…"
                    let code = await run("/usr/bin/curl", ["-fsSL", "--retry", "3", "-C", "-", "-o", partial.path,
                                                          "https://huggingface.co/\(ImageSidecar.modelRepo)/resolve/\(ImageSidecar.modelRevision)/\(name)"])
                    if job?.state == .pausing { job?.state = .paused; return }
                    guard code == 0 else { throw Kapitsa.Failure(errorDescription: "Downloading \(name) failed (curl \(code)). Retry to resume it.") }
                    guard ImageSidecar.size(partial) == bytes else {
                        try? fm.removeItem(at: partial)
                        throw Kapitsa.Failure(errorDescription: "\(name) came down with the wrong size and was removed. Retry to download it again.")
                    }
                    try? fm.removeItem(at: target)
                    try fm.moveItem(at: partial, to: target)
                }
                try await check(target, against: sha256, named: name)
                revision += 1
            }
            // 2. llama.cpp's release: the archive, checked against the SHA-256 GitHub lists for it, then unpacked
            //    into llama/, flat as it ships.
            if !fm.isExecutableFile(atPath: ImageSidecar.runner.path) || !ImageSidecar.verified(ImageSidecar.runnerRecord, ImageSidecar.runnerSHA256) {
                let archive = folder.appendingPathComponent("llama.tar.gz")
                job?.lastLine = "Downloading llama.cpp \(ImageSidecar.runnerBuild)…"
                let code = await run("/usr/bin/curl", ["-fsSL", "--retry", "3", "-C", "-", "-o", archive.path, ImageSidecar.runnerURL.absoluteString])
                if job?.state == .pausing { job?.state = .paused; return }
                guard code == 0 else { throw Kapitsa.Failure(errorDescription: "Downloading llama.cpp failed (curl \(code)). Retry to resume it.") }
                guard ImageSidecar.size(archive) == ImageSidecar.runnerBytes else {
                    try? fm.removeItem(at: archive)
                    throw Kapitsa.Failure(errorDescription: "llama.cpp's archive came down with the wrong size and was removed. Retry to download it again.")
                }
                try await check(archive, against: ImageSidecar.runnerSHA256, named: "llama.cpp \(ImageSidecar.runnerBuild)")
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
                try ImageSidecar.runnerSHA256.write(to: ImageSidecar.runnerRecord, atomically: true, encoding: .utf8)
                try? fm.removeItem(at: archive)
                try? fm.removeItem(at: ImageSidecar.record(for: archive))  // (the runner's record is llama/SHA256)
            }
            job?.state = .finished
            job?.done = ImageSidecar.totalBytes
            revision += 1
        } catch {
            job?.state = .failed(error.localizedDescription)
            revision += 1
        }
    }

    /// Compares a file's SHA-256 with the pinned one and records the match beside it; a file that doesn't match
    /// is removed, and the download fails with a message.
    private func check(_ file: URL, against sha256: String, named name: String) async throws {
        job?.lastLine = "Checking \(name)…"
        let actual = try await Task.detached { try ImageSidecar.sha256(of: file) }.value
        guard actual == sha256 else {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: ImageSidecar.record(for: file))
            throw Kapitsa.Failure(errorDescription: "\(name) did not match its published SHA-256 (got \(actual.prefix(12))…) and was removed. Retry to download it again.")
        }
        try sha256.write(to: ImageSidecar.record(for: file), atomically: true, encoding: .utf8)
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
    /// The port the vision server uses: the one image_tool last started it on (`port` in the folder; it moves to a
    /// free one when another app holds 8765), else 8765.
    nonisolated static var port: Int {
        let text = try? String(contentsOf: folder.appendingPathComponent("port"), encoding: .utf8)
        guard let port = text.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }), (1024...65535).contains(port) else { return 8765 }
        return port
    }

    /// Whether the vision server is up: our llama-server listens on its port and answers (another app's server on
    /// that port doesn't count).
    nonisolated static func serverRunning() async -> Bool {
        let port = port
        let pid = await Task.detached { ServerController.listener(port) }.value
        guard pid != 0, isRunner(pid) else { return false }
        return await ServerController.healthy(port)
    }

    /// Stops the vision server the tool started, if it is running: the pid in server.pid is signalled only while
    /// it is still our llama-server (the file outlives a restart or a crashed watchdog, and pids are reused).
    static func stopServer() {
        let pidFile = folder.appendingPathComponent("server.pid")
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           isRunner(pid) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Whether a pid is our llama-server, by the executable it runs.
    static func isRunner(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE, which Swift doesn't see
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return path == runner.resolvingSymlinksInPath().path
    }
}
