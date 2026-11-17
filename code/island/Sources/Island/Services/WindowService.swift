import AppKit
import ApplicationServices
import CoreGraphics

/// Real app windows on all desktops and what is inside them (VS Code folder + file, browser tabs).
///
/// Source of truth for "is this a real window": Accessibility (AX). CGWindowList alone also returns invisible
/// helper windows (Safari kept 3 of them next to 1 real window; CursorUIViewService — 17), which showed up as
/// «Окно 1…N». AX lists only real windows, gives titles without the Screen Recording permission and reaches
/// tab bars. kAXWindowsAttribute covers the current desktop only, so windows on other desktops are found by
/// walking AX element ids (`scan`, the AltTab technique) and cached by CG window id.
///
/// Thread-safe: AppState calls it from a background queue; `focus` comes from the main thread.
final class WindowService: WindowProviding, @unchecked Sendable {
    private let selfPid = getpid()
    private let listLock = NSLock()        // one listWindows at a time
    private let stateLock = NSLock()       // guards `elements` (short critical sections only)
    /// AX window elements by CG window id. An element stays valid while its window exists, on any desktop.
    private var elements: [CGWindowID: AXUIElement] = [:]
    /// Element-id scan progress per app. Touched only under listLock.
    private var scans: [pid_t: Scan] = [:]
    private struct Scan { var unknown: Set<CGWindowID>; var next: UInt64; var complete: Bool }

    /// Element ids grow over an app's life (a day-old VS Code window had id 14976). 40k ids ≈ 0.5 s (VS Code)
    /// to 2 s (Safari), spread over several refreshes by the budgets below and cached afterwards.
    private static let scanLimit: UInt64 = 40_000
    private static let scanBudgetPerApp: TimeInterval = 0.5
    private static let scanBudgetTotal: TimeInterval = 1.2

    private static let excludedNames: Set<String> = [
        "Dock", "Window Server", "Control Center", "Notification Center", "Spotlight", "loginwindow", "Island", "Остров",
    ]
    static let vscode = "com.microsoft.VSCode"
    static let browsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
                                        "company.thebrowser.Browser", "org.mozilla.firefox",
                                        "ru.yandex.desktop.yandex-browser", "com.microsoft.edgemac", "com.brave.Browser"]
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                         "com.mitchellh.ghostty"]

    init() {
        // A hung app must not freeze the list: every AX call gives up after 0.3 s (system-wide default).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }

    private static func rank(_ bundle: String?) -> Int {
        guard let b = bundle else { return 3 }
        if b == vscode { return 0 }
        if browsers.contains(b) { return 1 }
        if terminals.contains(b) { return 2 }
        return 3
    }

    // MARK: list

    private struct Candidate {
        let wid: CGWindowID, pid: pid_t, name: String, bundle: String?, cgTitle: String, onScreen: Bool, space: Int?
    }

    func listWindows() -> [WindowItem] {
        listLock.lock(); defer { listLock.unlock() }
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let trusted = AXIsProcessTrusted()
        let cgTitles = CGPreflightScreenCaptureAccess()
        let spaceMap = SkyLight.spaceIndexMap()

        var apps: [pid_t: (name: String, bundle: String?, hidden: Bool)?] = [:]
        var cands: [Candidate] = []
        for w in info {
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != selfPid,
                  (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  ((b["Width"] as? NSNumber)?.doubleValue ?? 0) > 50,
                  ((b["Height"] as? NSNumber)?.doubleValue ?? 0) > 50 else { continue }
            let app: (name: String, bundle: String?, hidden: Bool)?
            if let c = apps[pid] { app = c } else {
                // Only apps with a Dock icon: background services (CursorUIViewService, Open and Save Panel
                // Service, AutoFill, Wi-Fi…) own invisible layer-0 windows.
                let r = NSRunningApplication(processIdentifier: pid)
                let v = r.flatMap { $0.activationPolicy == .regular
                    ? ($0.localizedName ?? (w[kCGWindowOwnerName as String] as? String) ?? "?", $0.bundleIdentifier, $0.isHidden)
                    : nil }
                apps[pid] = .some(v)
                app = v
            }
            guard let app, !Self.excludedNames.contains(app.name) else { continue }
            let spaces = SkyLight.spaces(forWindow: wid)
            // On no desktop at all = ordered-out helper (Chrome, Zoom, Keynote… keep several). Cheap and needs no
            // permission. A hidden app's (⌘H) windows are on no desktop too: those are left to the AX check.
            if let spaces, spaces.isEmpty, !app.hidden { continue }
            var space: Int?
            if let map = spaceMap, let sid = spaces?.first { space = map[sid] }
            cands.append(Candidate(wid: wid, pid: pid, name: app.name, bundle: app.bundle,
                                   cgTitle: (w[kCGWindowName as String] as? String) ?? "",
                                   onScreen: (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                                   space: space))
        }

        let alive = Set(cands.map(\.wid))
        stateLock.lock(); elements = elements.filter { alive.contains($0.key) }; stateLock.unlock()
        let pids = Set(cands.map(\.pid))
        scans = scans.filter { pids.contains($0.key) }

        var budget = Self.scanBudgetTotal
        var items: [WindowItem] = []
        // VS Code and browsers first: they get the scan budget before everything else
        let byPid = Dictionary(grouping: cands, by: \.pid)
            .sorted { (Self.rank($0.value[0].bundle), $0.key) < (Self.rank($1.value[0].bundle), $1.key) }
        for (pid, list) in byPid {
            var scanIncomplete = false
            if trusted {
                collectCurrentDesktop(pid: pid)
                let unknown = Set(list.map(\.wid)).subtracting(knownIDs())
                if unknown.isEmpty { scans[pid] = nil }
                else { scanIncomplete = !scan(pid: pid, unknown: unknown, budget: &budget) }
            }
            for c in list {
                let el = element(c.wid)
                if trusted {
                    // Not found by AX = helper window. Exception: the scan has not finished yet and CG knows a
                    // title (Screen Recording granted) — keep it until the scan decides.
                    if el == nil && !(scanIncomplete && !c.cgTitle.isEmpty) { continue }
                } else if cgTitles && c.cgTitle.isEmpty {
                    continue                     // titles are readable, so an untitled window is a helper
                }
                var item = WindowItem(id: c.wid, pid: pid, appName: c.name, bundleID: c.bundle, title: c.cgTitle,
                                      spaceIndex: c.space, isOnScreen: c.onScreen)
                if let el { describe(&item, el) } else { item.primary = item.title }
                items.append(item)
            }
        }
        return items.sorted {
            let (ra, rb) = (Self.rank($0.bundleID), Self.rank($1.bundleID))
            if ra != rb { return ra < rb }
            if $0.appName != $1.appName { return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            if ($0.spaceIndex ?? 99) != ($1.spaceIndex ?? 99) { return ($0.spaceIndex ?? 99) < ($1.spaceIndex ?? 99) }
            return $0.primary.localizedCaseInsensitiveCompare($1.primary) == .orderedAscending
        }
    }

    // MARK: AX window discovery

    private func element(_ wid: CGWindowID) -> AXUIElement? {
        stateLock.lock(); defer { stateLock.unlock() }
        return elements[wid]
    }

    private func knownIDs() -> Set<CGWindowID> {
        stateLock.lock(); defer { stateLock.unlock() }
        return Set(elements.keys)
    }

    private func remember(_ e: AXUIElement) {
        guard Self.isRealWindow(e), let wid = SkyLight.windowID(of: e) else { return }
        stateLock.lock(); elements[wid] = e; stateLock.unlock()
    }

    private static func isRealWindow(_ e: AXUIElement) -> Bool {
        let sr = AX.string(e, kAXSubroleAttribute)
        return sr == kAXStandardWindowSubrole || sr == kAXDialogSubrole
    }

    /// Windows of the app on the current desktop (and minimized ones): cheap, one AX call.
    private func collectCurrentDesktop(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        for w in AX.elements(app, kAXWindowsAttribute) { remember(w) }
    }

    /// Walks AX element ids of the app until all `unknown` windows are found or the id range is exhausted.
    /// Resumes where it stopped on the next call while the set of unknown windows stays the same.
    /// Returns true when the scan is complete (unknown windows that remain are helper windows).
    private func scan(pid: pid_t, unknown: Set<CGWindowID>, budget: inout TimeInterval) -> Bool {
        guard SkyLight.remoteElementsAvailable else { return true }
        var s = scans[pid] ?? Scan(unknown: unknown, next: 0, complete: false)
        if s.unknown != unknown { s = Scan(unknown: unknown, next: 0, complete: false) }
        defer { scans[pid] = s }
        if s.complete { return true }
        guard budget > 0.02 else { return false }
        let start = Date()
        let limit = min(Self.scanBudgetPerApp, budget)
        var remaining = unknown
        while s.next < Self.scanLimit {
            if Date().timeIntervalSince(start) > limit { break }
            let id = s.next
            s.next += 1
            guard let e = SkyLight.remoteElement(pid: pid, elementID: id) else { continue }
            var raw: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &raw)
            if err == .cannotComplete { s.complete = true; break }        // app hung or quit: stop, keep what we have
            guard err == .success, let sr = raw as? String,
                  sr == kAXStandardWindowSubrole || sr == kAXDialogSubrole,
                  let wid = SkyLight.windowID(of: e) else { continue }
            stateLock.lock(); elements[wid] = e; stateLock.unlock()
            remaining.remove(wid)
            if remaining.isEmpty { s.complete = true; break }
        }
        if s.next >= Self.scanLimit { s.complete = true }
        budget -= Date().timeIntervalSince(start)
        return s.complete
    }

    // MARK: what is inside

    private func describe(_ item: inout WindowItem, _ el: AXUIElement) {
        if let t = AX.string(el, kAXTitleAttribute), !t.isEmpty { item.title = t }
        item.isMinimized = AX.bool(el, kAXMinimizedAttribute) ?? false
        let bundle = item.bundleID ?? ""
        if bundle == Self.vscode {
            let v = Self.parseVSCode(item.title, document: AX.string(el, kAXDocumentAttribute))
            item.primary = v.folder ?? v.file ?? (v.badge != nil ? "папка не открыта" : item.title)
            item.secondary = v.folder != nil ? v.file : nil
            item.badge = v.badge
            item.hint = v.path ?? item.title
        } else if Self.browsers.contains(bundle) {
            let bar = Self.tabBar(el)
            item.tabs = bar.tabs.enumerated().map { WindowTab(id: $0.offset, title: $0.element.title, isActive: $0.element.active) }
            let active = item.tabs.first(where: \.isActive)?.title
            item.primary = (active?.isEmpty == false ? active : nil) ?? item.title
            item.secondary = bar.url.flatMap(Self.host)      // the tab count is a separate chip in the row
            item.hint = item.title
        } else {
            item.primary = item.title
            item.hint = item.title.isEmpty ? nil : item.title
        }
    }

    /// VS Code titles: "file — folder", "● file — folder" (unsaved), "folder", and the local-model windows
    /// "🔒 ЛОКАЛЬНО · без интернета · folder — file" / "🧪 ЛАБОРАТОРИЯ · интернет · folder — file".
    static func parseVSCode(_ title: String, document: String?) -> (folder: String?, file: String?, badge: String?, path: String?) {
        var badge: String?
        var folder: String?
        var file: String?
        let clean = { (s: String) -> String in
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("● ") { t.removeFirst(2) }
            return t
        }
        if title.hasPrefix("🔒") || title.hasPrefix("🧪") {
            badge = title.hasPrefix("🔒") ? "локально" : "лаборатория"
            let parts = title.components(separatedBy: " · ")
            let tail = parts.count >= 3 ? parts.dropFirst(2).joined(separator: " · ") : ""
            let p = tail.components(separatedBy: " — ").map(clean).filter { !$0.isEmpty }
            folder = p.first
            file = p.count > 1 ? p.dropFirst().joined(separator: " — ") : nil
        } else {
            let p = title.components(separatedBy: " — ").map(clean)
                .filter { !$0.isEmpty && $0 != "Visual Studio Code" && $0 != "Code" }
            if p.count >= 2 {
                folder = p.last
                file = p.dropLast().joined(separator: " — ")
            } else if let only = p.first {
                if document != nil { file = only } else { folder = only }
            }
        }
        // Full folder path from the open file: the nearest parent directory named like the folder.
        var path: String?
        if let folder, let doc = document, let url = URL(string: doc), url.isFileURL {
            var dir = url.deletingLastPathComponent()
            while dir.path != "/" {
                if dir.lastPathComponent == folder { path = (dir.path as NSString).abbreviatingWithTildeInPath; break }
                dir = dir.deletingLastPathComponent()
            }
        }
        return (folder, file, badge, path)
    }

    /// Tab buttons and the address field of a browser window. Bounded walk: skips page content (web areas,
    /// scroll areas, split groups) so a heavy page costs nothing.
    private static func tabBar(_ window: AXUIElement) -> (tabs: [(title: String, active: Bool, el: AXUIElement)], url: String?) {
        var tabs: [(title: String, active: Bool, el: AXUIElement)] = []
        var url: String?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        let skip: Set<String> = ["AXWebArea", "AXScrollArea", "AXSplitGroup", "AXTable", "AXOutline", "AXList"]
        while !queue.isEmpty, visited < 400 {
            let (e, depth) = queue.removeFirst()
            visited += 1
            let role = AX.string(e, kAXRoleAttribute) ?? ""
            if role == "AXRadioButton", AX.string(e, kAXSubroleAttribute) == "AXTabButton" {
                let title = AX.string(e, kAXTitleAttribute) ?? AX.string(e, kAXDescriptionAttribute) ?? ""
                tabs.append((title, (AX.number(e, kAXValueAttribute) ?? 0) == 1, e))
                continue
            }
            if role == "AXTextField", url == nil, let v = AX.string(e, kAXValueAttribute), looksLikeURL(v) {
                url = v
                continue
            }
            if depth >= 6 || skip.contains(role) { continue }
            for k in AX.elements(e, kAXChildrenAttribute) { queue.append((k, depth + 1)) }
        }
        return (tabs, url)
    }

    private static func looksLikeURL(_ s: String) -> Bool {
        !s.contains(" ") && s.contains(".") && s.count < 2048
    }

    static func host(_ s: String) -> String? {
        let u = URL(string: s.contains("://") ? s : "https://" + s)
        guard var h = u?.host, !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func tabsWord(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? "вкладка" : ((2...4).contains(m10) && !(12...14).contains(m100) ? "вкладки" : "вкладок")
        return "\(n) \(w)"
    }

    // MARK: actions

    @discardableResult
    func selectTab(_ window: WindowItem, index: Int) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if element(window.id) == nil { collectCurrentDesktop(pid: window.pid) }
        guard let el = element(window.id) else { return false }
        let tabs = Self.tabBar(el).tabs
        guard tabs.indices.contains(index) else { return false }
        return AXUIElementPerformAction(tabs[index].el, kAXPressAction as CFString) == .success
    }

    @discardableResult
    func focus(_ window: WindowItem) -> Bool {
        guard SkyLight.windowFocusAvailable, AXIsProcessTrusted() else {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            return false
        }
        var target = element(window.id)
        if target == nil {
            let axApp = AXUIElementCreateApplication(window.pid)
            target = AX.elements(axApp, kAXWindowsAttribute).first { SkyLight.windowID(of: $0) == window.id }
        }
        if let t = target, AX.bool(t, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(t, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard SkyLight.focusWindow(pid: window.pid, windowID: window.id) else {
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            return false
        }
        if let t = target { AXUIElementPerformAction(t, kAXRaiseAction as CFString) }
        return true
    }
}

/// Small typed wrappers over AXUIElementCopyAttributeValue.
enum AX {
    static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var r: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &r) == .success ? r : nil
    }
    static func string(_ e: AXUIElement, _ attr: String) -> String? { value(e, attr) as? String }
    static func bool(_ e: AXUIElement, _ attr: String) -> Bool? { (value(e, attr) as? NSNumber)?.boolValue }
    static func number(_ e: AXUIElement, _ attr: String) -> Int? { (value(e, attr) as? NSNumber)?.intValue }
    static func elements(_ e: AXUIElement, _ attr: String) -> [AXUIElement] { (value(e, attr) as? [AXUIElement]) ?? [] }
}
