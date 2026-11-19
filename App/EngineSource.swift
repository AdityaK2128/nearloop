import Foundation

/// A Kapitsa built from its source at the latest commit of `main`, for the people who compile their own rather
/// than wait for a release (user, 19.11: "ultimul commit, nu ultimul build"). Nearloop keeps a clone of
/// nace-ai/kapitsa and builds the `kapitsa` and `systemone` targets in Release, as the project's CONTRIBUTING.md
/// says; the binary stays in its build folder, where the CMakeCache.txt beside it tells Kapitsa itself that this is
/// a source build. A clone of the user's own, picked with Choose…, is recognised the same way and updated the same
/// way: `git pull`, then `cmake --build`.
enum EngineSource {
    static let repository = "https://github.com/nace-ai/kapitsa.git"

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
        case behind(Int, String)
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
        do {
            try step(git, ["-C", checkout.source.path, "fetch", "-q", "origin", "main"], timeout: 120)
            let head = try read(git, ["-C", checkout.source.path, "rev-parse", "--short", "HEAD"])
            let latest = try read(git, ["-C", checkout.source.path, "rev-parse", "--short", "origin/main"])
            let when = age(try read(git, ["-C", checkout.source.path, "log", "-1", "--format=%cI", "origin/main"])).map { ", \($0)" } ?? ""
            let behind = Int(try read(git, ["-C", checkout.source.path, "rev-list", "--count", "HEAD..origin/main"])) ?? 0
            if behind == 0 { return .atLatest("At the latest commit on main (\(head)\(when))") }
            return .behind(behind, "\(behind) commit\(behind == 1 ? "" : "s") behind main (\(head) → \(latest)\(when))")
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// What main holds right now, asked of GitHub before there is a checkout: the commit a first Build compiles.
    static func remote() -> Status {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/nace-ai/kapitsa/commits/main")!, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        var outcome: Status = .unknown("Could not reach GitHub")
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { outcome = .unknown("Could not reach GitHub: \(error.localizedDescription)"); return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String else { outcome = .unknown("GitHub gave no answer about main"); return }
            let date = ((json["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"] as? String
            let when = date.flatMap(age).map { ", \($0)" } ?? ""
            outcome = .remote("Latest on main: \(sha.prefix(7))\(when) — not built yet")
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return outcome
    }

    /// Clones the repository when the checkout is not there yet, pulls main, configures and builds `kapitsa` and
    /// `systemone` in Release. The first build takes minutes; `progress` names the step under way.
    static func update(_ checkout: Checkout, progress: @escaping (String) -> Void) throws {
        guard let git = which("git") else { throw Kapitsa.Failure(errorDescription: "git is not installed: run xcode-select --install") }
        guard let cmake = which("cmake") else { throw Kapitsa.Failure(errorDescription: "CMake is not installed: brew install cmake") }
        let fm = FileManager.default
        if fm.fileExists(atPath: checkout.source.appendingPathComponent(".git").path) {
            progress("Pulling main…")
            try step(git, ["-C", checkout.source.path, "pull", "-q", "--ff-only", "origin", "main"], timeout: 300)
        } else {
            progress("Cloning nace-ai/kapitsa…")
            try fm.createDirectory(at: checkout.source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try step(git, ["clone", "-q", "--depth", "50", repository, checkout.source.path], timeout: 900)
        }
        progress("Configuring (cmake)…")
        try step(cmake, ["-S", checkout.source.path, "-B", checkout.build.path, "-DCMAKE_BUILD_TYPE=Release"], timeout: 600)
        progress("Building kapitsa — minutes on the first build…")
        try step(cmake, ["--build", checkout.build.path, "--target", "kapitsa", "systemone", "-j"], timeout: 3600)
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
