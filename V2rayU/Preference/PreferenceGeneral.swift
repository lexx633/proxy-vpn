// PreferenceGeneral.swift — limm VPN fork
// Limm section added programmatically (no xib edits needed).
// Proxy mode selector added — default is Global.

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
    private var limmBox:         NSBox!
    private var checkinCheckbox: NSButton!
    private var sendLogButton:   NSButton!
    private var modeLabel:       NSTextField!
    private var modeControl:     NSSegmentedControl!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Restore original checkboxes
        autoLaunch.state          = UserDefaults.getBool(forKey: .autoLaunch)          ? .on : .off
        autoCheckVersion.state    = UserDefaults.getBool(forKey: .autoCheckVersion)    ? .on : .off
        autoUpdateServers.state   = UserDefaults.getBool(forKey: .autoUpdateServers)   ? .on : .off
        autoSelectFastServer.state = UserDefaults.getBool(forKey: .autoSelectFastestServer) ? .on : .off

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
        let addH:  CGFloat = 130
        view.frame.size.height = nibH + addH
        preferredContentSize   = NSSize(width: nibW, height: nibH + addH)

        let mode = RunMode(rawValue: UserDefaults.get(forKey: .runMode) ?? "global") ?? .global

        // ── Box container ────────────────────────────────────────
        limmBox = NSBox()
        limmBox.title         = "limm VPN Agent"
        limmBox.titlePosition = .atTop
        limmBox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(limmBox)

        // ── Proxy mode ───────────────────────────────────────────
        modeLabel = NSTextField(labelWithString: "Режим прокси:")
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        limmBox.addSubview(modeLabel)

        modeControl = NSSegmentedControl(labels: ["Global", "PAC", "Manual"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(proxyModeChanged(_:)))
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegment = mode == .global ? 0 : (mode == .pac ? 1 : 2)
        limmBox.addSubview(modeControl)

        // ── Checkin toggle ───────────────────────────────────────
        checkinCheckbox = NSButton(checkboxWithTitle: "Отправлять диагностику на limm.space каждые 15 мин",
                                   target: self, action: #selector(checkinToggled(_:)))
        checkinCheckbox.translatesAutoresizingMaskIntoConstraints = false
        checkinCheckbox.state = UserDefaults.standard.bool(forKey: LimmConfig.checkinEnabledKey) ? .on : .off
        limmBox.addSubview(checkinCheckbox)

        // ── Send log button ──────────────────────────────────────
        sendLogButton = NSButton(title: "Send Diagnostic Log",
                                 target: self, action: #selector(sendDiagnosticLog(_:)))
        sendLogButton.bezelStyle = .rounded
        sendLogButton.translatesAutoresizingMaskIntoConstraints = false
        limmBox.addSubview(sendLogButton)

        // ── Constraints ──────────────────────────────────────────
        let col1: CGFloat = 16

        NSLayoutConstraint.activate([
            // limmBox below NIB content
            limmBox.topAnchor.constraint(equalTo: view.topAnchor, constant: nibH + 8),
            limmBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            limmBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            limmBox.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            // Mode
            modeLabel.topAnchor.constraint(equalTo: limmBox.topAnchor, constant: 20),
            modeLabel.leadingAnchor.constraint(equalTo: limmBox.leadingAnchor, constant: col1),

            modeControl.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),
            modeControl.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 12),

            // Checkin
            checkinCheckbox.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 14),
            checkinCheckbox.leadingAnchor.constraint(equalTo: limmBox.leadingAnchor, constant: col1),

            // Send log
            sendLogButton.topAnchor.constraint(equalTo: checkinCheckbox.bottomAnchor, constant: 12),
            sendLogButton.leadingAnchor.constraint(equalTo: limmBox.leadingAnchor, constant: col1),
            sendLogButton.bottomAnchor.constraint(equalTo: limmBox.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Actions

    @objc private func proxyModeChanged(_ sender: NSSegmentedControl) {
        let modes: [RunMode] = [.global, .pac, .manual]
        let selected = modes[sender.selectedSegment]
        UserDefaults.set(forKey: .runMode, value: selected.rawValue)
        if UserDefaults.getBool(forKey: .v2rayTurnOn) {
            V2rayLaunch.restartV2ray()
        }
    }

    @objc private func checkinToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: LimmConfig.checkinEnabledKey)
        if enabled {
            LimmCheckin.shared.start()
        } else {
            LimmCheckin.shared.stop()
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

    // "Feedback..." → наш GitHub
    @IBAction func goFeedback(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(string: "https://github.com/lexx633/vpn-mac")!)
    }

    // "Check for Updates..." → наш LimmUpdater (не Sparkle)
    @IBAction func checkVersion(_ sender: NSButton) {
        LimmUpdater.shared.checkForUpdates(silent: false)
    }
}
