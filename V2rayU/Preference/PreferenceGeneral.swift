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
    private var limmBox:          NSBox!
    private var checkinCheckbox:  NSButton!
    private var sendLogButton:    NSButton!
    private var modeLabel:        NSTextField!
    private var modeControl:      NSSegmentedControl!
    private var limmSectionBuilt: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Restore original checkboxes
        autoLaunch.state          = UserDefaults.getBool(forKey: .autoLaunch)          ? .on : .off
        autoCheckVersion.state    = UserDefaults.getBool(forKey: .autoCheckVersion)    ? .on : .off
        autoUpdateServers.state   = UserDefaults.getBool(forKey: .autoUpdateServers)   ? .on : .off
        autoSelectFastServer.state = UserDefaults.getBool(forKey: .autoSelectFastestServer) ? .on : .off
    }

    // NIB uses AutoLayout — frame is only valid after layout pass, not in viewDidLoad.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !limmSectionBuilt, view.frame.height > 50 else { return }
        limmSectionBuilt = true
        buildLimmSection()
    }

    // MARK: - Limm section (programmatic)

    private func buildLimmSection() {
        // At this point (called from viewDidLayout) view.frame is valid.
        // NSPreferences views are flipped (y=0 at top), so "below existing content"
        // means y = origH (in flipped coords the box sits right after the NIB rows).
        let origH: CGFloat = view.frame.height
        let boxH:  CGFloat = 148
        let addH:  CGFloat = boxH + 16

        // Expand the view downward to fit our box.
        view.frame.size.height = origH + addH
        preferredContentSize   = NSSize(width: view.frame.width, height: view.frame.height)

        // Box — frame-based, no AutoLayout (avoids fighting the NIB's constraint engine).
        limmBox = NSBox(frame: NSRect(x: 20, y: origH + 8,
                                     width: view.frame.width - 40, height: boxH))
        limmBox.autoresizingMask = [.width]
        limmBox.title        = "limm VPN Agent"
        limmBox.titlePosition = .atTop
        view.addSubview(limmBox)

        let boxW = limmBox.bounds.width

        // Proxy mode label
        modeLabel = NSTextField(labelWithString: "Режим прокси:")
        modeLabel.sizeToFit()
        modeLabel.setFrameOrigin(NSPoint(x: 16, y: boxH - 44))
        limmBox.addSubview(modeLabel)

        // Segmented control: Global / PAC / Manual
        modeControl = NSSegmentedControl(labels: ["Global", "PAC", "Manual"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(proxyModeChanged(_:)))
        modeControl.sizeToFit()
        modeControl.setFrameOrigin(NSPoint(x: 16 + modeLabel.frame.width + 12,
                                           y: modeLabel.frame.minY - 2))
        let mode = RunMode(rawValue: UserDefaults.get(forKey: .runMode) ?? "global") ?? .global
        modeControl.selectedSegment = mode == .global ? 0 : (mode == .pac ? 1 : 2)
        limmBox.addSubview(modeControl)

        // Checkin checkbox
        checkinCheckbox = NSButton(checkboxWithTitle: "Отправлять диагностику на limm.space каждые 15 мин",
                                   target: self, action: #selector(checkinToggled(_:)))
        checkinCheckbox.sizeToFit()
        checkinCheckbox.setFrameOrigin(NSPoint(x: 16, y: modeLabel.frame.minY - 30))
        checkinCheckbox.state = UserDefaults.standard.bool(forKey: LimmConfig.checkinEnabledKey) ? .on : .off
        limmBox.addSubview(checkinCheckbox)

        // Send log button
        sendLogButton = NSButton(title: "Send Diagnostic Log",
                                 target: self, action: #selector(sendDiagnosticLog(_:)))
        sendLogButton.bezelStyle = .rounded
        sendLogButton.sizeToFit()
        sendLogButton.setFrameOrigin(NSPoint(x: 16, y: checkinCheckbox.frame.minY - 32))
        limmBox.addSubview(sendLogButton)
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
        // Menu item visibility updates automatically via KVO in MenuController
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
