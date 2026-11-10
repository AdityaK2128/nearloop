import AppKit
import ServiceManagement
import SwiftUI

struct MainWindow: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var updater = Updater.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { store.page }, set: { if let page = $0 { store.page = page } })) {
                ForEach(Page.allCases.filter { $0.section == nil }, id: \.self) { row($0) }
                ForEach(Page.sections, id: \.self) { section in
                    Section(section) {
                        ForEach(Page.allCases.filter { $0.section == section }, id: \.self) { row($0) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.page {
                    case .home: HomeView()
                    case .chat: ChatView()
                    case .settings: SettingsPage()
                    case .discover: DiscoverView()
                    case .models: ModelsView()
                    case .agents: AgentsView()
                    case .usage: UsageView()
                    case .benchmarks: BenchmarksView()
                    case .experimental: ExperimentalView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !store.notice.isEmpty {
                    Divider()
                    HStack {
                        Text(store.notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button { store.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).font(.caption)
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
        .onChange(of: store.selectedModelID) { _, id in
            UserDefaults.standard.set(id, forKey: "selectedModel")
            store.clampContext()
        }
        .onChange(of: server.phase) { _, phase in
            switch phase {
            case .ready: store.notice = "Model ready."
            case .failed: store.notice = "Model failed to start. See Logs for details."
            case .stopped: store.notice = "Model stopped."
            default: break
            }
        }
        .alert("Nearloop", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert(store.launchWarning.map { "Not enough context for \(Agents.displayName($0.agent))" } ?? "",
               isPresented: Binding(get: { store.launchWarning != nil }, set: { if !$0 { store.launchWarning = nil } }),
               presenting: store.launchWarning) { warning in
            if let context = warning.reload {
                Button("Reload at \(warning.reloadLabel ?? context) and Launch") { store.reloadAndLaunch(warning.agent, project: warning.project, context: context) }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Launch Anyway") { store.launch(warning.agent, project: warning.project, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { warning in Text(warning.message) }
        .sheet(isPresented: $store.showLog) { LogSheet() }
        .sheet(isPresented: $updater.showSheet) { UpdateSheet() }
    }

    /// The tag must be the outermost modifier: a list matches rows to its selection by it, and a modifier
    /// applied after it (such as a badge) hides it, which leaves every row unclickable.
    private func row(_ page: Page) -> some View {
        Label(page.title, systemImage: page.symbol).tag(page)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            UpdateBanner()
            if !downloads.active.isEmpty {
                ForEach(downloads.active) { job in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(job.title).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(job.state == .pausing ? "Pausing" : String(format: "%.0f%%", job.fraction * 100))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: job.fraction).controlSize(.small)
                    }
                }
                Divider()
            }
            HStack(spacing: 8) {
                StatusDot(server: server)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.record?.modelName ?? (server.phase == .external ? Offload.shared.externalName : "No Model Loaded"))
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Text(server.phase == .ready ? "Port \(server.port)" : server.phase == .starting ? "Loading…" : "Idle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if server.owned {
                    Button { server.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop Model")
                }
            }
        }.padding(12)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(server.record.map { "\($0.modelName) — \(server.phase == .ready ? "Running" : "Loading")" } ?? (server.phase == .external ? Offload.shared.externalName + " Running" : "No Model Loaded"))
        Divider()
        if server.owned {
            Button("Stop Model") { server.stop() }
        } else if !server.running, let path = Prefs.lastModel, let model = store.model(at: path) {
            Button("Load \(model.name)") { store.loadLast() }
        }
        if server.phase == .ready || server.phase == .external {
            Button("Copy API URL") { store.copy("http://127.0.0.1:\(server.port)/v1", "API URL copied.") }
        }
        Divider()
        Menu("Launch Agent") {
            ForEach(Agents.catalog.filter { store.agents[$0.id] != nil }) { agent in
                Menu(agent.name) {
                    Button("Open Project…") { NSApp.activate(ignoringOtherApps: true); store.launch(agent.id) }
                    ForEach(Prefs.recentProjects, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { store.launch(agent.id, project: URL(fileURLWithPath: path)) }
                    }
                }
            }
            if store.agents.isEmpty { Text("No Agents Installed") }
        }
        Divider()
        Button("Open Chat") { store.page = .chat; openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Open Nearloop") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        CheckForUpdatesButton()
        OpenSettingsButton()
        Divider()
        Button("Quit Nearloop") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The app icon's K monogram as a menu bar template glyph: the bob is filled while a model is running.
enum MenuBarIcon {
    /// The app icon's loop and point as an 18-point template glyph: the point is filled while a model runs.
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 8.4, y: 8.4), radius: CGFloat = 5.8, point = CGFloat.pi / 4
            NSColor.black.set()
            // Same proportions as the app icon: a ring with a gap where the point is passing.
            let loop = NSBezierPath()
            loop.appendArc(withCenter: center, radius: radius, startAngle: (point + 0.64) * 180 / .pi,
                           endAngle: (point - 0.64 + 2 * .pi) * 180 / .pi)
            loop.lineWidth = 2.2; loop.lineCapStyle = .round
            loop.stroke()
            let dot = NSPoint(x: center.x + radius * cos(point), y: center.y + radius * sin(point)), size: CGFloat = 2.4
            let rect = NSRect(x: dot.x - size, y: dot.y - size, width: size * 2, height: size * 2)
            if active {
                NSBezierPath(ovalIn: rect).fill()
            } else {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            QuickChatHotKey.shared.register()
            await AppStore.shared.bootstrap()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let server = ServerController.shared
            if let work = AppStore.shared.unfinishedFileWork {
                let alert = NSAlert()
                alert.messageText = "Quit Before It Finishes?"
                alert.informativeText = "\(work). Quitting now stops it partway and can leave an incomplete copy behind."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Anyway")
                guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            }
            if server.owned {
                let alert = NSAlert()
                alert.messageText = "Stop Running Model?"
                alert.informativeText = "Quitting stops \(server.record?.modelName ?? "the model"). Connected agents and chats will disconnect."
                alert.addButton(withTitle: "Stop and Quit")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
                server.stopAndWait()
            }
            BenchmarkRunner.shared.cancel()
            Downloads.shared.pauseAllAndWait()
            ChatStore.shared.saveInProgress()
            return .terminateNow
        }
    }
}

@main
struct NearloopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var server = ServerController.shared

    init() { Prefs.migrate() }

    var body: some Scene {
        Window("Nearloop", id: "main") {
            MainWindow().tint(Color(red: 0.29, green: 0.55, blue: 0.76))
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            // Settings is a page of the main window, so ⌘, opens it there.
            CommandGroup(replacing: .appSettings) { OpenSettingsButton() }
            CommandGroup(after: .newItem) {
                Button("Add Model Folder…") { AppStore.shared.addLibrary() }.keyboardShortcut("o")
            }
            CommandMenu("Go") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    Button(page.title) { AppStore.shared.page = page }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(nsImage: MenuBarIcon.image(active: server.phase == .ready))
        }
    }
}
