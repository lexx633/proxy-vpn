// AppDelegate.swift — limm VPN (fork of V2rayU)
// Firebase and AppCenter removed. Limm checkin + updater added.

import Cocoa
import ServiceManagement
import MASShortcut
import Preferences

let launcherAppIdentifier = "net.yanue.V2rayU.Launcher"
let appVersion = getAppVersion()

let NOTIFY_TOGGLE_RUNNING_SHORTCUT      = Notification.Name("NOTIFY_TOGGLE_RUNNING_SHORTCUT")
let NOTIFY_SWITCH_PROXY_MODE_SHORTCUT   = Notification.Name("NOTIFY_SWITCH_PROXY_MODE_SHORTCUT")

// Preferences tabs — only generalTab/advanceTab/subscribeTab/aboutTab shown in window;
// dnsTab/routingTab/pacTab kept for compilation (their view controllers still exist in project)
extension Settings.PaneIdentifier {
    static let generalTab   = Self("generalTab")
    static let advanceTab   = Self("advanceTab")
    static let subscribeTab = Self("subscribeTab")
    static let aboutTab     = Self("aboutTab")
    static let dnsTab       = Self("dnsTab")
    static let routingTab   = Self("routingTab")
    static let pacTab       = Self("pacTab")
}

let preferencesWindowController = PreferencesWindowController(
    preferencePanes: [
        PreferenceGeneralViewController(),
        PreferenceAdvanceViewController(),
        PreferenceSubscribeViewController(),
        PreferenceAboutViewController(),
    ]
)

let langStr   = Locale.current.languageCode
let isMainland = langStr == "zh-CN" || langStr == "zh" || langStr == "zh-Hans" || langStr == "zh-Hant"

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet weak var statusMenu: NSMenu!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // check installed
        V2rayLaunch.checkInstall()

        // default settings
        checkDefault()

        // auto launch
        if UserDefaults.getBool(forKey: .autoLaunch) {
            let startedAtLogin = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == launcherAppIdentifier
            }
            if startedAtLogin {
                DistributedNotificationCenter.default().post(
                    name: Notification.Name("terminateV2rayU"),
                    object: Bundle.main.bundleIdentifier!)
            }
        }

        // wake / sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onSleepNote(note:)),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onWakeNote(note:)),
            name: NSWorkspace.didWakeNotification, object: nil)

        // URL scheme
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleAppleEvent(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID:    AEEventID(kAEGetURL))

        // global hotkeys
        let nc = NotificationCenter.default
        nc.addObserver(forName: NOTIFY_TOGGLE_RUNNING_SHORTCUT, object: nil, queue: nil) { _ in
            V2rayLaunch.ToggleRunning()
        }
        nc.addObserver(forName: NOTIFY_SWITCH_PROXY_MODE_SHORTCUT, object: nil, queue: nil) { _ in
            V2rayLaunch.SwitchProxyMode()
        }
        ShortcutsController.bindShortcuts()

        // run v2ray at start (restores last state if was running)
        V2rayLaunch.runAtStart()
        // limm: auto-connect — always connect to last profile on launch, regardless of last state
        if UserDefaults.standard.bool(forKey: LimmConfig.autoConnectKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                V2rayLaunch.startV2rayCore()
            }
        }

        // limm: checkin every 15 min
        LimmCheckin.shared.start()
        // limm: auto-switch to fastest server (resumes if was enabled)
        LimmAutoSwitch.shared.start()

        // limm: auto check updates — only if enabled AND >30 days since last check.
        // Stores last check timestamp so the app doesn't ping GitHub on every launch.
        if UserDefaults.getBool(forKey: .autoCheckVersion) {
            let lastTs   = UserDefaults.standard.double(forKey: LimmConfig.lastUpdateCheckKey)
            let daysSince = (Date().timeIntervalSince1970 - lastTs) / 86_400
            if daysSince >= 30 {
                UserDefaults.standard.set(Date().timeIntervalSince1970,
                                          forKey: LimmConfig.lastUpdateCheckKey)
                LimmUpdater.shared.checkForUpdates(silent: true)
            }
        }
    }

    func checkDefault() {
        if UserDefaults.get(forKey: .autoUpdateServers) == nil {
            UserDefaults.setBool(forKey: .autoUpdateServers, value: true)
        }
        // limm: auto-select disabled — prevents constant ping/switch/restart loop
        // User can enable in Preferences > General if needed
        if UserDefaults.get(forKey: .autoSelectFastestServer) == nil {
            UserDefaults.setBool(forKey: .autoSelectFastestServer, value: false)
        }
        if UserDefaults.get(forKey: .autoLaunch) == nil {
            SMLoginItemSetEnabled(launcherAppIdentifier as CFString, true)
            UserDefaults.setBool(forKey: .autoLaunch, value: true)
        }
        // limm: ALWAYS Global mode — весь трафик через тоннель
        UserDefaults.set(forKey: .runMode, value: RunMode.global.rawValue)
        if UserDefaults.get(forKey: .autoClearLog) == nil {
            UserDefaults.setBool(forKey: .autoClearLog, value: true)
        }
        // limm: checkin enabled by default
        if UserDefaults.standard.object(forKey: LimmConfig.checkinEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: LimmConfig.checkinEnabledKey)
        }
        // limm: pre-populate our subscription if none exist
        if UserDefaults.getArray(forKey: .v2raySubList)?.isEmpty ?? true {
            V2raySubscription.add(remark: "limm.space", url: LimmConfig.subURL)
        }

        V2rayLaunch.clearLogFile()
        V2rayServer.loadConfig()

        // Remove the invalid "default" placeholder (empty vmess) — imported subscription provides real servers
        let servers = V2rayServer.list()
        if let idx = servers.firstIndex(where: { $0.name == "config.default" }) {
            V2rayServer.remove(idx: idx)
        }
        V2rayRoutings.loadConfig()
        V2raySubscription.loadConfig()
    }

    @objc func handleAppleEvent(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let desc = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              let _ = desc.stringValue else { return }
        // todo: handle vpn:// scheme
    }

    @objc func onWakeNote(note: NSNotification) {
        NSLog("onWakeNote")
        if UserDefaults.getBool(forKey: .v2rayTurnOn) {
            V2rayLaunch.restartV2ray()
        }
        if UserDefaults.getBool(forKey: .autoCheckVersion) {
            LimmUpdater.shared.checkForUpdates(silent: true)
        }
        if UserDefaults.getBool(forKey: .autoUpdateServers) {
            V2raySubSync.shared.sync()
        }
        if UserDefaults.getBool(forKey: .autoClearLog) {
            V2rayLaunch.truncateLogFile()
        }
        // restart checkin + auto-switch timers after wake
        LimmCheckin.shared.stop()
        LimmCheckin.shared.start()
        LimmAutoSwitch.shared.stop()
        LimmAutoSwitch.shared.start()
    }

    @objc func onSleepNote(note: NSNotification) {
        NSLog("onSleepNote")
        LimmCheckin.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MASShortcutMonitor.shared().unregisterAllShortcuts()
        LimmCheckin.shared.stop()
        V2rayLaunch.Stop()
        V2rayLaunch.setSystemProxy(mode: .off)
        killSelfV2ray()
        webServer.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ aNotification: Notification) {}
}
