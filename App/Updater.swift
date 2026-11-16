import AppKit
import Foundation
import Security

/// A published release of Nearloop, from the repository's GitHub Releases.
struct AppRelease: Equatable {
    let version: String
    let title: String
    let notes: String
    let page: URL
    let download: URL?
    let size: Int
}

/// Checks GitHub Releases for a newer Nearloop, downloads its DMG, verifies that it is signed by the same
/// developer as the running app, replaces the app in place and relaunches it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading(Double), installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The newest release found, whether or not it is newer than this copy.
    @Published private(set) var latest: AppRelease?
    @Published var showSheet = false

    private var work: Task<Void, Never>?
    private var helper: Process?

    // MARK: Facts about this copy

    nonisolated static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    nonisolated static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    /// "owner/name"; set at build time, so a fork updates from its own releases.
    nonisolated static var repository: String { Bundle.main.infoDictionary?["NearloopUpdateRepository"] as? String ?? "AdityaK2128/nearloop" }
    nonisolated static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    /// The API address. NEARLOOP_UPDATE_URL points it elsewhere for testing; whatever it serves still has to
    /// pass the signature check before it is installed.
    nonisolated private static var feed: URL {
        if let custom = ProcessInfo.processInfo.environment["NEARLOOP_UPDATE_URL"], let url = URL(string: custom) { return url }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    var updateAvailable: AppRelease? {
        guard let latest, Self.isNewer(latest.version, than: Self.currentVersion) else { return nil }
        return latest
    }

    /// Shown in the sidebar: an update the user hasn't chosen to skip.
    var pendingUpdate: AppRelease? {
        guard let release = updateAvailable, release.version != UserDefaults.standard.string(forKey: "skippedVersion") else { return nil }
        return release
    }

    var busy: Bool {
        switch phase { case .checking, .downloading, .installing: return true; default: return false }
    }

    // MARK: Checking

    /// When automatic checks are on: checks at every launch and offers an update the user hasn't skipped
    /// (Skip This Version, or Don't Remind Me to stop these checks); then checks once a day while open,
    /// which only updates the sidebar and menu.
    func startAutomaticChecks() {
        Self.cleanUpLeftovers()
        Task {
            if Prefs.checkForUpdates, !busy {
                await check(userInitiated: false)
                if Prefs.checkForUpdates, pendingUpdate != nil, phase == .available { showSheet = true }
            }
            while true {
                try? await Task.sleep(for: .seconds(6 * 3600))
                let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
                if Prefs.checkForUpdates, Date().timeIntervalSince1970 - last > 24 * 3600, !busy {
                    await check(userInitiated: false)
                }
            }
        }
    }

    /// A manual check opens the sheet to show the answer; an automatic one only updates the sidebar.
    func check(userInitiated: Bool) async {
        guard !busy else { if userInitiated { showSheet = true }; return }
        if userInitiated { showSheet = true }
        phase = .checking
        do {
            var request = URLRequest(url: Self.feed, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Nearloop/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw Kapitsa.Failure(errorDescription: status == 403 || status == 429
                    ? "GitHub is limiting requests right now. Try again in a while."
                    : status == 404 ? "No releases were found." : "GitHub answered with an error (\(status)).")
            }
            latest = try Self.parse(data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            phase = updateAvailable == nil ? .upToDate : .available
        } catch {
            phase = .failed((error as? URLError).map { _ in "Couldn’t reach GitHub. Check your internet connection." } ?? error.localizedDescription)
        }
    }

    nonisolated static func parse(_ data: Data) throws -> AppRelease {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw Kapitsa.Failure(errorDescription: "The release information couldn’t be read.")
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        return AppRelease(version: version, title: json["name"] as? String ?? "Nearloop \(version)",
                          notes: json["body"] as? String ?? "",
                          page: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage,
                          download: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                          size: dmg?["size"] as? Int ?? 0)
    }

    /// Compares dotted versions numerically: 3.10 is newer than 3.9, and 3.4 equals 3.4.0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.version, forKey: "skippedVersion")
        showSheet = false
    }

    /// Turns off automatic checks (Settings › General turns them on again); manual checks still work.
    func stopReminding() {
        UserDefaults.standard.set(false, forKey: "checkForUpdates")
        showSheet = false
    }

    // MARK: Installing

    /// Why this copy can't replace itself, if it can't; the release page is offered instead.
    nonisolated static var installProblem: String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return "Nearloop is running from a temporary location macOS made for it. Move Nearloop to your Applications folder, open it from there, then update."
        }
        if path.hasPrefix("/Volumes/") && !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return "Nearloop is running from its disk image. Drag it to your Applications folder, open it from there, then update."
        }
        if !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return "Nearloop can’t replace itself in \((path as NSString).deletingLastPathComponent). Download the update and drag it there yourself."
        }
        if signingTeam(of: Bundle.main.bundleURL) == nil {
            return "This copy of Nearloop is a development build without a Developer ID signature, so it can’t verify an update. Download the release and install it yourself."
        }
        return nil
    }

    func install() {
        guard let release = updateAvailable, let download = release.download else { return }
        if let problem = Self.installProblem { phase = .failed(problem); return }
        if let work = AppStore.shared.unfinishedFileWork { phase = .failed("\(work). Install the update once it finishes."); return }
        phase = .downloading(0)
        work = Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nearloop-update-\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                // The updater lives as long as the app, so its progress closure holds it plainly.
                let dmg = try await UpdateDownload.run(download, to: folder.appendingPathComponent("Nearloop.dmg")) { fraction in
                    Task { @MainActor in if case .downloading = Updater.shared.phase { Updater.shared.phase = .downloading(fraction) } }
                }
                try Task.checkCancellation()
                phase = .installing
                let staged = try await Task.detached { try Self.stage(dmg: dmg, in: folder, expecting: release.version) }.value
                // Quitting skips the defer above, so the download goes now.
                try? FileManager.default.removeItem(at: folder)
                try await relaunch(into: staged)
            } catch is CancellationError {
                phase = .available
            } catch {
                if (error as? URLError)?.code == .cancelled { phase = .available; return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        work?.cancel()
        UpdateDownload.cancelAll()
    }

    /// Mounts the DMG, checks the app inside, and copies it next to this one, ready to swap in.
    nonisolated static func stage(dmg: URL, in folder: URL, expecting version: String) throws -> URL {
        let mount = folder.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try Kapitsa.runSync("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path], timeout: 120)
        guard attach.code == 0 else { throw Kapitsa.Failure(errorDescription: "The downloaded disk image couldn’t be opened. It may be damaged; try again.") }
        defer { _ = try? Kapitsa.runSync("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"], timeout: 60) }

        guard let name = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw Kapitsa.Failure(errorDescription: "The disk image doesn’t contain the app.")
        }
        let app = mount.appendingPathComponent(name)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Kapitsa.Failure(errorDescription: "The download isn’t Nearloop, so it wasn’t installed.")
        }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(newVersion, than: currentVersion) else {
            throw Kapitsa.Failure(errorDescription: "The download is version \(newVersion), which isn’t newer than this one, so it wasn’t installed.")
        }
        try verifySignature(app)

        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".Nearloop-update.app")
        try? FileManager.default.removeItem(at: staged)
        let copy = try Kapitsa.runSync("/usr/bin/ditto", [app.path, staged.path], timeout: 300)
        guard copy.code == 0 else { throw Kapitsa.Failure(errorDescription: "The update couldn’t be copied into \(parent.path).") }
        // The copy must still be the app that was verified.
        try verifySignature(staged)
        return staged
    }

    /// The candidate must satisfy this app's own designated requirement: the same bundle identifier, signed
    /// by the same Developer ID team. An ad-hoc build's requirement is its own hash, which nothing else meets.
    nonisolated static func verifySignature(_ app: URL) throws {
        var current: SecCode?
        var currentStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess, let currentStatic,
              SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw Kapitsa.Failure(errorDescription: "Nearloop couldn’t read its own signature to verify the update.")
        }
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw Kapitsa.Failure(errorDescription: "The update’s signature couldn’t be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw Kapitsa.Failure(errorDescription: "The update isn’t signed by Nearloop’s developer, so it wasn’t installed.")
        }
    }

    nonisolated static func signingTeam(of app: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Starts a small script that waits for this process to exit, swaps the staged app in, and opens it; then quits.
    private func relaunch(into staged: URL) async throws {
        // A move or conversion started while the update downloaded would be cut off partway.
        if let work = AppStore.shared.unfinishedFileWork {
            try? FileManager.default.removeItem(at: staged)
            throw Kapitsa.Failure(errorDescription: "\(work). Install the update once it finishes.")
        }
        let current = Bundle.main.bundleURL
        let backup = current.deletingLastPathComponent().appendingPathComponent(".Nearloop-previous.app")
        let script = """
        pid="$1"; current="$2"; staged="$3"; backup="$4"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i+1)); [ "$i" -gt 600 ] && { rm -rf "$staged"; exit 1; }
          sleep 0.5
        done
        rm -rf "$backup"
        if mv "$current" "$backup"; then
          if mv "$staged" "$current"; then rm -rf "$backup"; else mv "$backup" "$current"; fi
        fi
        open "$current"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "nearloop-update", String(ProcessInfo.processInfo.processIdentifier),
                             current.path, staged.path, backup.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        helper = process

        // Stop the model here, so quitting doesn't ask about it a second time.
        let server = ServerController.shared
        if server.owned { server.stopAndWait() }
        BenchmarkRunner.shared.cancel()
        // Downloads pause, as the update window says, rather than carry on without the app.
        Downloads.shared.pauseAllAndWait()
        // macOS won't quit while a window has a sheet open, so close this one first.
        showSheet = false
        try? await Task.sleep(for: .milliseconds(500))
        NSApp.terminate(nil)
        // Still running: something cancelled the quit. Call off the swap.
        process.terminate()
        helper = nil
        try? FileManager.default.removeItem(at: staged)
        phase = .failed("Quitting was cancelled, so the update wasn’t installed.")
        showSheet = true
    }

    /// Removes a staged copy left behind by an update that didn't finish.
    private static func cleanUpLeftovers() {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        for name in [".Nearloop-update.app", ".Nearloop-previous.app"] {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("nearloop-update-") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }
}

/// One file download with progress, for the update DMG.
private final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    private static var sessions: [URLSession] = []
    private static let lock = NSLock()

    private let destination: URL
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func run(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let delegate = UpdateDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        lock.withLock { sessions.append(session) }
        defer { session.finishTasksAndInvalidate(); lock.withLock { sessions.removeAll { $0 === session } } }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("Nearloop/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    static func cancelAll() { lock.withLock { sessions.forEach { $0.invalidateAndCancel() } } }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(.failure(Kapitsa.Failure(errorDescription: "The download failed (\(status)). Try again.")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
