// MainMenu.swift — limm VPN menubar controller
// Menu: status / toggle / ─── / Preferences / ─── / Configure / Servers / ─── / [Send Diagnostic Log / ─── /] Quit

import Cocoa
import ServiceManagement

let menuController = (NSApplication.shared.delegate as? AppDelegate)?.statusMenu.delegate as! MenuController

class MenuController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var statusItemClicked: (() -> Void)?
    let lock = NSLock()

    // IBOutlets kept for xib compatibility — most are hidden in awakeFromNib
    @IBOutlet var pacMode: NSMenuItem!
    @IBOutlet var manualMode: NSMenuItem!
    @IBOutlet var globalMode: NSMenuItem!
    @IBOutlet var statusMenu: NSMenu!
    @IBOutlet var toggleV2rayItem: NSMenuItem!
    @IBOutlet var v2rayStatusItem: NSMenuItem!
    @IBOutlet var serverItems: NSMenuItem!
    @IBOutlet var newVersionItem: NSMenuItem!
    @IBOutlet var routingMenu: NSMenuItem!

    // MARK: - Setup

    override func awakeFromNib() {
        super.awakeFromNib()
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        simplifyMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(configWindowWillClose(notification:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    // Dynamic "Send Diagnostic Log" menu item — shown only when checkin is enabled
    private lazy var sendLogMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Send Diagnostic Log",
                              action: #selector(sendDiagnosticLog(_:)),
                              keyEquivalent: "")
        item.target = self
        return item
    }()
    private lazy var sendLogSeparator = NSMenuItem.separator()

    // "Full Test..." — пошаговая диагностика, всегда доступна
    private lazy var fullTestMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Full Test...",
                              action: #selector(runFullTest(_:)),
                              keyEquivalent: "")
        item.target = self
        return item
    }()

    // Saved references for Preferences and Quit (set in simplifyMenu)
    private var prefsItem: NSMenuItem?
    private var quitItem:  NSMenuItem?

    /// Rebuild menu to: status / toggle / ─── / Preferences / ─── / Configure / Servers / ─── / [Send Diagnostic Log /] Full Test... / ─── / Quit
    private func simplifyMenu() {
        // Find Preferences and Quit before clearing
        for item in statusMenu.items {
            if let action = item.action {
                let sel = NSStringFromSelector(action)
                if sel == "openPreferenceGeneral:" { prefsItem = item }
                if sel == "quitClicked:"           { quitItem  = item }
            }
        }

        // Clear all items
        statusMenu.removeAllItems()

        rebuildMenu()

        // Apply initial labels
        setStatusOff()

        // Observe UserDefaults changes so menu updates when user toggles checkin in Prefs
        UserDefaults.standard.addObserver(self,
            forKeyPath: LimmConfig.checkinEnabledKey,
            options: [.new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == LimmConfig.checkinEnabledKey {
            DispatchQueue.main.async { self.rebuildMenu() }
        }
    }

    // "Configure..." — opens the server config window
    private lazy var configMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Configure...",
                              action: #selector(openConfig(_:)),
                              keyEquivalent: "")
        item.target = self
        return item
    }()

    // "Servers" — submenu with the server list
    private lazy var serversMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Servers", action: nil, keyEquivalent: "")
        return item
    }()

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        // 1. Status label
        statusMenu.addItem(v2rayStatusItem)
        // 2. Toggle
        statusMenu.addItem(toggleV2rayItem)
        // 3. Separator
        statusMenu.addItem(.separator())

        // 4. Preferences
        if let p = prefsItem { statusMenu.addItem(p) }
        statusMenu.addItem(.separator())

        // 5. Configure + Servers
        statusMenu.addItem(configMenuItem)
        serversMenuItem.submenu = getServerMenus()
        statusMenu.addItem(serversMenuItem)
        statusMenu.addItem(.separator())

        // 6. Diagnostic tools
        let checkinOn = UserDefaults.standard.bool(forKey: LimmConfig.checkinEnabledKey)
        if checkinOn {
            statusMenu.addItem(sendLogMenuItem)
        }
        statusMenu.addItem(fullTestMenuItem)
        statusMenu.addItem(.separator())

        // 7. Quit
        if let q = quitItem  { statusMenu.addItem(q) }
    }

    // MARK: - Status updates (rename "v2ray-core" → "limm VPN")

    func setStatusOff() {
        DispatchQueue.main.async {
            self.v2rayStatusItem.title = "limm VPN: Off"
            self.toggleV2rayItem.title = "Turn VPN On"
            if let button = self.statusItem.button {
                button.image = NSImage(named: NSImage.Name("IconOff"))
            }
            UserDefaults.setBool(forKey: .v2rayTurnOn, value: false)
        }
    }

    func setStatusOn(mode: RunMode) {
        DispatchQueue.main.async {
            self.v2rayStatusItem.title = "limm VPN: On"
            self.toggleV2rayItem.title = "Turn VPN Off"
            self.setModeIcon(mode: mode)
            UserDefaults.setBool(forKey: .v2rayTurnOn, value: true)
        }
    }

    func setModeIcon(mode: RunMode) {
        DispatchQueue.main.async {
            let iconName: String
            switch mode {
            case .global: iconName = "IconOnG"
            case .manual: iconName = "IconOnM"
            case .pac:    iconName = "IconOnP"
            default:      iconName = "IconOn"
            }
            if let button = self.statusItem.button {
                button.image = NSImage(named: NSImage.Name(iconName))
            }
        }
    }

    func setStatusMenuTip(pingTip: String) {
        // not shown in simplified menu — no-op
    }

    // showServers — refresh the Servers submenu (called by V2rayLaunch after switch/import)
    func showServers() {
        DispatchQueue.main.async {
            self.serversMenuItem.submenu = self.getServerMenus()
        }
    }
    func showRouting() {}

    // Build the Servers submenu from the saved server list
    func getServerMenus() -> NSMenu {
        let menu = NSMenu()
        let curSer = UserDefaults.get(forKey: .v2rayCurrentServerName)
        let servers = V2rayServer.list()
        if servers.isEmpty {
            let empty = NSMenuItem(title: "No servers — use Configure...", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for item in servers {
            menu.addItem(buildServerItem(item: item, curSer: curSer))
        }
        return menu
    }

    func buildServerItem(item: V2rayItem, curSer: String?) -> NSMenuItem {
        let title = item.remark.isEmpty ? item.name : item.remark
        let menuItem = NSMenuItem(title: title,
                                  action: #selector(switchServer(_:)),
                                  keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item
        menuItem.state = (item.name == curSer) ? .on : .off
        menuItem.isEnabled = item.isValid
        return menuItem
    }

    // MARK: - IBActions (kept for xib wiring; most are no-ops in simplified UI)

    @IBAction func openLogs(_ sender: NSMenuItem) { OpenLogs() }

    @objc func runFullTest(_ sender: Any) {
        LimmFullTest.shared.run()
    }

    @objc func sendDiagnosticLog(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText     = "Отправка диагностики..."
        alert.informativeText = "Собираем пробы и логи V2rayU."
        alert.addButton(withTitle: "OK")
        alert.runModal()

        LimmLogReporter.shared.send { ok, msg in
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText     = ok ? "Лог отправлен" : "Ошибка отправки"
                a.informativeText = msg
                a.runModal()
            }
        }
    }

    @IBAction func start(_ sender: NSMenuItem) { V2rayLaunch.ToggleRunning() }

    @IBAction func quitClicked(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    @IBAction func openPreferenceGeneral(_ sender: NSMenuItem) {
        DispatchQueue.main.async {
            preferencesWindowController.show(preferencePane: .generalTab)
            showDock(state: true)
        }
    }

    @IBAction func openPreferenceSubscribe(_ sender: NSMenuItem) {
        DispatchQueue.main.async {
            preferencesWindowController.show(preferencePane: .subscribeTab)
            showDock(state: true)
        }
    }

    @IBAction func openPreferencePac(_ sender: NSMenuItem) {}

    @IBAction func switchServer(_ sender: NSMenuItem) {
        guard let obj = sender.representedObject as? V2rayItem else { return }
        UserDefaults.set(forKey: .v2rayCurrentServerName, value: obj.name)
        V2rayLaunch.restartV2ray()
    }

    @IBAction func switchRouting(_ sender: NSMenuItem) {
        guard let obj = sender.representedObject as? RoutingItem else { return }
        UserDefaults.set(forKey: .routingSelectedRule, value: obj.name)
        V2rayLaunch.restartV2ray()
    }

    @IBAction func openConfig(_ sender: NSMenuItem) { OpenConfigWindow() }

    @objc private func configWindowWillClose(notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        let titles = ["limm VPN", "About", "Subscription", "General", "Advance"]
        if titles.contains(win.title) { showDock(state: false) }
    }

    @IBAction func goHelp(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://github.com/lexx633/vpn-mac")!)
    }

    @IBAction func switchManualMode(_ sender: NSMenuItem) {
        UserDefaults.set(forKey: .runMode, value: RunMode.manual.rawValue)
        V2rayLaunch.restartV2ray()
    }

    @IBAction func switchPacMode(_ sender: NSMenuItem) {
        UserDefaults.set(forKey: .runMode, value: RunMode.pac.rawValue)
        V2rayLaunch.restartV2ray()
    }

    @IBAction func goRouting(_ sender: NSMenuItem) {}

    @IBAction func switchGlobalMode(_ sender: NSMenuItem) {
        UserDefaults.set(forKey: .runMode, value: RunMode.global.rawValue)
        V2rayLaunch.restartV2ray()
    }

    @IBAction func checkForUpdate(_ sender: NSMenuItem) {
        LimmUpdater.shared.checkForUpdates(silent: false)
    }

    @IBAction func generateQrcode(_ sender: NSMenuItem) {}
    @IBAction func copyExportCommand(_ sender: NSMenuItem) {}
    @IBAction func scanQrcode(_ sender: NSMenuItem) {}
    @IBAction func ImportFromPasteboard(_ sender: NSMenuItem) {}
    @IBAction func pingSpeed(_ sender: NSMenuItem) {}
    @IBAction func viewConfig(_ sender: Any) {}
    @IBAction func viewPacFile(_ sender: Any) {}
    @IBAction func goRelease(_ sender: Any) {}
}

func getMenuServerTitle(item: V2rayItem) -> String {
    let speed = item.speed.count > 0 ? item.speed : "-1ms"
    return speed + "  " + item.remark
}
