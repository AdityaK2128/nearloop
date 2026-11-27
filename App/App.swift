import AppKit
import ServiceManagement
import SwiftUI

struct MainWindow: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var updater = Updater.shared
    @AppStorage(Page.experimentalKey) private var experimental = false
    /// The sidebar's visibility, kept here so the toggle is the app's own: the system one left the toolbar when the
    /// sidebar collapsed, reappearing only inside an empty overflow button ("»") at the far right.
    @State private var columns = NavigationSplitViewVisibility.all
    /// The sidebar's download the user asked to cancel, until the alert is answered.
    @State private var cancelling: PendingDownload?

    var body: some View {
        let pages = Page.visible(experimental: experimental)
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding(get: { store.page }, set: { if let page = $0 { store.page = page } })) {
                ForEach(pages.filter { $0.section == nil }, id: \.self) { row($0) }
                ForEach(Page.sections.filter { section in pages.contains { $0.section == section } }, id: \.self) { section in
                    Section(section) {
                        ForEach(pages.filter { $0.section == section }, id: \.self) { row($0) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
            .toolbar(removing: .sidebarToggle)
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    // No animation: the split view's own slide let the content run past the window's right edge
                    // and spring back when the sidebar came back.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { columns = columns == .detailOnly ? .all : .detailOnly }
                    // AppKit brings a sidebar back by widening the window when it can, keeping the content's width;
                    // the window is to stay as the user sized it, so its frame is put back and the content gives way.
                    if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                        let frame = window.frame
                        var token: NSObjectProtocol?
                        // AppKit can resize more than once, so this watches for a second; a resize the user is dragging
                        // in that time is theirs, and stays.
                        token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                            if !window.inLiveResize, window.frame.size != frame.size { window.setFrame(frame, display: true, animate: false) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if let token { NotificationCenter.default.removeObserver(token) } }
                    }
                } label: {
                    Label(columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left")
                }
                .help(columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
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
            if !pendingDownloads.isEmpty {
                ForEach(pendingDownloads) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if item.busy {
                                SidebarIconButton(symbol: "pause.circle", hover: .accentColor, help: "Pause") { downloads.pause(item.id) }
                                    .disabled(item.pausing)
                            } else {
                                SidebarIconButton(symbol: "play.circle", hover: .accentColor, help: "Resume where it stopped") {
                                    downloads.start(item.id, title: item.title, expectedBytes: item.expected)
                                }
                            }
                            SidebarIconButton(symbol: "xmark.circle", hover: .red, help: "Cancel the download and delete its files") { cancelling = item }
                        }
                        // The percent sits at the bar's end, in the bar's own colour: blue while the download runs, grey paused.
                        HStack(spacing: 6) {
                            ProgressView(value: item.fraction).controlSize(.small).tint(item.busy ? Color.accentColor : Color.secondary)
                            Text(item.pausing ? "Pausing" : String(format: "%.0f%%", item.fraction * 100))
                                .font(.caption2).monospacedDigit().lineLimit(1).fixedSize()
                                .foregroundStyle(item.busy ? Color.accentColor : Color.secondary)
                        }
                    }
                }
                Divider()
            }
            HStack(spacing: 8) {
                StatusDot(server: server)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.record?.modelName ?? (server.phase == .external ? Offload.shared.externalName : "No Model Loaded"))
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Text(server.phase == .ready || server.phase == .external ? "Port \(String(server.port))" : server.phase == .starting ? "Loading…" : "Idle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if server.owned {
                    Button { server.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop Model")
                } else if server.phase == .external, Offload.shared.serving {
                    Button { Offload.shared.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop Model")
                }
            }
        }.padding(12)
        .alert(item: $cancelling) { item in
            Alert(title: Text("Cancel the download of \(item.title)?"),
                  message: Text(item.fraction > 0 ? String(format: "The %.0f%% downloaded so far is deleted.", item.fraction * 100) : "Its files are deleted."),
                  primaryButton: .destructive(Text("Delete Download")) {
                      Task {
                          do { try await downloads.cancel(item.id) } catch { store.errorMessage = error.localizedDescription }
                          await store.scan()
                      }
                  },
                  secondaryButton: .cancel(Text("Keep")))
        }
    }

    /// Every download the sidebar follows: the jobs of this session that have not finished (running, pausing,
    /// paused or failed) and the catalog folders an earlier session left unfinished (no job, files on disk), so a
    /// paused download can be resumed or cancelled from here without finding its card in Discover.
    private var pendingDownloads: [PendingDownload] {
        var rows = downloads.jobs.values.filter { $0.state != .finished }.map { job in
            PendingDownload(id: job.id, title: job.title, fraction: job.fraction, busy: job.busy, pausing: job.state == .pausing, expected: job.expected)
        }
        for variant in store.catalog.flatMap(\.variants) where downloads.jobs[variant.id] == nil {
            guard let model = store.localModel(for: variant), model.status == .incomplete else { continue }
            let fraction = variant.bytes > 0 ? min(0.99, Double(model.size) / Double(variant.bytes)) : 0
            rows.append(PendingDownload(id: variant.id, title: variant.id, fraction: fraction, busy: false, pausing: false, expected: variant.bytes))
        }
        return rows.sorted { $0.title < $1.title }
    }
}

/// A borderless icon button of the sidebar's download rows: grey until the pointer is over it, then its own colour
/// (blue for pause and play, red for cancel).
private struct SidebarIconButton: View {
    let symbol: String
    let hover: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(hovering ? hover : Color.secondary)
            .onHover { hovering = $0 }
            .help(help)
    }
}

/// A row of the sidebar's download list (MainWindow.pendingDownloads).
struct PendingDownload: Identifiable {
    let id: String
    let title: String
    let fraction: Double
    let busy: Bool
    let pausing: Bool
    let expected: Int64
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
        } else if server.phase == .external, Offload.shared.serving {
            Button("Stop Model") { Offload.shared.stop() }
        } else if server.canLoad, let path = Prefs.lastModel, let model = store.model(at: path) {
            Button("Load \(model.name)") { store.loadLast() }
        }
        if server.phase == .ready || server.phase == .external {
            Button("Copy API URL") { store.copy("http://127.0.0.1:\(server.port)/v1", "API URL copied.") }
        }
        Divider()
        Menu("Launch Agent") {
            ForEach(store.agentCatalog.filter { store.agents[$0.id] != nil }) { agent in
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
            CommandMenu("Go") { GoMenu() }
        }
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(nsImage: MenuBarIcon.image(active: server.phase == .ready))
        }
    }
}

/// The Go menu: one item per visible page, numbered ⌘1… in sidebar order.
struct GoMenu: View {
    @AppStorage(Page.experimentalKey) private var experimental = false

    var body: some View {
        ForEach(Array(Page.visible(experimental: experimental).enumerated()), id: \.element) { index, page in
            Button(page.title) { AppStore.shared.page = page }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        }
    }
}

