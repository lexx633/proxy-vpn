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
import Network

class LimmAutoSwitch {
    static let shared = LimmAutoSwitch()

    private var timer: Timer?
    private var probeTimer: Timer?
    private var lastSwitchDate: Date? = nil
    private init() {}

    // MARK: - Latency store (filled by the 5-min TCP pre-ping)

    /// Measured TCP-connect latency per profile name, in ms. -1 = unreachable.
    /// A name absent from the dict = not probed yet (treated as reachable so the
    /// menu doesn't gray everything out before the first probe completes).
    private var latencyByName: [String: Int] = [:]
    private let latencyLock = NSLock()

    /// Probe interval — re-ping every profile every 5 minutes.
    private static let probeIntervalSec: TimeInterval = 300
    /// Per-connection probe timeout.
    private static let probeTimeoutMs = 2000

    // MARK: - Transport ladder (priority order)

    /// Ordered list of known transport server names. MUST match the #fragment
    /// names in the subscription (server/www/vpn/sub) so loadSelectedItem() finds
    /// a real imported profile — otherwise failover jumps to a nil item and kills
    /// connectivity. Index 0 = preferred; failover goes 0→1→2→3→0 (cyclically).
    /// Order by robustness: REALITY → XHTTP → WS(CF) → hy2 (UDP, last resort).
    /// Note: tuic (-tc) is excluded — V2rayU does not parse tuic:// URIs, so those
    /// profiles are never imported on macOS. AmneziaWG removed from the fleet 2026-06.
    let transportLadder: [String] = ["FR1-vl", "FR1-xhttp", "FR1-ws", "FR1-hy2"]

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

    /// Starts the 5-minute pre-ping timer. Runs ALWAYS (independent of auto mode)
    /// so the menu shows fresh per-profile latency and grays out unreachable ones
    /// even when the user picks servers manually. Call on launch and wake.
    func startProbing() {
        stopProbing()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshPings() }
        let t = Timer(timeInterval: LimmAutoSwitch.probeIntervalSec, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { self?.refreshPings() }
        }
        RunLoop.main.add(t, forMode: .common)
        probeTimer = t
    }

    func stopProbing() { probeTimer?.invalidate(); probeTimer = nil }

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

        // Real liveness of the ACTIVE profile failed (L3) → switch, but only to a
        // pre-pinged REACHABLE alternative. Refresh pings first so we don't jump to
        // a transport whose host went down since the last 5-min probe.
        _ = curIdx   // (kept above only to confirm curName is a ladder member)
        refreshPings()
        guard let nextName = bestLadderCandidate(excluding: curName) else {
            NSLog("[AutoSwitch] L3=fail on '%@' but no reachable alternative — staying", curName)
            return
        }
        let ms = latency(for: nextName) ?? -1
        NSLog("[AutoSwitch] L3=fail on '%@' → switching to '%@' (%dms, lowest reachable)",
              curName, nextName, ms)
        doSwitch(to: nextName)
    }

    /// Lowest-latency reachable ladder profile other than `cur`, or nil if none
    /// answered the TCP pre-ping. Drives ping-based failover when auto is enabled.
    private func bestLadderCandidate(excluding cur: String) -> String? {
        var best: (name: String, ms: Int)? = nil
        for name in transportLadder where name != cur {
            guard let ms = latency(for: name), ms >= 0 else { continue }
            if best == nil || ms < best!.ms { best = (name, ms) }
        }
        return best?.name
    }

    /// AWG transport name. When this is the target/current transport we drive
    /// LimmAWGProcess (userspace TUN) instead of launching an xray profile.
    static let awgTransportName = "FR1-awg"

    /// Hysteria2 transport names. These drive LimmHy2Process (SOCKS5 on :1088)
    /// instead of xray (which does not support the hysteria2 protocol).
    static func isHy2Transport(_ name: String) -> Bool { name.hasSuffix("-hy2") }

    func doSwitch(to name: String) {
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
                // → switching TO Hysteria2: bring up hy2 + point xray at it as a
                //   relay so the fixed local SOCKS port (:1080) flows through it.
                //   startHy2Relay() handles AWG teardown and hy2 (re)start.
                NSLog("[AutoSwitch] entering HY2 transport: %@", name)
                V2rayLaunch.startHy2Relay(transport: name)
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

    // MARK: - TCP pre-ping (reachability + latency for the menu)

    /// Probe every imported server's host:port with a quick TCP connect and store
    /// the latency. Note: this proves the host/port is REACHABLE, not that the
    /// tunnel protocol works (hy2 is UDP; CF/REALITY answer TCP regardless). Real
    /// tunnel liveness comes from the active profile's L3 egress — see hybrid note.
    func refreshPings() {
        let servers = V2rayServer.list()
        var results: [String: Int] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for s in servers {
            guard let ep = endpoint(for: s) else { continue }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let ms = self.tcpPing(host: ep.host, port: ep.port) ?? -1
                lock.lock(); results[s.name] = ms; lock.unlock()
                group.leave()
            }
        }
        // Bound the whole sweep so a hung probe never stalls failover.
        _ = group.wait(timeout: .now() + .milliseconds(LimmAutoSwitch.probeTimeoutMs + 1500))
        latencyLock.lock(); latencyByName = results; latencyLock.unlock()
        DispatchQueue.main.async { menuController.showServers() }
    }

    /// host:port for a profile, parsed from its original share URL (vless:// or
    /// hysteria2://) — both carry `userinfo@host:port`. Authoritative, no hardcode.
    private func endpoint(for item: V2rayItem) -> (host: String, port: Int)? {
        var s = item.url
        if let h = s.range(of: "#") { s = String(s[..<h.lowerBound]) }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty else { return nil }
        return (host, u.port ?? 443)
    }

    /// Single TCP-connect latency probe. Returns ms on success, nil on timeout/fail.
    private func tcpPing(host: String, port: Int, timeoutMs: Int = LimmAutoSwitch.probeTimeoutMs) -> Int? {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var result: Int? = nil
        let start = Date()
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result = Int(Date().timeIntervalSince(start) * 1000)
                sem.signal()
            case .failed, .cancelled:
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "limm.tcpping"))
        _ = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        conn.cancel()
        return result
    }

    /// Measured latency (ms) for a profile, or nil if not probed yet. -1 = unreachable.
    func latency(for name: String) -> Int? {
        latencyLock.lock(); defer { latencyLock.unlock() }
        return latencyByName[name]
    }

    /// False only when a profile was probed AND its host/port did not answer.
    /// Untested (nil) → true, so the menu doesn't gray out before the first probe.
    func isReachable(_ name: String) -> Bool {
        guard let ms = latency(for: name) else { return true }
        return ms >= 0
    }

    /// Menu suffix: "123 ms", "—" (unreachable), or "" (not probed yet).
    func pingLabel(for name: String) -> String {
        guard let ms = latency(for: name) else { return "" }
        return ms >= 0 ? "\(ms) ms" : "—"
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
