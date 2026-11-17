import SwiftUI

struct WindowsTab: View {
    @ObservedObject var state: AppState
    /// Browser windows whose tab list is unfolded.
    @State private var open: Set<CGWindowID> = []
    @Environment(\.islandOffscreen) private var offscreen

    /// Offscreen debug render has no clicks: show the first browser window unfolded.
    private func isOpen(_ w: WindowItem) -> Bool {
        open.contains(w.id) || (offscreen && w.id == state.windows.first(where: { $0.tabs.count > 1 })?.id)
    }

    private var groups: [(name: String, pid: pid_t, items: [WindowItem])] {
        var order: [String] = []
        var map: [String: [WindowItem]] = [:]
        for w in state.windows {
            let key = w.bundleID == WindowService.vscode ? "VS Code" : w.appName
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(w)
        }
        return order.map { (name: $0, pid: map[$0]![0].pid, items: map[$0]!) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !state.permissions.accessibility {
                PermissionBanner(
                    text: "Разреши «Универсальный доступ»: покажу, какая папка открыта в каждом окне VS Code и какие вкладки в Safari, и смогу переключать окна",
                    button: "Разрешить") {
                    Permissions.requestAccessibility(); state.refreshPermissions()
                }
            }
            if state.windows.isEmpty {
                if state.windowsLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Смотрю окна на всех рабочих столах…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                } else {
                    Text("Окон не найдено").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.top, 40)
                }
            } else {
                IslandScroll {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.name) { g in group(g) }
                    }
                }
            }
        }
    }

    private func group(_ g: (name: String, pid: pid_t, items: [WindowItem])) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                AppIcon(pid: g.pid, size: 16)
                Text(g.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if g.items.count > 1 {
                    Text(Self.windowsWord(g.items.count)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 2)
            ForEach(Array(g.items.enumerated()), id: \.element.id) { idx, w in
                HStack(spacing: 4) {
                    Button { state.focus(w) } label: { WindowRow(window: w, index: idx + 1) }
                        .buttonStyle(RowButtonStyle())
                        .help(w.hint ?? "")
                    if w.tabs.count > 1 {
                        TabsToggle(count: w.tabs.count, isOpen: isOpen(w)) {
                            if open.contains(w.id) { open.remove(w.id) } else { open.insert(w.id) }
                        }
                    }
                }
                if isOpen(w) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(w.tabs) { t in
                            Button { state.focus(w, tab: t.id) } label: { TabRow(tab: t) }
                                .buttonStyle(RowButtonStyle())
                                .help(t.title)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    static func windowsWord(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? "окно" : ((2...4).contains(m10) && !(12...14).contains(m100) ? "окна" : "окон")
        return "· \(n) \(w)"
    }
}

struct WindowRow: View {
    let window: WindowItem
    let index: Int

    private var details: String? {
        var parts: [String] = []
        if let s = window.secondary, !s.isEmpty { parts.append(s) }
        if window.isMinimized { parts.append("свёрнуто") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(window.primary.isEmpty ? "Окно \(index)" : window.primary)
                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let b = window.badge {
                        Text(b)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(b == "локально" ? Color.green : Color.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background((b == "локально" ? Color.green : Color.orange).opacity(0.16), in: .capsule)
                            .fixedSize()
                    }
                }
                if let d = details {
                    Text(d).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let s = window.spaceIndex {
                Text(s == 0 ? "весь экран" : "стол \(s)")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.09), in: .capsule)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .padding(.leading, 22)
    }
}

/// "9 вкладок ⌄" chip that unfolds the tab list of a browser window.
struct TabsToggle: View {
    let count: Int
    let isOpen: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(WindowService.tabsWord(count)).font(.system(size: 10.5, weight: .medium))
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(isOpen ? 0.14 : 0.08), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.trailing, 10)
        .help(isOpen ? "Свернуть вкладки" : "Показать вкладки этого окна")
    }
}

struct TabRow: View {
    let tab: WindowTab
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tab.isActive ? Color.accentColor : Color.primary.opacity(0.25))
                .frame(width: 5, height: 5)
            Text(tab.title.isEmpty ? "Вкладка \(tab.id + 1)" : tab.title)
                .font(.system(size: 11.5, weight: tab.isActive ? .medium : .regular))
                .foregroundStyle(tab.isActive ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if tab.isActive {
                Text("открыта сейчас").font(.system(size: 9.5)).foregroundStyle(.tertiary).fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 3.5)
        .padding(.leading, 34)
    }
}
