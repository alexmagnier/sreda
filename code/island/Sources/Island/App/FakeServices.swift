// In-memory fakes with realistic data. Used only when ISLAND_FAKE=1 / --render / temporary Composition.
import Foundation

final class FakeStats: SystemStatsProviding {
    func sampleMemory() -> (used: UInt64, total: UInt64, compressed: UInt64, pressure: MemoryPressure) {
        (33_500_000_000, 51_539_607_552, 4_200_000_000, .normal)
    }
    func sampleCPU() -> Double? { 23 }
    func sampleGPU() -> Double? { 71 }
    func thermal() -> ThermalLevel { .fair }
    func diskFree() -> UInt64? { 412_000_000_000 }
}

final class FakeProcesses: ProcessSampling {
    func sample(limit: Int) -> (byCPU: [ProcessRow], byMemory: [ProcessRow]) {
        let cpu: [(String, Double, UInt64)] = [("LM Studio Helper", 412.0, 21_000_000_000), ("Code Helper (Renderer)", 38.5, 1_400_000_000),
                   ("WindowServer", 22.0, 420_000_000), ("Google Chrome Helper", 14.2, 980_000_000),
                   ("claude", 9.8, 310_000_000), ("Telegram", 3.1, 540_000_000)]
        let mem: [(String, Double, UInt64)] = [("LM Studio Helper", 412.0, 21_000_000_000), ("Code Helper (Renderer)", 38.5, 1_400_000_000),
                   ("Google Chrome Helper", 14.2, 980_000_000), ("Telegram", 3.1, 540_000_000),
                   ("WindowServer", 22.0, 420_000_000), ("claude", 9.8, 310_000_000)]
        func rows(_ a: [(String, Double, UInt64)]) -> [ProcessRow] {
            a.enumerated().map { ProcessRow(id: pid_t(100 + $0.offset), name: $0.element.0, cpuPercent: $0.element.1, memoryBytes: $0.element.2) }
        }
        return (rows(cpu), rows(mem))
    }
}

final class FakeWindows: WindowProviding, @unchecked Sendable {
    func listWindows() -> [WindowItem] {
        let me = ProcessInfo.processInfo.processIdentifier
        func w(_ id: UInt32, _ app: String, _ bid: String, _ t: String, _ s: Int?,
               primary: String? = nil, secondary: String? = nil, badge: String? = nil, tabs: [String] = [],
               active: Int = 0, minimized: Bool = false) -> WindowItem {
            var item = WindowItem(id: id, pid: me, appName: app, bundleID: bid, title: t, spaceIndex: s, isOnScreen: true)
            item.primary = primary ?? t
            item.secondary = secondary
            item.badge = badge
            item.tabs = tabs.enumerated().map { WindowTab(id: $0.offset, title: $0.element, isActive: $0.offset == active) }
            item.isMinimized = minimized
            return item
        }
        let code = "com.microsoft.VSCode"
        return [
            w(1, "Code", code, "AppState.swift — mac-widget", 1, primary: "mac-widget", secondary: "AppState.swift"),
            w(2, "Code", code, "SPEC.md — crm-backend", 2, primary: "crm-backend", secondary: "SPEC.md"),
            w(3, "Code", code, "🔒 ЛОКАЛЬНО · без интернета · смета-клиента — выжимка.md", 3,
              primary: "смета-клиента", secondary: "выжимка.md", badge: "локально"),
            w(4, "Code", code, "🧪 ЛАБОРАТОРИЯ · интернет · Лаборатория", 3, primary: "Лаборатория", badge: "лаборатория"),
            w(5, "Safari", "com.apple.Safari", "Мои товары — CRM", 1, primary: "Мои товары — CRM",
              secondary: "crm.example.ru",
              tabs: ["Разбор для лидеров — Claude", "Horizon 3: portable monitor", "Мои товары — CRM",
                     "Документация", "Входящие — Почта"], active: 2),
            w(6, "Safari", "com.apple.Safari", "Anthropic Console", 4, primary: "Anthropic Console", secondary: "console.anthropic.com"),
            w(7, "Terminal", "com.apple.Terminal", "zsh — 120×32", 2),
            w(8, "Telegram", "ru.keepcoder.Telegram", "", 5),
            w(9, "LM Studio", "ai.elementlabs.lmstudio", "LM Studio", nil, minimized: true),
        ]
    }
    func focus(_ window: WindowItem) -> Bool { true }
    func selectTab(_ window: WindowItem, index: Int) -> Bool { true }
}

final class FakeSessions: SessionWatching {
    func list() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(id: "a", pid: 101, name: "landing-03", project: "mac-widget", cwd: "/x/mac-widget", entrypoint: "claude-vscode",
                         state: .working, since: now.addingTimeInterval(-180), message: nil),
            AgentSession(id: "b", pid: 102, name: "crm-backend-01", project: "crm-backend", cwd: "/x/crm-backend", entrypoint: "claude-vscode",
                         state: .waiting, since: now.addingTimeInterval(-45), message: "нужно разрешение: Bash"),
            AgentSession(id: "c", pid: 103, name: "content-02", project: "content-studio", cwd: "/x/content", entrypoint: "cli",
                         state: .idle, since: now.addingTimeInterval(-1500), message: nil),
        ]
    }
    func start(onChange: @escaping ([AgentSession]) -> Void) { onChange(list()) }
    func stop() {}
    func reload() -> [AgentSession] { list() }
}

final class FakeLMS: LMStudioControlling {
    func status() async -> LMStudioStatus { LMStudioStatus(serverUp: true, loadedModels: ["qwen3-coder-30b-a3b"]) }
    func unloadAll() async -> Bool { true }
}

@MainActor
func makeFakeAppState(realWindows: Bool = false) -> AppState {
    // realWindows: the debug render shows this Mac's actual windows (needs Accessibility for the rendering process)
    AppState(stats: FakeStats(), processes: FakeProcesses(), windows: realWindows ? WindowService() : FakeWindows(),
             sessions: FakeSessions(), lms: FakeLMS(),
             permissions: { realWindows ? Permissions.current() : PermissionStatus(accessibility: true, screenRecording: false) })
}
