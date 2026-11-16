import SwiftUI

/// The update window: the answer to a check, the release notes, and the download and install progress.
struct UpdateSheet: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject var server = ServerController.shared
    @ObservedObject var downloads = Downloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.title3.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let release = updater.updateAvailable {
                        Link("Release Page ↗", destination: release.page).font(.callout)
                    }
                }
                Spacer(minLength: 0)
            }
            if let release = updater.updateAvailable {
                if !release.notes.isEmpty { ReleaseNotes(text: release.notes) }
                progress
                if updater.phase == .available || isFailed {
                    if let warning { Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            buttons
        }
        .padding(22)
        .frame(width: 520)
        .frame(minHeight: 160)
    }

    private var isFailed: Bool { if case .failed = updater.phase { return true }; return false }

    private var headline: String {
        switch updater.phase {
        case .checking: return "Checking for Updates…"
        case .failed where updater.updateAvailable == nil: return "Couldn’t Check for Updates"
        case .failed: return "The Update Didn’t Install"
        default:
            if let release = updater.updateAvailable { return "Nearloop \(release.version) Is Available" }
            return "Nearloop Is Up to Date"
        }
    }

    private var detail: String {
        if case .failed(let message) = updater.phase { return message }
        if updater.phase == .checking { return "Looking for the latest release on GitHub." }
        if let release = updater.updateAvailable {
            return "You have \(Updater.currentVersion)." + (release.size > 0 ? " The download is \(ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file))." : "")
        }
        return "Version \(Updater.currentVersion) is the latest release."
    }

    /// What installing interrupts, said before it happens.
    private var warning: String? {
        var parts = ["Nearloop quits, replaces itself and opens again."]
        if server.owned { parts.append("The running model stops; load it again afterwards.") }
        if !downloads.active.isEmpty { parts.append("Downloads in progress pause and can be resumed.") }
        if let work = AppStore.shared.unfinishedFileWork { parts.append("\(work); install once it finishes.") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder private var progress: some View {
        switch updater.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text(String(format: "Downloading… %.0f%%", fraction * 100)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying and installing…").font(.caption).foregroundStyle(.secondary)
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch updater.phase {
            case .checking:
                Spacer()
                ProgressView().controlSize(.small)
            case .downloading:
                Spacer()
                Button("Cancel") { updater.cancel() }
            case .installing:
                Spacer()
            default:
                if let release = updater.updateAvailable {
                    Button("Skip This Version") { updater.skip(release) }
                        .help("Don’t offer \(release.version) again. A newer version is still offered.")
                    Button("Don’t Remind Me") { updater.stopReminding() }
                        .help("Turns off automatic update checks. Turn them on again in Settings › General; Check for Updates… still works.")
                    Spacer()
                    Button("Later") { updater.showSheet = false }.keyboardShortcut(.cancelAction)
                    if Updater.installProblem == nil && release.download != nil {
                        Button(isFailed ? "Try Again" : "Install and Relaunch") { updater.install() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Download") { NSWorkspace.shared.open(release.download ?? release.page) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                } else {
                    if isFailed { Link("Releases on GitHub ↗", destination: Updater.releasesPage).font(.callout) }
                    Spacer()
                    if isFailed { Button("Try Again") { Task { await updater.check(userInitiated: true) } } }
                    Button("OK") { updater.showSheet = false }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// GitHub release notes, which are Markdown: headings, bullets and inline styles, shown simply.
private struct ReleaseNotes: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("#") {
                        Text(inline(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))).font(.callout.weight(.semibold)).padding(.top, 4)
                    } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(inline(String(line.dropFirst(2))))
                        }.font(.callout)
                    } else {
                        Text(inline(line)).font(.callout)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
        }
        .frame(maxHeight: 240)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var lines: [String] {
        text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }
}

/// A line in the sidebar when an update is waiting.
struct UpdateBanner: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        if let release = updater.pendingUpdate {
            Button { updater.showSheet = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update Available").font(.caption.weight(.medium))
                        Text("Nearloop \(release.version)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

/// Settings › General: the version, automatic checks, and a manual check.
struct UpdateSettings: View {
    @ObservedObject var updater = Updater.shared
    @AppStorage("checkForUpdates") private var automatic = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: "\(Updater.currentVersion) (\(Updater.currentBuild))")
            Toggle("Check for Updates Automatically", isOn: $automatic)
            HStack {
                Text(status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if updater.updateAvailable != nil {
                    Button("Install…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); updater.showSheet = true }
                }
                Button("Check Now") { Task { await updater.check(userInitiated: false) } }.disabled(updater.busy)
            }
        }
    }

    private var status: String {
        switch updater.phase {
        case .checking: return "Checking…"
        case .downloading, .installing: return "Installing an update…"
        case .failed(let message): return message
        case .upToDate: return "Up to date."
        case .available: return "Nearloop \(updater.latest?.version ?? "") is available."
        case .idle:
            let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
            return last > 0 ? "Last checked " + Date(timeIntervalSince1970: last).formatted(.relative(presentation: .named)) + "." : "Updates come from GitHub Releases."
        }
    }
}

/// "Check for Updates…", or "Update to 3.5…" once one is known; the update sheet lives on the main window, so it opens that first.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(updater.pendingUpdate.map { "Update to \($0.version)…" } ?? "Check for Updates…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            if updater.updateAvailable != nil { updater.showSheet = true } else { Task { await updater.check(userInitiated: true) } }
        }.disabled(updater.phase == .installing)
    }
}
