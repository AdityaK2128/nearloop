import Foundation

/// A Kapitsa built from its source at the latest commit of `main`, for the people who compile their own rather
/// than wait for a release. Nearloop keeps a clone of
/// nace-ai/kapitsa and builds the `kapitsa` and `systemone` targets in Release, as the project's CONTRIBUTING.md
/// says; the binary stays in its build folder, where the CMakeCache.txt beside it tells Kapitsa itself that this is
/// a source build. A clone of the user's own, picked with Other…, is recognised the same way; it is compared with
/// nace-ai/kapitsa's main (not whatever its `origin` is) and moved forward only while it is on a clean `main`.
enum EngineSource {
    static let repository = "https://github.com/nace-ai/kapitsa.git"

    /// What Nearloop's own clone follows: Kapitsa's main, or a beta branch on a fork with work upstream hasn't
    /// shipped yet. A beta entry is removed from `betas` once Kapitsa ships it.
    struct Source: Identifiable, Equatable {
        let id: String
        let label: String
        /// The git URL to fetch from.
        let repository: String
        let branch: String
        /// One line on what the branch brings.
        let about: String
        /// The pull request that brings it upstream, once there is one.
        var pullRequest: URL? = nil
        var isMain: Bool { id == "main" }
        /// "owner/name" for GitHub's API.
        var github: String {
            repository.replacingOccurrences(of: "https://github.com/", with: "").replacingOccurrences(of: ".git", with: "")
        }
    }
    static let main = Source(id: "main", label: "Kapitsa main", repository: repository, branch: "main",
                             about: "The latest commit of nace-ai/kapitsa.")
    static let betas: [Source] = [
        Source(id: "ink2-vision", label: "Inkling image input (beta)", repository: "https://github.com/gelubodrug/kapitsa.git", branch: "ink2-vision",
               about: "Inkling-2-Mini reads images through the checkpoint’s own vision tower, so Chat and the agents can send it screenshots.",
               pullRequest: URL(string: "https://github.com/nace-ai/kapitsa/pull/1419")),
    ]
    static var sources: [Source] { [main] + betas }
    static func source(_ id: String?) -> Source { sources.first { $0.id == id } ?? main }

    /// The source chosen in Settings › Engine; before any choice, whatever branch Nearloop's clone is on (a clone
    /// switched to a beta branch by hand shows as that beta).
    static var chosen: Source {
        if let id = Prefs.engineSource { return source(id) }
        let branch = currentBranch(of: managed)
        return betas.first { $0.branch == branch } ?? main
    }

    /// The branch a checkout is on, from .git/HEAD; nil when there is no checkout or HEAD is detached.
    static func currentBranch(of checkout: Checkout) -> String? {
        guard let head = try? String(contentsOf: checkout.source.appendingPathComponent(".git/HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }
        return String(line.dropFirst("ref: refs/heads/".count))
    }

    /// The source a checkout follows: the chosen one for Nearloop's clone, main for a clone of the user's own.
    static func source(for checkout: Checkout) -> Source { checkout == managed ? chosen : main }

    /// Moves Nearloop's clone to the source's branch when that branch is there already and the clone is clean,
    /// so the Engine row and the next Check for Updates speak of the chosen source; the binary stays what it was
    /// until the next Build. Nothing to do when the branch is not local yet: Build fetches it.
    static func switchTo(_ source: Source) {
        guard let git = which("git"), !isBuilding(managed.binary),
              FileManager.default.fileExists(atPath: managed.source.appendingPathComponent(".git").path),
              currentBranch(of: managed) != source.branch else { return }
        guard (try? read(git, ["-C", managed.source.path, "status", "--porcelain", "--untracked-files=no"]))?.isEmpty == true else { return }
        guard (try? read(git, ["-C", managed.source.path, "rev-parse", "--verify", "-q", "refs/heads/\(source.branch)"])) != nil else { return }
        try? step(git, ["-C", managed.source.path, "checkout", "-q", source.branch], timeout: 60)
    }

    /// Build folders with a build under way. The engine there is being relinked, so `Kapitsa.binary` doesn't hand it
    /// out meanwhile, and a second build of the same checkout is refused (the pane can be closed and reopened while
    /// one runs).
    private static let lock = NSLock()
    private static var building: Set<String> = []
    static func isBuilding(_ binary: URL) -> Bool {
        let folder = binary.resolvingSymlinksInPath().deletingLastPathComponent().path
        lock.lock(); defer { lock.unlock() }
        return building.contains(folder)
    }
    static var anyBuilding: Bool { lock.lock(); defer { lock.unlock() }; return !building.isEmpty }

    /// A source checkout and the build folder inside it.
    struct Checkout: Equatable {
        let source: URL
        let build: URL
        var binary: URL { build.appendingPathComponent("kapitsa") }
    }

    /// The clone Nearloop makes when asked to build from source.
    static var managed: Checkout {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let source = support.appendingPathComponent("Nearloop/kapitsa-src", isDirectory: true)
        return Checkout(source: source, build: source.appendingPathComponent("build", isDirectory: true))
    }

    /// The checkout a binary was built in: a CMakeCache.txt beside it (build/kapitsa) or one folder up, the rule
    /// Kapitsa's own `update` uses. The cache names the source folder.
    static func checkout(of binary: URL) -> Checkout? {
        let fm = FileManager.default
        var folder = binary.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<2 {
            let cache = folder.appendingPathComponent("CMakeCache.txt")
            if fm.fileExists(atPath: cache.path) {
                let text = (try? String(contentsOf: cache, encoding: .utf8)) ?? ""
                let home = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("CMAKE_HOME_DIRECTORY:") }
                    .flatMap { $0.split(separator: "=", maxSplits: 1).last }.map { URL(fileURLWithPath: String($0)) }
                return Checkout(source: home ?? folder.deletingLastPathComponent(), build: folder)
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// The checkout the engine in use was built in, when it is a source build.
    static var current: Checkout? { Kapitsa.binary.flatMap(checkout(of:)) }

    /// A tool on the login shell's PATH: git comes with the Command Line Tools, cmake with Homebrew or cmake.org.
    static func which(_ tool: String) -> String? {
        for folder in Kapitsa.loginPath.split(separator: ":") {
            let path = "\(folder)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    enum Status: Equatable {
        case atLatest(String)
        /// How many commits behind, the words for the row, and the subjects of the newest of those commits.
        case behind(Int, String, [String])
        /// What main holds right now, for a checkout that is not built yet: the commit a Build would compile.
        case remote(String)
        case unknown(String)
    }

    /// "3 hours ago", from a git or GitHub date.
    static func age(_ iso: String) -> String? {
        let parsers = [ISO8601DateFormatter(), { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()]
        guard let date = parsers.lazy.compactMap({ $0.date(from: iso) }).first else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Fetches origin's main and says how many commits this checkout is behind it, by short hashes, with the age
    /// of main's latest commit.
    static func check(_ checkout: Checkout) -> Status {
        guard let git = which("git") else { return .unknown("git is not installed: run xcode-select --install") }
        let source = source(for: checkout)
        do {
            let branch = try read(git, ["-C", checkout.source.path, "rev-parse", "--abbrev-ref", "HEAD"])
            let head = try read(git, ["-C", checkout.source.path, "rev-parse", "--short", "HEAD"])
            if branch != source.branch {
                // Nearloop's clone on another branch than the chosen source's: Build switches it over.
                if checkout == managed { return .behind(0, "On branch \(branch) (\(head)): Build switches to \(source.branch)", []) }
                return .unknown("On branch \(branch) (\(head)): Build updates a checkout of main only")
            }
            // The source's branch, whatever this clone's origin is (a fork, say).
            try step(git, ["-C", checkout.source.path, "fetch", "-q", source.repository, source.branch], timeout: 120)
            let latest = try read(git, ["-C", checkout.source.path, "rev-parse", "--short", "FETCH_HEAD"])
            let when = age(try read(git, ["-C", checkout.source.path, "log", "-1", "--format=%cI", "FETCH_HEAD"])).map { ", \($0)" } ?? ""
            let behind = Int(try read(git, ["-C", checkout.source.path, "rev-list", "--count", "HEAD..FETCH_HEAD"])) ?? 0
            if behind == 0 { return .atLatest("At the latest commit on \(source.branch) (\(head)\(when))") }
            // What a Build would bring: the newest commits' subjects, as the branch's log words them.
            let subjects = try read(git, ["-C", checkout.source.path, "log", "--format=%s", "-n", "\(whatsNewLimit)", "HEAD..FETCH_HEAD"])
                .split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .behind(behind, "\(behind) commit\(behind == 1 ? "" : "s") behind \(source.branch) (\(head) → \(latest)\(when))", subjects)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// How many lines of what's new the Engine pane shows: commit subjects for a source build, release notes otherwise.
    static let whatsNewLimit = 12

    /// What the latest release brings, from its notes on GitHub: the bullet lines of the release body, without the
    /// markdown; empty when GitHub does not answer. For an installed engine, which updates to that release.
    static func releaseNotes() -> [String] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/nace-ai/kapitsa/releases/latest")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        var lines: [String] = []
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? String else { return }
            lines = body.split(whereSeparator: \.isNewline).map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("- ") || text.hasPrefix("* ") { text = String(text.dropFirst(2)) }
                return text.replacingOccurrences(of: "`", with: "")
            }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            lines = Array(lines.prefix(whatsNewLimit))
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return lines
    }

    /// What the source's branch holds right now, asked of GitHub before there is a checkout: the commit a first
    /// Build compiles.
    static func remote(_ source: Source = chosen) -> Status {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(source.github)/commits/\(source.branch)")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        var outcome: Status = .unknown("Could not reach GitHub")
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { outcome = .unknown("Could not reach GitHub: \(error.localizedDescription)"); return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String else { outcome = .unknown("GitHub gave no answer about \(source.branch)"); return }
            let date = ((json["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"] as? String
            let when = date.flatMap(age).map { ", \($0)" } ?? ""
            outcome = .remote("\(source.branch.prefix(1).uppercased() + source.branch.dropFirst()) is at \(sha.prefix(7))\(when) — not built yet")
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return outcome
    }

    /// Clones the repository when the checkout is not there yet, brings main up to nace-ai's, configures and builds
    /// `kapitsa` and `systemone` in Release. The first build takes minutes; `progress` names the step under way.
    static func update(_ checkout: Checkout, progress: @escaping (String) -> Void) throws {
        guard let git = which("git") else { throw Kapitsa.Failure(errorDescription: "git is not installed: run xcode-select --install") }
        guard let cmake = which("cmake") else { throw Kapitsa.Failure(errorDescription: "CMake is not installed: brew install cmake") }
        let key = checkout.binary.resolvingSymlinksInPath().deletingLastPathComponent().path
        lock.lock()
        let started = building.insert(key).inserted
        lock.unlock()
        guard started else { throw Kapitsa.Failure(errorDescription: "A build of this checkout is already running.") }
        defer { lock.lock(); building.remove(key); lock.unlock() }

        let fm = FileManager.default
        let source = source(for: checkout)
        if fm.fileExists(atPath: checkout.source.appendingPathComponent(".git").path) {
            // Only a clean checkout moves: work in progress stays as it is. A clone of the user's own moves only
            // on main; Nearloop's own clone switches to the chosen source's branch.
            let branch = try read(git, ["-C", checkout.source.path, "rev-parse", "--abbrev-ref", "HEAD"])
            guard branch == source.branch || checkout == managed else {
                throw Kapitsa.Failure(errorDescription: "\(checkout.source.path) is on branch \(branch); switch it to main to update it here.")
            }
            guard try read(git, ["-C", checkout.source.path, "status", "--porcelain", "--untracked-files=no"]).isEmpty else {
                throw Kapitsa.Failure(errorDescription: "\(checkout.source.path) has uncommitted changes; commit or stash them first.")
            }
            progress("Pulling \(source.branch)…")
            try step(git, ["-C", checkout.source.path, "fetch", "-q", source.repository, source.branch], timeout: 300)
            if source.isMain {
                if branch != "main" { try step(git, ["-C", checkout.source.path, "checkout", "-q", "-B", "main", "FETCH_HEAD"], timeout: 120) }
                else { try step(git, ["-C", checkout.source.path, "merge", "-q", "--ff-only", "FETCH_HEAD"], timeout: 120) }
            } else {
                // A beta branch follows the fork's tip, rebased or not: the local branch is set to what was fetched.
                try step(git, ["-C", checkout.source.path, "checkout", "-q", "-B", source.branch, "FETCH_HEAD"], timeout: 120)
            }
        } else {
            progress("Cloning \(source.github)…")
            try fm.createDirectory(at: checkout.source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try step(git, ["clone", "-q", "--depth", "50", "--branch", source.branch, source.repository, checkout.source.path], timeout: 900)
        }
        progress("Configuring (cmake)…")
        try step(cmake, ["-S", checkout.source.path, "-B", checkout.build.path, "-DCMAKE_BUILD_TYPE=Release"], timeout: 600)
        progress("Building kapitsa — minutes on the first build…")
        // A bounded job count: plain `-j` lets Make start every compile at once, which can run a Mac with a model
        // loaded out of memory. One job per core, and no more than about 1.5 GB of free memory each.
        let jobs = max(1, min(ProcessInfo.processInfo.activeProcessorCount, Int(SystemMemory.availableGB() / 1.5)))
        try step(cmake, ["--build", checkout.build.path, "--target", "kapitsa", "systemone", "-j", String(jobs)], timeout: 3600)
        guard fm.isExecutableFile(atPath: checkout.binary.path) else {
            throw Kapitsa.Failure(errorDescription: "The build finished but left no kapitsa in \(checkout.build.path).")
        }
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Kapitsa.loginPath
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private static func read(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try Kapitsa.runSync(executable, arguments, env: environment(), timeout: 30)
        guard result.code == 0 else { throw failure(executable, arguments, result) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func step(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws {
        let result = try Kapitsa.runSync(executable, arguments, env: environment(), timeout: timeout)
        guard result.code == 0 else { throw failure(executable, arguments, result) }
    }

    private static func failure(_ executable: String, _ arguments: [String], _ result: Kapitsa.Output) -> Kapitsa.Failure {
        let tail = result.output.split(whereSeparator: \.isNewline).suffix(3).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return Kapitsa.Failure(errorDescription: "\(name) \(arguments.first ?? "") failed (exit \(result.code)): \(tail)")
    }
}
