// LimmAutoSwitch.swift — transport-ladder failover
//
// Algorithm (per tick, every 60 s):
//   1. Get current server name.
//   2. If it's not in transportLadder → do nothing (user's custom server, don't touch).
//   3. Read last L3 result from LimmCheckin.lastL3ok.
//   4. If L3=true → tunnel works, stay put.
//   5. If L3=false AND cooldown elapsed → advance to next transport in ladder (cyclically).
//
// No ping probes. No flapping. Source of truth = last checkin L3 result.

import Foundation

class LimmAutoSwitch {
    static let shared = LimmAutoSwitch()

    private var timer: Timer?
    private var lastSwitchDate: Date? = nil
    private init() {}

    // MARK: - Transport ladder (priority order)

    /// Ordered list of known transport server names.
    /// Index 0 = preferred; failover goes 0→1→2→3→0 (cyclically).
    /// AmneziaWG ("FR1-awg") is NOT an xray profile — it's a userspace TUN driven by
    /// LimmAWGProcess. doSwitch() branches on this name. See docs/TZ-amneziawg-clients.md §B.
    let transportLadder: [String] = ["FR1-xhttp", "FR1-cf", "FR1-hy2", "FR1-awg", "FR1-wg", "FR1"]

    // MARK: - Settings from UserDefaults

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: LimmConfig.autoServerKey) }
        set { UserDefaults.standard.set(newValue, forKey: LimmConfig.autoServerKey) }
    }

    /// Cooldown in minutes: minimum time between two switches.
    var switchCooldownMin: Double {
        Double(UserDefaults.standard.string(forKey: LimmConfig.switchCooldownKey) ?? "5") ?? 5
    }

    // MARK: - Lifecycle

    func enable() { isEnabled = true; start() }
    func disable() { isEnabled = false; stop() }

    /// Register default: autoswitch ON unless user explicitly disabled it.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [LimmConfig.autoServerKey: true])
    }

    /// Starts the 60-second timer. Call on app launch and on wake-from-sleep.
    func start() {
        guard isEnabled else { return }
        stop()
        tick()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Evaluation

    private func tick() {
        DispatchQueue.global(qos: .utility).async { self.evaluateAndSwitch() }
    }

    private func evaluateAndSwitch() {
        let curName = UserDefaults.get(forKey: .v2rayCurrentServerName) ?? ""

        // If current server is not in our ladder → user chose a custom profile, leave it alone.
        guard let curIdx = transportLadder.firstIndex(of: curName) else {
            NSLog("[AutoSwitch] current server '%@' not in ladder — skipping", curName)
            return
        }

        // Read last L3 result written by LimmCheckin.perform()
        let l3ok    = LimmCheckin.lastL3ok
        let l3date  = LimmCheckin.lastL3date

        // If we haven't received any checkin data yet, play it safe and don't switch.
        guard let checkinAge = l3date.map({ Date().timeIntervalSince($0) }) else {
            NSLog("[AutoSwitch] no checkin data yet — skipping")
            return
        }

        // If checkin is stale (>20 min), data may be unreliable — skip.
        if checkinAge > 20 * 60 {
            NSLog("[AutoSwitch] last checkin is %.0fs ago (>20min) — skipping", checkinAge)
            return
        }

        // Tunnel is working → stay put.
        if l3ok {
            NSLog("[AutoSwitch] L3=ok on '%@' — no switch needed", curName)
            return
        }

        // Tunnel broken → check cooldown before switching.
        if let last = lastSwitchDate {
            let elapsed = Date().timeIntervalSince(last) / 60   // minutes
            if elapsed < switchCooldownMin {
                let remaining = Int((switchCooldownMin - elapsed).rounded(.up))
                NSLog("[AutoSwitch] L3=fail on '%@' but cooldown: %dmin remaining", curName, remaining)
                return
            }
        }

        // Advance to next transport in ladder (cyclically).
        let nextIdx  = (curIdx + 1) % transportLadder.count
        let nextName = transportLadder[nextIdx]

        NSLog("[AutoSwitch] L3=fail on '%@' → switching to '%@' (ladder %d→%d)",
              curName, nextName, curIdx, nextIdx)
        doSwitch(to: nextName)
    }

    /// AWG transport name. When this is the target/current transport we drive
    /// LimmAWGProcess (userspace TUN) instead of launching an xray profile.
    static let awgTransportName = "FR1-awg"

    /// Hysteria2 transport names. These drive LimmHy2Process (SOCKS5 on :1088)
    /// instead of xray (which does not support the hysteria2 protocol).
    static func isHy2Transport(_ name: String) -> Bool { name.hasSuffix("-hy2") }

    private func doSwitch(to name: String) {
        lastSwitchDate = Date()
        let curName    = UserDefaults.get(forKey: .v2rayCurrentServerName) ?? ""
        let leavingAWG = (curName == LimmAutoSwitch.awgTransportName)
        let leavingHy2 = LimmAutoSwitch.isHy2Transport(curName)

        DispatchQueue.main.async {
            UserDefaults.set(forKey: .v2rayCurrentServerName, value: name)

            if name == LimmAutoSwitch.awgTransportName {
                // → switching TO AmneziaWG: stop xray + hy2, bring up AWG TUN.
                NSLog("[AutoSwitch] entering AWG transport")
                if leavingHy2 || LimmHy2Process.shared.isRunning {
                    NSLog("[AutoSwitch] leaving HY2 transport (→ AWG)")
                    LimmHy2Process.shared.stop()
                }
                V2rayLaunch.stopV2rayCore()
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = LimmAWGProcess.shared.start()
                    NSLog("[AutoSwitch] AWG start → %@", ok ? "ok" : "FAILED")
                    DispatchQueue.main.async { menuController.showServers() }
                }
                LimmAutoSwitch.sendSwitchEvent(to: name)
                return
            }

            if LimmAutoSwitch.isHy2Transport(name) {
                // → switching TO Hysteria2: stop xray + AWG, start hysteria2.
                NSLog("[AutoSwitch] entering HY2 transport: %@", name)
                if leavingAWG || LimmAWGProcess.shared.isRunning {
                    NSLog("[AutoSwitch] leaving AWG transport (→ HY2)")
                    LimmAWGProcess.shared.stop()
                }
                if LimmHy2Process.shared.isRunning { LimmHy2Process.shared.stop() }
                V2rayLaunch.stopV2rayCore()
                let switchName = name   // capture before async block
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = LimmHy2Process.shared.start(transport: switchName)
                    NSLog("[AutoSwitch] HY2 start (%@) → %@", switchName, ok ? "ok" : "FAILED")
                    DispatchQueue.main.async { menuController.showServers() }
                }
                LimmAutoSwitch.sendSwitchEvent(to: name)
                return
            }

            // → switching TO an xray transport.
            if leavingAWG || LimmAWGProcess.shared.isRunning {
                NSLog("[AutoSwitch] leaving AWG transport (→ xray)")
                LimmAWGProcess.shared.stop()
            }
            if leavingHy2 || LimmHy2Process.shared.isRunning {
                NSLog("[AutoSwitch] leaving HY2 transport (→ xray)")
                LimmHy2Process.shared.stop()
            }
            V2rayLaunch.restartV2ray()
            menuController.showServers()
            LimmAutoSwitch.sendSwitchEvent(to: name)
        }
    }

    /// Notify the monitoring collector that a transport switch happened (dashboard event).
    private static func sendSwitchEvent(to name: String) {
        guard let url = URL(string: "\(LimmConfig.apiBase)/event") else { return }
        let payload: [String: Any] = [
            "client_uid": LimmConfig.clientUID(),
            "event_type": "transport_switch",
            "note":       "macos → \(name)",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(LimmConfig.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 15
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { _, _, _ in session.finishTasksAndInvalidate() }.resume()
    }
}
