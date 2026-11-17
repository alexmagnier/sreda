import SwiftUI

private struct OffscreenKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// true when rendered via ImageRenderer (--render): Liquid Glass can't draw offscreen, use flat fills.
    var islandOffscreen: Bool {
        get { self[OffscreenKey.self] }
        set { self[OffscreenKey.self] = newValue }
    }
}

enum PanelMetrics {
    static let panelWidth: CGFloat = 460
    static let panelHeight: CGFloat = 520
    static let gap: CGFloat = 8
}

/// Root content of the NSPanel: pill on top, dropdown below when expanded.
struct IslandRootView: View {
    @ObservedObject var state: AppState
    let notchWidth: CGFloat
    let menuBarHeight: CGFloat

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: PanelMetrics.gap) {
                PillView(state: state, notchWidth: notchWidth, height: menuBarHeight)
                    .onTapGesture { state.expanded.toggle() }
                if state.expanded {
                    PanelView(state: state)
                        .frame(width: PanelMetrics.panelWidth, height: PanelMetrics.panelHeight)
                        .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: state.expanded)
    }
}

struct PanelView: View {
    @ObservedObject var state: AppState
    @Namespace private var tabNS
    @Environment(\.islandOffscreen) private var offscreen

    var body: some View {
        VStack(spacing: 10) {
            tabs
            Group {
                switch state.tab {
                case .agents: AgentsTab(state: state)
                case .windows: WindowsTab(state: state)
                case .system: SystemTab(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(12)
        .modifier(PanelBackground(offscreen: offscreen))
    }

    private var footer: some View {
        HStack {
            if state.tab == .windows {
                Button { state.refreshWindows() } label: {
                    Label("Обновить", systemImage: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            Button { state.hide(for: 3600) } label: {
                Text("Скрыть на час").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Островок спрячется на час и вернётся сам")
            Button { state.hideUntilMorning() } label: {
                Text("До утра").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Спрятать до 9:00. Вернуть раньше — значок островка в строке меню")
        }
        .padding(.horizontal, 6)
    }

    private var tabs: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(PanelTab.allCases) { t in
                    let selected = state.tab == t
                    Button { state.tab = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .modifier(TabBackground(offscreen: offscreen, selected: selected, id: t.rawValue, ns: tabNS))
                }
            }
        }
    }
}

private struct PanelBackground: ViewModifier {
    let offscreen: Bool
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        if offscreen {
            content.background((scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)).opacity(0.75), in: .rect(cornerRadius: 26))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
    }
}

private struct TabBackground: ViewModifier {
    let offscreen: Bool
    let selected: Bool
    let id: String
    let ns: Namespace.ID
    func body(content: Content) -> some View {
        if offscreen {
            content.background(selected ? Color.white.opacity(0.18) : Color.clear, in: .capsule)
        } else {
            content
                .glassEffect(selected ? .regular.interactive() : .clear, in: .capsule)
                .glassEffectID(id, in: ns)
        }
    }
}
