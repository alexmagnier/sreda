// AppState — the only place that schedules work. Collapsed: memory every 3 s + events only.
// Expanded: stats 2 s, processes 5 s, disk 60 s, windows on demand. Everything stops on collapse.
import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var expanded = false { didSet { expanded ? startExpanded() : stopExpanded() } }
    @Published var tab: PanelTab = .agents {
        didSet { if tab == .windows { refreshWindows() } else if tab == .system { sampleProcesses() } }
    }
    @Published private(set) var system = SystemSnapshot()
    @Published private(set) var processesByCPU: [ProcessRow] = []
    @Published private(set) var processesByMemory: [ProcessRow] = []
    @Published private(set) var windows: [WindowItem] = []
    /// First window list of this expansion is still being built (AX scan of other desktops can take ~1 s).
    @Published private(set) var windowsLoading = false
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var lmstudio = LMStudioStatus()
    @Published private(set) var permissions = PermissionStatus()
    @Published private(set) var highlight: AgentState? = nil      // pulse after a transition
    /// Sessions that finished (working → idle/error) and whose window the user has not opened since.
    @Published private(set) var unseen: Set<String> = []
    @Published var unloading = false
    /// Pill hidden by the user until this moment ("Скрыть на час").
    @Published var hiddenUntil: Date? = nil

    /// The user explicitly asked to see the island (menu bar icon / reopened the app) — show it even while
    /// the screen is mirrored. Reset by PanelController when mirroring starts or stops.
    @Published var forceVisible = false
    /// Filled by StatusItemController for the debug dump (menu bar icon present and where).
    static var statusItemDebug: String = "none"

    func hide(for seconds: TimeInterval) {
        expanded = false
        forceVisible = false
        hiddenUntil = Date().addingTimeInterval(seconds)
    }

    /// Hide until 9:00 tomorrow (or today, if it is before 9:00 now).
    func hideUntilMorning() {
        let cal = Calendar.current
        let now = Date()
        var target = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(8 * 3600)
        if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        hide(for: target.timeIntervalSince(now))
    }

    func showNow(expand: Bool) {
        hiddenUntil = nil
        forceVisible = true
        if expand { expanded = true }
    }

    let stats: SystemStatsProviding
    let processes: ProcessSampling
    let windowService: WindowProviding
    let sessionStore: SessionWatching
    let lms: LMStudioControlling
    let permissionsProvider: () -> PermissionStatus

    private var memoryTimer: Timer?
    private var fastTimer: Timer?
    private var processTimer: Timer?
    private var diskTimer: Timer?
    private var highlightWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Window listing runs here: AX calls into other apps must never block the main thread.
    private let windowQueue = DispatchQueue(label: "local.claude-kit.island.windows", qos: .userInitiated)
    private var windowsGeneration = 0

    init(stats: SystemStatsProviding, processes: ProcessSampling, windows: WindowProviding,
         sessions: SessionWatching, lms: LMStudioControlling, permissions: @escaping () -> PermissionStatus) {
        self.stats = stats
        self.processes = processes
        self.windowService = windows
        self.sessionStore = sessions
        self.lms = lms
        self.permissionsProvider = permissions
    }

    // MARK: lifecycle

    func start() {
        sampleMemory()
        system.thermal = stats.thermal()
        memoryTimer = makeTimer(3.0) { [weak self] in self?.sampleMemory() }

        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.sampleMemory() }
        src.resume()
        pressureSource = src

        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.system.thermal = self?.stats.thermal() ?? .nominal }
            })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.expanded, self.tab == .windows else { return }
                    self.refreshWindows()
                }
            })
        }

        sessionStore.start { [weak self] list in
            MainActor.assumeIsolated { self?.applySessions(list) }
        }
        permissions = permissionsProvider()

        // Debug / automation hooks (local only, no data leaves the process except the dump file):
        //   local.claude-kit.island.toggle — expand/collapse;  local.claude-kit.island.dump — write state JSON.
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("local.claude-kit.island.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.expanded.toggle() }
        })
        observers.append(dnc.addObserver(forName: .init("local.claude-kit.island.dump"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dumpState() }
        })
    }

    private func dumpState() {
        let f = ISO8601DateFormatter()
        let obj: [String: Any] = [
            "expanded": expanded,
            "statusItem": AppState.statusItemDebug,
            "forceVisible": forceVisible,
            "memoryUsedGB": Double(system.memoryUsedBytes) / 1_073_741_824,
            "memoryTotalGB": Double(system.memoryTotalBytes) / 1_073_741_824,
            "pressure": system.memoryPressure.rawValue,
            "cpu": system.cpuPercent ?? -1, "gpu": system.gpuPercent ?? -1,
            "thermal": system.thermal.label,
            "sessions": sessions.map { ["project": $0.project, "name": $0.name, "client": $0.clientLabel,
                                        "state": $0.state.rawValue, "since": f.string(from: $0.since),
                                        "unseen": unseen.contains($0.id), "message": $0.message ?? ""] },
            "counts": ["working": counts.working, "ready": counts.ready, "waiting": counts.waiting],
            "windows": windows.count,
            "windowRows": windows.map { ["app": $0.appName, "primary": $0.primary, "secondary": $0.secondary ?? "",
                                         "badge": $0.badge ?? "", "tabs": $0.tabs.count, "space": $0.spaceIndex ?? 0,
                                         "minimized": $0.isMinimized] },
            "lmstudio": ["up": lmstudio.serverUp, "loaded": lmstudio.loadedModels],
            "permissions": ["accessibility": permissions.accessibility, "screenRecording": permissions.screenRecording],
        ]
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/island-build/state.json")
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func startExpanded() {
        permissions = permissionsProvider()
        sampleFast()
        sampleProcesses()
        system.diskFreeBytes = stats.diskFree()
        if tab == .windows { refreshWindows() }
        refreshLMStudio()
        fastTimer = makeTimer(3.0) { [weak self] in self?.sampleFast() }
        processTimer = makeTimer(5.0) { [weak self] in
            guard let self else { return }
            self.sampleProcesses(); self.refreshLMStudio()
            if self.tab == .windows {                 // tabs and folders change while you work; permission may be granted
                self.refreshPermissions()
                self.refreshWindows()
            }
        }
        diskTimer = makeTimer(60.0) { [weak self] in self?.system.diskFreeBytes = self?.stats.diskFree() }
    }

    private func stopExpanded() {
        [fastTimer, processTimer, diskTimer].forEach { $0?.invalidate() }
        fastTimer = nil; processTimer = nil; diskTimer = nil
        system.cpuPercent = nil
        system.gpuPercent = nil
    }

    private func makeTimer(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        t.tolerance = interval * 0.25                       // let macOS coalesce wake-ups
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    // MARK: sampling

    private func sampleMemory() {
        let m = stats.sampleMemory()
        // publish only meaningful changes (≥ 50 MB or pressure) to avoid redrawing the pill
        if abs(Int64(m.used) - Int64(system.memoryUsedBytes)) >= 50_000_000 || m.pressure != system.memoryPressure
            || system.memoryUsedBytes == 0 {
            system.memoryUsedBytes = m.used
            system.memoryTotalBytes = m.total
            system.memoryCompressedBytes = m.compressed
            system.memoryPressure = m.pressure
        }
    }

    private func sampleFast() {
        sampleMemory()
        // publish only visible changes: every @Published write re-renders the whole panel
        let cpu = stats.sampleCPU(), gpu = stats.sampleGPU()
        if cpu.map({ abs($0 - (system.cpuPercent ?? -10)) >= 1 }) ?? false { system.cpuPercent = cpu }
        if gpu.map({ abs($0 - (system.gpuPercent ?? -10)) >= 1 }) ?? false { system.gpuPercent = gpu }
    }

    private func sampleProcesses() {
        guard tab == .system else { return }          // only the System tab shows processes
        let r = processes.sample(limit: 6)
        if r.byCPU.map(\.id) != processesByCPU.map(\.id) || r.byCPU.map({ Int($0.cpuPercent) }) != processesByCPU.map({ Int($0.cpuPercent) }) { processesByCPU = r.byCPU }
        if r.byMemory.map(\.id) != processesByMemory.map(\.id) { processesByMemory = r.byMemory }
    }

    func refreshWindows() {
        windowsGeneration += 1
        let gen = windowsGeneration
        if windows.isEmpty { windowsLoading = true }
        let svc = windowService
        windowQueue.async { [weak self] in
            let list = svc.listWindows()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.windowsGeneration else { return }
                    if self.windows != list { self.windows = list }
                    self.windowsLoading = false
                }
            }
        }
    }

    /// Debug rendering only: fill the list synchronously.
    func loadWindowsNow() {
        windows = windowService.listWindows()
    }

    func refreshPermissions() {
        permissions = permissionsProvider()
    }

    private func refreshLMStudio() {
        Task { [weak self] in
            guard let self else { return }
            let s = await self.lms.status()
            self.lmstudio = s
        }
    }

    // MARK: sessions

    private func applySessions(_ list: [AgentSession]) {
        let old = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
        // waiting → error → finished & not yet seen → working → the rest; newest first inside a group
        func rank(_ s: AgentSession) -> Int {
            switch s.state {
            case .waiting: return 0
            case .error: return 1
            case .idle: return unseen.contains(s.id) ? 2 : 4
            case .working: return 3
            }
        }
        var pulseState: AgentState? = nil
        defer { sessions = list.sorted { (rank($0), $1.since) < (rank($1), $0.since) } }
        for s in list {
            guard let prev = old[s.id], prev != s.state else { continue }
            if prev == .working && (s.state == .idle || s.state == .error) { unseen.insert(s.id) }
            if s.state == .working { unseen.remove(s.id) }
            if s.state != .working { pulseState = pulseState ?? s.state }
        }
        unseen = unseen.intersection(Set(list.map(\.id)))           // forget ended sessions
        if let p = pulseState { pulse(p) }
    }

    private func pulse(_ state: AgentState) {
        highlightWork?.cancel()
        highlight = state
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.highlight = nil } }
        highlightWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    /// Pill counters: working · ready & not yet looked at · needs you.
    var counts: (working: Int, ready: Int, waiting: Int) {
        (sessions.filter { $0.state == .working }.count,
         sessions.filter { $0.state != .working && $0.state != .waiting && unseen.contains($0.id) }.count,
         sessions.filter { $0.state == .waiting }.count)
    }

    // MARK: actions

    func focus(_ window: WindowItem) {
        windowService.focus(window)
        expanded = false
    }

    /// Open a browser window on a specific tab: switch the tab first (works on any desktop), then bring it up.
    func focus(_ window: WindowItem, tab index: Int) {
        expanded = false
        let svc = windowService
        DispatchQueue.global(qos: .userInitiated).async {      // not windowQueue: a running scan must not delay the click
            svc.selectTab(window, index: index)
            DispatchQueue.main.async { svc.focus(window) }
        }
    }

    /// Jump to the window of a session: VS Code window whose title contains the project folder,
    /// otherwise a terminal window mentioning it, otherwise the app the session runs in.
    func focus(_ session: AgentSession) {
        unseen.remove(session.id)
        expanded = false
        let svc = windowService
        windowQueue.async {
            let all = svc.listWindows()
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.focus(session, among: all) } }
        }
    }

    private func focus(_ session: AgentSession, among all: [WindowItem]) {
        let folder = session.project.lowercased()
        let vscode = all.filter { $0.bundleID == "com.microsoft.VSCode" }
        let terminals = all.filter { ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"].contains($0.bundleID ?? "") }
        let preferVSCode = session.entrypoint != "cli"
        let groups = preferVSCode ? [vscode, terminals, all] : [terminals, vscode, all]
        for g in groups {
            // VS Code: exact folder match first (the parsed folder), then any title containing it
            if let w = g.first(where: { $0.bundleID == WindowService.vscode && $0.primary.lowercased() == folder })
                ?? g.first(where: { !$0.title.isEmpty && $0.title.lowercased().contains(folder) }) {
                windowService.focus(w); return
            }
        }
        // no title match (e.g. no Accessibility permission): activate the app at least
        let bundle = session.entrypoint == "claude-desktop" ? "com.anthropic.claudefordesktop"
            : (preferVSCode ? "com.microsoft.VSCode" : "com.apple.Terminal")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate()
        }
    }

    func unloadModel() {
        guard !unloading else { return }
        unloading = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.lms.unloadAll()
            self.lmstudio = await self.lms.status()
            self.unloading = false
        }
    }
}
