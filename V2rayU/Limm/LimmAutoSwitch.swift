// LimmAutoSwitch.swift — auto-select fastest server with configurable hysteresis
//
// Algorithm (per tick, every 60 s):
//   1. Probe each server 3× concurrently → take arithmetic mean latency
//   2. Compare current server mean vs best alternative mean
//   3. Switch only if: (current_avg - best_avg) > switchGapMs
//      AND at least switchCooldownMin minutes have passed since the last switch
//
// This prevents flapping: small fluctuations (±20 ms) don't trigger a switch;
// only a sustained lag spike that exceeds the gap triggers a move.

import Foundation

class LimmAutoSwitch {
    static let shared = LimmAutoSwitch()

    private var timer: Timer?
    private var lastSwitchDate: Date? = nil
    private init() {}

    // MARK: - Settings from UserDefaults

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: LimmConfig.autoServerKey) }
        set { UserDefaults.standard.set(newValue, forKey: LimmConfig.autoServerKey) }
    }

    /// Gap in ms: switch only when current_avg − best_avg > switchGapMs.
    var switchGapMs: Int {
        Int(UserDefaults.standard.string(forKey: LimmConfig.switchGapKey) ?? "50") ?? 50
    }

    /// Cooldown in minutes: minimum time between two switches.
    var switchCooldownMin: Double {
        Double(UserDefaults.standard.string(forKey: LimmConfig.switchCooldownKey) ?? "5") ?? 5
    }

    // MARK: - Lifecycle

    func enable() { isEnabled = true; start() }
    func disable() { isEnabled = false; stop() }

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
        // Cooldown guard
        if let last = lastSwitchDate {
            let elapsed = Date().timeIntervalSince(last) / 60   // minutes
            if elapsed < switchCooldownMin {
                let remaining = Int((switchCooldownMin - elapsed).rounded(.up))
                NSLog("[AutoSwitch] cooldown: \(remaining) min remaining, skipping")
                return
            }
        }

        let servers = V2rayServer.all().filter { $0.isValid }
        guard servers.count > 1 else { return }

        let curName = UserDefaults.get(forKey: .v2rayCurrentServerName) ?? ""

        // Probe each server 3× concurrently, compute mean
        struct Probe { let name: String; let avgMs: Int }
        var probes = [Probe]()
        let outerGroup = DispatchGroup()
        let lock       = NSLock()

        for item in servers {
            guard let (host, port) = LimmAutoSwitch.parseAddress(item) else { continue }
            outerGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                let avg = Self.probeAverage(host: host, port: port, count: 3)
                lock.lock(); probes.append(Probe(name: item.name, avgMs: avg)); lock.unlock()
                outerGroup.leave()
            }
        }
        outerGroup.wait()

        let valid = probes.filter { $0.avgMs >= 0 }
        guard valid.count > 1 else { return }

        let gap = switchGapMs

        guard let cur = valid.first(where: { $0.name == curName }) else {
            // Current server unreachable → pick fastest available
            if let best = valid.min(by: { $0.avgMs < $1.avgMs }) {
                NSLog("[AutoSwitch] current unreachable → \(best.name) (\(best.avgMs)ms)")
                doSwitch(to: best.name)
            }
            return
        }

        let others = valid.filter { $0.name != curName }
        guard let best = others.min(by: { $0.avgMs < $1.avgMs }) else { return }

        let diff = cur.avgMs - best.avgMs
        NSLog("[AutoSwitch] cur=\(cur.name) avg=\(cur.avgMs)ms | best=\(best.name) avg=\(best.avgMs)ms | diff=\(diff)ms | gap=\(gap)ms | cooldown=\(Int(switchCooldownMin))min")

        if diff > gap {
            NSLog("[AutoSwitch] switching → \(best.name)")
            doSwitch(to: best.name)
        }
    }

    private func doSwitch(to name: String) {
        lastSwitchDate = Date()
        DispatchQueue.main.async {
            UserDefaults.set(forKey: .v2rayCurrentServerName, value: name)
            V2rayLaunch.restartV2ray()
            menuController?.showServers()  // P-L1: optional chain — guard against nil before menu is ready
        }
    }

    // MARK: - Helpers

    /// Probe host:port `count` times concurrently, return arithmetic mean (or -1 if all failed).
    private static func probeAverage(host: String, port: Int, count: Int) -> Int {
        var results = [Int]()
        let group   = DispatchGroup()
        let lock    = NSLock()

        for _ in 0..<count {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let ms = tcpConnectLatency(host: host, port: port)
                if ms >= 0 { lock.lock(); results.append(ms); lock.unlock() }
                group.leave()
            }
        }
        group.wait()

        guard !results.isEmpty else { return -1 }
        return results.reduce(0, +) / results.count
    }

    /// Extract (host, port) from a V2rayItem using the V2rayConfig parser.
    static func parseAddress(_ item: V2rayItem) -> (String, Int)? {
        let cfg = V2rayConfig()
        cfg.parseJson(jsonText: item.json)

        if !cfg.serverVless.address.isEmpty, cfg.serverVless.port > 0 {
            return (cfg.serverVless.address, cfg.serverVless.port)
        }
        if !cfg.serverVmess.address.isEmpty, cfg.serverVmess.port > 0 {
            return (cfg.serverVmess.address, cfg.serverVmess.port)
        }
        if !cfg.serverTrojan.address.isEmpty, cfg.serverTrojan.port > 0 {
            return (cfg.serverTrojan.address, cfg.serverTrojan.port)
        }
        return nil
    }
}

// MARK: - TCP latency probe

/// Synchronous TCP connect to host:port. Returns latency in ms, or -1 on failure/timeout.
/// Always call from a background queue — blocks the calling thread up to ~4 s.
func tcpConnectLatency(host: String, port: Int) -> Int {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var addrPtr: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &addrPtr) == 0,
          let info = addrPtr else { return -1 }
    defer { freeaddrinfo(addrPtr) }

    let sockfd = socket(info.pointee.ai_family, info.pointee.ai_socktype, 0)
    guard sockfd >= 0 else { return -1 }
    defer { close(sockfd) }

    let sem    = DispatchSemaphore(value: 0)
    var result = -1
    let t0     = Date()

    Thread.detachNewThread {
        Thread.current.name = "limm-tcp-probe"  // P-L2: named thread for profiler/crashlog
        if connect(sockfd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
            result = Int(Date().timeIntervalSince(t0) * 1000)
        }
        sem.signal()
    }

    _ = sem.wait(timeout: .now() + 4.0)
    return result
}
