import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState!
    var controller: PanelController!
    var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = makeAppState()
        state.start()
        controller = PanelController(state: state)
        statusItem = StatusItemController(state: state)
    }

    /// Opened again from Spotlight / Finder / `open` while already running: show it, even over a mirrored screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state.showNow(expand: true)
        return false
    }
}

// MARK: debug rendering: Island --render <out.png>  ->  out-pill.png, out-agents.png, out-windows.png, out-system.png

@MainActor
func renderDebug(base: String) {
    let dir = (base as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let stem = (base as NSString).deletingPathExtension
    let state = makeFakeAppState(realWindows: ProcessInfo.processInfo.environment["ISLAND_RENDER_REAL"] == "1")
    state.start()
    state.expanded = true

    func save<V: View>(_ v: V, _ name: String) {
        let content = v
            .padding(14)
            .background(LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.4, blue: 0.6)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.islandOffscreen, true)
            .environment(\.colorScheme, name.hasSuffix("light") ? .light : .dark)
        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(name)"); return }
        let path = "\(stem)-\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print(path)
    }

    save(GlassEffectContainer { PillView(state: state, notchWidth: 185, height: 32) }, "pill")
    for (t, n) in [(PanelTab.agents, "agents"), (.windows, "windows"), (.system, "system")] {
        state.tab = t
        if t == .windows {
            state.loadWindowsNow()
            if ProcessInfo.processInfo.environment["ISLAND_RENDER_REAL"] == "1" {
                for w in state.windows {
                    print("ROW", w.appName, "|", w.primary, "|", w.secondary ?? "", "|", w.badge ?? "", "| tabs", w.tabs.count,
                          "| space", w.spaceIndex.map(String.init) ?? "-", w.isMinimized ? "| min" : "")
                }
            }
        }
        save(GlassEffectContainer {
            PanelView(state: state).frame(width: PanelMetrics.panelWidth, height: PanelMetrics.panelHeight)
        }, n)
        save(GlassEffectContainer {
            PanelView(state: state).frame(width: PanelMetrics.panelWidth, height: PanelMetrics.panelHeight)
        }, n + "-light")
    }
}

let args = CommandLine.arguments
let app = NSApplication.shared
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    MainActor.assumeIsolated { renderDebug(base: args[i + 1]) }
    exit(0)
}
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
