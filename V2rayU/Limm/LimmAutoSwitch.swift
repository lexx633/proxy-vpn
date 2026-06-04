// LimmAutoSwitch.swift — auto-select fastest server with configurable hysteresis
// Logic: every 60 s probe each server via TCP connect; switch to a faster one
// only if current is slower by more than switchGapMs. This prevents flapping
// when latencies are close (e.g. 70ms vs 80ms with a 50ms gap → no switch).

import Foundation

class LimmAutoSwitch {
    static let shared = LimmAutoSwitch()
    private var timer: Timer?
    private init() {}

    // MARK: - State

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: LimmConfig.autoServerKey) }
        set { UserDefaults.standard.set(newValue, forKey: LimmConfig.autoServerKey) }
    }

    /// Gap threshold in ms — only switch when current - best > switchGapMs.
    var switchGapMs: Int {
        let raw = UserDefaults.standard.string(forKey: LimmConfig.switchGapKey) ?? "50"
        return Int(raw) ?? 50
    }

    // MARK: - Lifecycle

    func enable() {
        isEnabled = true
        start()
    }

    func disable() {
        isEnabled = false
        stop()
    }

    /// Call on app launch (resumes if was enabled in previous session).
    func start() {
        guard isEnabled else { return }
        stop()
        tick()   // immediate first evaluation
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Core logic

    private func tick() {
        DispatchQueue.global(qos: .utility).async { self.evaluateAndSwitch() }
    }

    private func evaluateAndSwitch() {
        let servers = V2rayServer.all().filter { $0.isValid }
        guard servers.count > 1 else { return }

        let curName = UserDefaults.get(forKey: .v2rayCurrentServerName) ?? ""

        // Probe all servers concurrently
        struct Probe { let name: String; let ms: Int }
        var probes = [Probe]()
        let group  = DispatchGroup()
        let lock   = NSLock()

        for item in servers {
            guard let (host, port) = Self.parseAddress(item) else { continue }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let ms = tcpConnectLatency(host: host, port: port)
                lock.lock(); probes.append(Probe(name: item.name, ms: ms)); lock.unlock()
                group.leave()
            }
        }
        group.wait()

        let valid = probes.filter { $0.ms >= 0 }
        guard valid.count > 1 else { return }

        let gap = switchGapMs

        guard let cur = valid.first(where: { $0.name == curName }) else {
            // Current server probe failed — immediately pick the fastest reachable one
            if let best = valid.min(by: { $0.ms < $1.ms }) {
                NSLog("[AutoSwitch] current unreachable → \(best.name) (\(best.ms)ms)")
                doSwitch(to: best.name)
            }
            return
        }

        let others = valid.filter { $0.name != curName }
        guard let best = others.min(by: { $0.ms < $1.ms }) else { return }

        let diff = cur.ms - best.ms
        NSLog("[AutoSwitch] cur=\(cur.name) \(cur.ms)ms | best=\(best.name) \(best.ms)ms | diff=\(diff)ms | gap=\(gap)ms")

        if diff > gap {
            NSLog("[AutoSwitch] switching → \(best.name)")
            doSwitch(to: best.name)
        }
    }

    private func doSwitch(to name: String) {
        DispatchQueue.main.async {
            UserDefaults.set(forKey: .v2rayCurrentServerName, value: name)
            V2rayLaunch.restartV2ray()
            menuController.showServers()
        }
    }

    // MARK: - Address parsing

    /// Extract (host, port) from a V2rayItem using V2rayConfig parser.
    static func parseAddress(_ item: V2rayItem) -> (String, Int)? {
        let cfg = V2rayConfig()
        cfg.parseJson(jsonText: item.json)

        if !cfg.serverVless.address.isEmpty && cfg.serverVless.port > 0 {
            return (cfg.serverVless.address, cfg.serverVless.port)
        }
        if !cfg.serverVmess.address.isEmpty && cfg.serverVmess.port > 0 {
            return (cfg.serverVmess.address, cfg.serverVmess.port)
        }
        if !cfg.serverTrojan.address.isEmpty && cfg.serverTrojan.port > 0 {
            return (cfg.serverTrojan.address, cfg.serverTrojan.port)
        }
        return nil
    }
}

// MARK: - TCP latency probe

/// Synchronous TCP connect to host:port. Returns latency in ms, or -1 on failure/timeout.
/// Always call from a background queue — blocks the calling thread up to ~4 s.
func tcpConnectLatency(host: String, port: Int) -> Int {
    // Resolve address on a background thread (blocks on getaddrinfo)
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var addrPtr: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &addrPtr) == 0,
          let info = addrPtr else { return -1 }
    defer { freeaddrinfo(addrPtr) }

    let sockfd = socket(info.pointee.ai_family, info.pointee.ai_socktype, 0)
    guard sockfd >= 0 else { return -1 }
    defer { close(sockfd) }

    // Use semaphore + detached thread so we can enforce a hard timeout
    let sem     = DispatchSemaphore(value: 0)
    var result  = -1
    let t0      = Date()

    Thread.detachNewThread {
        if connect(sockfd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
            result = Int(Date().timeIntervalSince(t0) * 1000)
        }
        sem.signal()
    }

    // Wait up to 4 seconds
    _ = sem.wait(timeout: .now() + 4.0)
    return result
}
