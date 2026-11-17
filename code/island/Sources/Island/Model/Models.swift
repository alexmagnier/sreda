// Shared data contract between services (Services/) and UI (UI/, App/).
// Services produce these value types; AppState publishes them; views only read them.
import AppKit
import Foundation

enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4
}

enum ThermalLevel: Sendable {
    case nominal, fair, serious, critical

    init(_ s: ProcessInfo.ThermalState) {
        switch s {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var label: String {
        switch self {
        case .nominal: return "норма"
        case .fair: return "тёплый"
        case .serious: return "горячий"
        case .critical: return "перегрев"
        }
    }
}

struct SystemSnapshot: Sendable, Equatable {
    var memoryUsedBytes: UInt64 = 0          // Activity Monitor "Memory Used": app + wired + compressed
    var memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memoryCompressedBytes: UInt64 = 0
    var memoryPressure: MemoryPressure = .normal
    var cpuPercent: Double? = nil            // 0…100, nil until two samples exist
    var gpuPercent: Double? = nil            // 0…100, nil if IOKit has no value
    var thermal: ThermalLevel = .nominal
    var diskFreeBytes: UInt64? = nil

    /// "Hot" hint for the pill: GPU busy or the Mac reports heat.
    var isHot: Bool { (gpuPercent ?? 0) > 60 || thermal == .serious || thermal == .critical }
}

struct ProcessRow: Identifiable, Sendable, Equatable {
    let id: pid_t
    let name: String
    let cpuPercent: Double                   // % of ONE core (like Activity Monitor), may exceed 100
    let memoryBytes: UInt64                  // phys_footprint
}

struct WindowTab: Identifiable, Sendable, Equatable {
    let id: Int                              // position in the window's tab bar, 0-based
    let title: String
    let isActive: Bool
}

struct WindowItem: Identifiable, Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    var title: String                        // raw window title, "" = unknown (no Accessibility permission)
    let spaceIndex: Int?                     // 1-based desktop number on its display, 0 = full screen, nil = unknown
    let isOnScreen: Bool
    var isMinimized = false
    /// Main line of the row: VS Code → project folder, browser → active tab, otherwise the title. "" = unknown.
    var primary = ""
    /// Second line: VS Code → open file, browser → site · N tabs.
    var secondary: String? = nil
    /// Chip for the local-model VS Code windows: «локально» / «лаборатория».
    var badge: String? = nil
    /// Browser tabs (Safari, Chromium browsers), in tab-bar order.
    var tabs: [WindowTab] = []
    /// Tooltip: full folder path or the full title.
    var hint: String? = nil
}

enum AgentState: String, Codable, Sendable, CaseIterable {
    case working, waiting, idle, error

    var label: String {
        switch self {
        case .working: return "работает"
        case .waiting: return "ждёт тебя"
        case .idle: return "готов — можно дать задачу"
        case .error: return "ошибка"
        }
    }
}

struct AgentSession: Identifiable, Sendable, Equatable {
    // Source of truth: Claude Code's own ~/.claude/sessions/<pid>.json (status busy|idle, liveness by pid)
    // + the hook overlay ~/.claude/island/waiting/<sessionId>.json (waiting for permission/answer, errors).
    let id: String                           // Claude Code sessionId
    let pid: Int32
    let name: String                         // Claude Code session name ("landing-03") — distinguishes 2 sessions in one folder
    let project: String                      // basename of cwd
    let cwd: String
    let entrypoint: String                   // "claude-vscode", "cli", "claude-desktop", …
    let state: AgentState
    let since: Date                          // when the current state began
    let message: String?                     // "нужно разрешение: Bash" etc. (never prompts / tool data)

    var clientLabel: String {
        switch entrypoint {
        case "claude-vscode": return "VS Code"
        case "claude-desktop": return "Claude Desktop"
        case "cli": return "терминал"
        default: return entrypoint
        }
    }
}

struct LMStudioStatus: Sendable, Equatable {
    var serverUp = false
    var loadedModels: [String] = []
}

struct PermissionStatus: Sendable, Equatable {
    var accessibility = false
    var screenRecording = false
}

enum PanelTab: String, CaseIterable, Identifiable {
    case agents = "Агенты", windows = "Окна", system = "Система"
    var id: String { rawValue }
}

// MARK: - Service interfaces (implemented in Services/)

protocol SystemStatsProviding: AnyObject {
    /// Cheap (microseconds): used/total/compressed memory + pressure level.
    func sampleMemory() -> (used: UInt64, total: UInt64, compressed: UInt64, pressure: MemoryPressure)
    /// CPU busy % since the previous call (nil on first call).
    func sampleCPU() -> Double?
    /// GPU "Device Utilization %" from IOAccelerator, nil if unavailable.
    func sampleGPU() -> Double?
    func thermal() -> ThermalLevel
    func diskFree() -> UInt64?
}

protocol ProcessSampling: AnyObject {
    /// Top processes by CPU (delta since previous call) and by memory footprint.
    func sample(limit: Int) -> (byCPU: [ProcessRow], byMemory: [ProcessRow])
}

protocol WindowProviding: AnyObject, Sendable {
    /// Real app windows on all Spaces, apps sorted: VS Code, browsers, terminals first. Slow on first call
    /// (up to ~1 s): call off the main thread. Thread-safe.
    func listWindows() -> [WindowItem]
    /// Bring the window to front, switching Space if needed. Returns false if it could only activate the app.
    @discardableResult func focus(_ window: WindowItem) -> Bool
    /// Switch the browser window to tab `index` (does not bring the window to front). Thread-safe.
    @discardableResult func selectTab(_ window: WindowItem, index: Int) -> Bool
}

protocol SessionWatching: AnyObject {
    /// Starts watching status directories; calls onChange on the main queue with the full current list.
    func start(onChange: @escaping ([AgentSession]) -> Void)
    func stop()
    func reload() -> [AgentSession]
}

protocol LMStudioControlling: AnyObject {
    func status() async -> LMStudioStatus
    /// `lms unload --all`; returns true on success.
    func unloadAll() async -> Bool
}
