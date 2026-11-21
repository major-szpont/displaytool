import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var monitors: [MonitorController] = []
    /// Increments on every discovery so a slow, stale discovery cannot overwrite a newer one.
    private var discoveryID = 0
    private var launchItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Display brightness")
        icon?.isTemplate = true
        item.button?.image = icon
        item.menu = menu
        statusItem = item

        menu.delegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSWorkspace.didWakeNotification, object: nil)

        rediscover()
    }

    @objc private func displaysChanged() {
        // After a wake or a hot-plug the display can come back with new service objects.
        // Wait briefly for the hardware to settle, then look again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.rediscover()
        }
    }

    private func rediscover() {
        discoveryID += 1
        let id = discoveryID
        let screens = ScreenInfo.externalScreens()  // AppKit access stays on the main thread

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = MonitorDiscovery.discover(screens: screens)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, id == self.discoveryID else { return }
                self.monitors = found
                self.rebuildMenu()
                found.forEach { $0.refresh() }
            }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if monitors.isEmpty {
            let none = NSMenuItem(title: "No external display with DDC/CI found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        for monitor in monitors {
            let item = NSMenuItem()
            item.view = MonitorRowView(controller: monitor)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(minimumMenuItem())

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = self
        launchItem = launch
        menu.addItem(launch)
        updateLaunchItem()

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshAll), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DisplayTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func updateLaunchItem() {
        launchItem?.state = LaunchAtLogin.isRegistered ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let register = !LaunchAtLogin.isRegistered
        do {
            try LaunchAtLogin.setRegistered(register)
        } catch {
            NSLog("DisplayTool: could not change launch at login: %@", error.localizedDescription)
            showAlert("Could not change Launch at Login", detail: error.localizedDescription)
        }
        updateLaunchItem()
        if register && LaunchAtLogin.needsApproval {
            LaunchAtLogin.openLoginItemsSettings()
        }
    }

    private func showAlert(_ message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func minimumMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Minimum brightness", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for preset in Safety.minimumPresets {
            let item = NSMenuItem(title: "\(preset)%", action: #selector(setMinimum(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset
            item.state = preset == Settings.minimumPercent ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func setMinimum(_ sender: NSMenuItem) {
        Settings.minimumPercent = sender.tag
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }

    @objc private func refreshAll() {
        rediscover()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Read only. Opening the menu never sends a brightness value.
        monitors.forEach { $0.refresh() }
        // The user can change the login item in System Settings, so re-read it each time.
        updateLaunchItem()
    }
}
