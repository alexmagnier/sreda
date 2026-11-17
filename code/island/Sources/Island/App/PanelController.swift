import AppKit
import Combine
import SwiftUI

/// Owns the window: geometry around the notch, expand/collapse, and WHEN the island is visible.
/// Hidden automatically while the screen is mirrored (TV / AirPlay / projector), over full-screen
/// apps (collectionBehavior), and when the user chose "Скрыть на час".
@MainActor
final class PanelController {
    private let state: AppState
    private let panel = IslandPanel()
    private var pillGlass: NSGlassEffectView!
    private var pillHost: NSView!
    private var panelHost: NSView?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var globalClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var unhideTimer: Timer?
    private var lastMirrored = false

    private var notchWidth: CGFloat = 0
    private var menuBarHeight: CGFloat = 32
    private var pillWidth: CGFloat { notchWidth + 2 * PillView.sideWidth }

    init(state: AppState) {
        self.state = state
        build()

        state.$expanded.removeDuplicates().sink { [weak self] exp in
            DispatchQueue.main.async { self?.expandedChanged(exp) }
        }.store(in: &cancellables)
        state.$hiddenUntil.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        }.store(in: &cancellables)
        state.$forceVisible.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateVisibility() }
        }.store(in: &cancellables)
        lastMirrored = screenIsMirrored

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.build() }      // also fires when mirroring starts/stops
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.build() }
            })
    }

    // MARK: visibility

    /// Screen mirrored to a TV/projector or AirPlay: the user is presenting or watching — stay away.
    private var screenIsMirrored: Bool {
        CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
    }

    private func updateVisibility() {
        unhideTimer?.invalidate(); unhideTimer = nil
        let mirrored = screenIsMirrored
        if mirrored != lastMirrored {          // TV connected/disconnected: drop the manual "show anyway"
            lastMirrored = mirrored
            if state.forceVisible { state.forceVisible = false }
        }
        var hide = mirrored && !state.forceVisible
        if let until = state.hiddenUntil {
            if until > Date() {
                hide = true
                unhideTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow + 0.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.state.hiddenUntil = nil }
                }
            } else {
                state.hiddenUntil = nil
            }
        }
        if hide {
            state.expanded = false
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: geometry & content

    private var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private func measureScreen() {
        guard let s = screen else { return }
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notchWidth = max(0, s.frame.width - l.width - r.width)
        } else {
            notchWidth = 0
        }
        let inset = s.safeAreaInsets.top
        menuBarHeight = inset > 0 ? inset : NSStatusBar.system.thickness
    }

    private func build() {
        measureScreen()
        guard let root = panel.contentView else { return }
        root.subviews.forEach { $0.removeFromSuperview() }
        panelHost = nil

        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: menuBarHeight))
        glass.cornerRadius = menuBarHeight / 2
        let host = FirstMouseHostingView(rootView:
            PillView(state: state, notchWidth: notchWidth, height: menuBarHeight, drawsGlass: false)
                .onTapGesture { [weak state] in state?.expanded.toggle() })
        host.sizingOptions = []
        glass.contentView = host
        pillGlass = glass
        pillHost = host
        root.addSubview(glass)

        if state.expanded { addPanelHost() }
        layout(expanded: state.expanded)
        updateVisibility()
    }

    private func addPanelHost() {
        guard panelHost == nil, let root = panel.contentView else { return }
        let host = FirstMouseHostingView(rootView:
            PanelView(state: state).frame(width: PanelMetrics.panelWidth, height: PanelMetrics.panelHeight))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.alphaValue = 0
        root.addSubview(host)
        panelHost = host
    }

    private func frame(expanded: Bool) -> NSRect {
        guard let s = screen else { return .zero }
        let w = expanded ? max(pillWidth, PanelMetrics.panelWidth) : pillWidth
        let h = expanded ? menuBarHeight + PanelMetrics.gap + PanelMetrics.panelHeight : menuBarHeight
        return NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h)
    }

    /// Window frame == visible shape (collapsed: exactly the pill), so clicks elsewhere reach the menu bar.
    private func layout(expanded: Bool) {
        let f = frame(expanded: expanded)
        panel.setFrame(f, display: true, animate: false)
        pillGlass.frame = NSRect(x: (f.width - pillWidth) / 2, y: f.height - menuBarHeight, width: pillWidth, height: menuBarHeight)
        pillHost.frame = pillGlass.bounds
        if let p = panelHost {
            p.frame = NSRect(x: (f.width - PanelMetrics.panelWidth) / 2, y: 0,
                             width: PanelMetrics.panelWidth, height: PanelMetrics.panelHeight)
        }
    }

    // MARK: expand / collapse

    private func expandedChanged(_ exp: Bool) {
        if exp {
            addPanelHost()
            layout(expanded: true)
            installMonitors()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panelHost?.animator().alphaValue = 1
            }
        } else {
            removeMonitors()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panelHost?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.state.expanded else { return }
                    self.panelHost?.removeFromSuperview()      // nothing rendered while collapsed
                    self.panelHost = nil
                    self.layout(expanded: false)
                }
            })
        }
    }

    private func installMonitors() {
        removeMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.state.expanded = false }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { DispatchQueue.main.async { self?.state.expanded = false } }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.state.expanded = false; return nil }
            return e
        }
    }

    private func removeMonitors() {
        for m in [globalClickMonitor, globalKeyMonitor, localKeyMonitor] { if let m { NSEvent.removeMonitor(m) } }
        globalClickMonitor = nil; globalKeyMonitor = nil; localKeyMonitor = nil
    }
}
