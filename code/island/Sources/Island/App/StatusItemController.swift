import AppKit

/// A static icon in the menu bar — the always-visible way back to the island, even while the pill hides
/// itself (TV mirroring, "Скрыть на час"). No live numbers here on purpose: nothing changes, nothing flickers.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(state: AppState) {
        self.state = state
        super.init()
        if let b = item.button {
            let img = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Остров")
            img?.isTemplate = true
            b.image = img
            b.toolTip = "Остров — островок с агентами и памятью"
        }
        menu.delegate = self
        item.menu = menu
        item.autosaveName = "local.claude-kit.island.menubar"
        item.isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            AppState.statusItemDebug = "visible=\(self.item.isVisible) frame=\(self.item.button?.window?.frame ?? .zero)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = state.counts
        let head = NSMenuItem(title: "Агенты: работают \(c.working) · готовы \(c.ready) · ждут тебя \(c.waiting)",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        add("Показать островок и панель", #selector(showPanel))
        if state.hiddenUntil != nil {
            add("Вернуть островок сейчас", #selector(showPill))
        }
        menu.addItem(.separator())
        add("Скрыть на час", #selector(hideHour))
        add("Скрыть до утра", #selector(hideMorning))
        menu.addItem(.separator())
        add("Выключить «Остров»", #selector(quit))
    }

    private func add(_ title: String, _ sel: Selector) {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    @objc private func showPanel() { state.showNow(expand: true) }
    @objc private func showPill() { state.showNow(expand: false) }
    @objc private func hideHour() { state.hide(for: 3600) }
    @objc private func hideMorning() { state.hideUntilMorning() }
    @objc private func quit() { NSApp.terminate(nil) }
}
