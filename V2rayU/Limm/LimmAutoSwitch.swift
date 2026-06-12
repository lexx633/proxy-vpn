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
    let transportLadder: [String] = ["FR1-xhttp", "FR1-cf", "FR1-hy2", "FR1"]

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

    private func doSwitch(to name: String) {
        lastSwitchDate = Date()
        DispatchQueue.main.async {
            UserDefaults.set(forKey: .v2rayCurrentServerName, value: name)
            V2rayLaunch.restartV2ray()
            menuController.showServers()
        }
    }
}
