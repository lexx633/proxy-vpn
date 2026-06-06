// PreferenceGeneral.swift — limm VPN fork
// Limm section added programmatically (no xib edits needed).
// Proxy mode is always Global — selector removed.

import Cocoa
import Preferences
import ServiceManagement

final class PreferenceGeneralViewController: NSViewController, SettingsPane {
    let preferencePaneIdentifier: Settings.PaneIdentifier = .generalTab
    let preferencePaneTitle = "General"
    let toolbarItemIcon = NSImage(named: NSImage.preferencesGeneralName)!

    override var nibName: NSNib.Name? { return "PreferenceGeneral" }

    // Original outlets
    @IBOutlet weak var autoLaunch:          NSButtonCell!
    @IBOutlet weak var autoCheckVersion:    NSButtonCell!
    @IBOutlet weak var autoUpdateServers:   NSButtonCell!
    @IBOutlet weak var autoSelectFastServer: NSButtonCell!

    // Limm UI — created programmatically
    private var limmBox:             NSBox!
    private var checkinCheckbox:     NSButton!
    private var autoConnectCheckbox: NSButton!
    private var sendLogButton:       NSButton!
    private var checkinButton:       NSButton!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Restore original checkboxes
        autoLaunch.state           = UserDefaults.getBool(forKey: .autoLaunch)               ? .on : .off
        autoCheckVersion.state     = UserDefaults.getBool(forKey: .autoCheckVersion)         ? .on : .off
        autoUpdateServers.state    = UserDefaults.getBool(forKey: .autoUpdateServers)        ? .on : .off
        autoSelectFastServer.state = UserDefaults.getBool(forKey: .autoSelectFastestServer)  ? .on : .off

        // Force AutoLayout to resolve NIB constraints so view.frame.height is valid.
        view.layoutSubtreeIfNeeded()
        buildLimmSection()
    }

    // MARK: - Limm section (programmatic)

    private func buildLimmSection() {
        // Hardcoded NIB dimensions (PreferenceGeneral.xib root view: 700×360).
        // Do NOT read view.frame here — in viewDidLoad the window is not yet set,
        // so frame can be zero even after layoutSubtreeIfNeeded().
        let nibW:  CGFloat = 700
        let nibH:  CGFloat = 360
        let addH:  CGFloat = 120   // extended: +row for autoConnect + checkin button
        view.frame.size.height = nibH + addH
        preferredContentSize   = NSSize(width: nibW, height: nibH + addH)

        // Always use Global mode — no selector needed
        UserDefaults.set(forKey: .runMode, value: RunMode.global.rawValue)

        // ── Box container ────────────────────────────────────────
        limmBox = NSBox()
        limmBox.title         = "limm VPN Agent"
        limmBox.titlePosition = .atTop
        limmBox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(limmBox)

        // ── Checkin toggle ───────────────────────────────────────
        checkinCheckbox = NSButton(checkboxWithTitle: "Отправлять диагностику на limm.space каждые 15 мин",
                                   target: self, action: #selector(checkinToggled(_:)))
        checkinCheckbox.translatesAutoresizingMaskIntoConstraints = false
        checkinCheckbox.state = UserDefaults.standard.bool(forKey: LimmConfig.checkinEnabledKey) ? .on : .off
        limmBox.addSubview(checkinCheckbox)

        // ── Auto-connect toggle ──────────────────────────────────
        autoConnectCheckbox = NSButton(checkboxWithTitle: "Авто-подключение при запуске (последний профиль)",
                                       target: self, action: #selector(autoConnectToggled(_:)))
        autoConnectCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoConnectCheckbox.state = UserDefaults.standard.bool(forKey: LimmConfig.autoConnectKey) ? .on : .off
        limmBox.addSubview(autoConnectCheckbox)

        // ── Send log button ──────────────────────────────────────
        sendLogButton = NSButton(title: "Send Diagnostic Log",
                                 target: self, action: #selector(sendDiagnosticLog(_:)))
        sendLogButton.bezelStyle = .rounded
        sendLogButton.translatesAutoresizingMaskIntoConstraints = false
        limmBox.addSubview(sendLogButton)

        // ── Checkin button ───────────────────────────────────────
        checkinButton = NSButton(title: "Чекин статуса",
                                 target: self, action: #selector(runCheckin(_:)))
        checkinButton.bezelStyle = .rounded
        checkinButton.translatesAutoresizingMaskIntoConstraints = false
        limmBox.addSubview(checkinButton)

        // ── Constraints ──────────────────────────────────────────
        let col1: CGFloat = 16

        NSLayoutConstraint.activate([
            // limmBox below NIB content
            limmBox.topAnchor.constraint(equalTo: view.topAnchor, constant: nibH + 8),
            limmBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            limmBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            limmBox.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            // Row 1: Checkin toggle
            checkinCheckbox.topAnchor.constraint(equalTo: limmBox.topAnchor, constant: 20),
            checkinCheckbox.leadingAnchor.constraint(equalTo: limmBox.leadingAnchor, constant: col1),

            // Row 2: Auto-connect toggle
            autoConnectCheckbox.topAnchor.constraint(equalTo: checkinCheckbox.bottomAnchor, constant: 8),
            autoConnectCheckbox.leadingAnchor.constraint(equalTo: limmBox.leadingAnchor, constant: col1),

            // Row 3: Send log | Чекин (side by side)
            sendLogButton.topAnchor.constraint(equalTo: autoConnectCheckbox.bottomAnchor, constant: 12),
            sendLogButton.leadingAnchor.constraint(equalTo: limmBox.leadingAnchor, constant: col1),
            sendLogButton.bottomAnchor.constraint(equalTo: limmBox.bottomAnchor, constant: -16),

            checkinButton.centerYAnchor.constraint(equalTo: sendLogButton.centerYAnchor),
            checkinButton.leadingAnchor.constraint(equalTo: sendLogButton.trailingAnchor, constant: 10),
        ])
    }

    // MARK: - Actions

    @objc private func checkinToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: LimmConfig.checkinEnabledKey)
        if enabled {
            LimmCheckin.shared.start()
        } else {
            LimmCheckin.shared.stop()
        }
    }

    @objc private func autoConnectToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: LimmConfig.autoConnectKey)
    }

    @objc private func runCheckin(_ sender: NSButton) {
        checkinButton.isEnabled = false
        checkinButton.title     = "Отправляем…"
        LimmCheckin.shared.runOnce { code, msg in
            DispatchQueue.main.async {
                self.checkinButton.isEnabled = true
                self.checkinButton.title     = "Чекин статуса"
                let alert = NSAlert()
                alert.messageText     = code == 200 ? "✅ Чекин отправлен" : "❌ Ошибка чекина"
                alert.informativeText = code == 200 ? "Статус обновлён на limm.space/stat" : msg
                alert.runModal()
            }
        }
    }

    @objc private func sendDiagnosticLog(_ sender: NSButton) {
        sendLogButton.isEnabled = false
        sendLogButton.title     = "Отправляем..."

        LimmLogReporter.shared.send { ok, msg in
            DispatchQueue.main.async {
                self.sendLogButton.isEnabled = true
                self.sendLogButton.title     = "Send Diagnostic Log"
                let alert = NSAlert()
                alert.messageText     = ok ? "✅ Лог отправлен" : "❌ Ошибка отправки"
                alert.informativeText = msg
                alert.runModal()
            }
        }
    }

    // MARK: - Original IBActions

    @IBAction func SetAutoLogin(_ sender: NSButtonCell) {
        SMLoginItemSetEnabled(launcherAppIdentifier as CFString, sender.state == .on)
        UserDefaults.setBool(forKey: .autoLaunch, value: sender.state == .on)
    }

    @IBAction func SetAutoCheckVersion(_ sender: NSButtonCell) {
        UserDefaults.setBool(forKey: .autoCheckVersion, value: sender.state == .on)
    }

    @IBAction func SetAutoUpdateServers(_ sender: NSButtonCell) {
        UserDefaults.setBool(forKey: .autoUpdateServers, value: sender.state == .on)
    }

    @IBAction func SetAutoSelectFastServer(_ sender: NSButtonCell) {
        UserDefaults.setBool(forKey: .autoSelectFastestServer, value: sender.state == .on)
    }

    // "Configure..." → opens server config window
    @IBAction func goFeedback(_ sender: NSButton) {
        OpenConfigWindow()
    }

    // "Check for Updates..." → наш LimmUpdater (не Sparkle)
    @IBAction func checkVersion(_ sender: NSButton) {
        LimmUpdater.shared.checkForUpdates(silent: false)
    }
}
