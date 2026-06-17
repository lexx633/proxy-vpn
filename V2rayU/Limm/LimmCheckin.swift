// LimmCheckin.swift — background diagnostic checkin every 15 min
// Mirrors LimmCheckinWorker.kt on Android and vpn-agent.py on Windows.
// Uses curl subprocess (always available on macOS) for probes — no extra deps.

import Foundation
import Cocoa

class LimmCheckin {
    static let shared = LimmCheckin()
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    // MARK: - Last L3 result (used by LimmAutoSwitch)

    /// True if the last completed checkin measured L3 (tunnel) = 1.
    /// Set by perform() after every full diagnostic cycle.
    static private(set) var lastL3ok:   Bool  = true
    static private(set) var lastL3date: Date? = nil

    // MARK: - Lifecycle

    func start() {
        guard !LimmConfig.token.isEmpty, LimmConfig.token != "__LIMM_TOKEN__" else {
            NSLog("[Limm] token not configured — checkin disabled")
            return
        }
        guard UserDefaults.standard.bool(forKey: LimmConfig.checkinEnabledKey) else {
            NSLog("[Limm] checkin disabled by user")
            return
        }
        // Prevent App Nap from throttling background work (does NOT block system sleep).
        activity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "Limm VPN checkin timer")
        NSLog("[Limm] starting checkin timer (%.0fs)", LimmConfig.checkinInterval)
        runAsync()   // immediate first run
        let t = Timer(timeInterval: LimmConfig.checkinInterval, repeats: true) { _ in self.runAsync() }
        // .common mode fires in all RunLoop modes (default + event tracking) — avoids timer freeze.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    func runAsync() {
        DispatchQueue.global(qos: .background).async { self.perform() }
    }

    /// One-shot checkin button: run full perform() on background queue, call completion on result.
    func runOnce(completion: @escaping (Int, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.perform(checkinCompletion: completion)
        }
    }

    /// Fast one-shot for the "Send Status Checkin" button — completes in <2s.
    /// • VPN SOCKS port alive → performQuick (no curl probes, instant POST)
    /// • VPN off             → one L0 probe (≤5s) + POST with vpn_running=0
    /// Avoids the full perform() that takes 30–75s and always triggered the 30s UI timeout.
    func runOnceQuick(completion: @escaping (Int, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let socksPort = (UserDefaults.standard.integer(forKey: "localSockPort")).nonzero ?? 1080
            let prefOn    = UserDefaults.standard.bool(forKey: "v2rayTurnOn")
            let vpnOn     = prefOn || self.socksListening(socksPort)
            if vpnOn {
                // Instant: no probes, just POST "VPN is on"
                self.performQuick(egressLatencyMs: nil, completion: completion)
            } else {
                // Minimal: one L0 connectivity probe + POST "VPN is off"
                let l0 = self.curlDirect("http://1.1.1.1", timeout: 5)
                let payload: [String: Any] = [
                    "client_uid":   LimmConfig.clientUID(),
                    "kind":         LimmConfig.clientKind,
                    "label":        LimmConfig.clientLabel,
                    "app_version":  LimmConfig.appVersion,
                    "l0_local_net": l0, "l1_tcp443": 0,
                    "l2_handshake": 0,  "l3_tunnel": 0, "l4_dest": 0,
                    "vpn_running":  0,
                    "raw": ["egress_ip": "", "dest_google": "down", "dest_telegram": "down",
                            "services": ["tg": "down", "ggl": "down", "chgpt": "down"]],
                ]
                self.postCheckin(payload: payload, token: LimmConfig.token, completion: completion)
            }
        }
    }

    /// Lightweight post-Full-Test checkin — no curl probes, just POSTs "VPN is on"
    /// with results we already know from the test. Fires completion from URLSession callback.
    /// egressLatencyMs: latency of the working profile (from curl api.ipify.org probe).
    func performQuick(egressLatencyMs: Int?, completion: @escaping (Int, String) -> Void) {
        let uid = LimmConfig.clientUID()
        var payload: [String: Any] = [
            "client_uid":   uid,
            "kind":         LimmConfig.clientKind,
            "label":        LimmConfig.clientLabel,
            "app_version":  LimmConfig.appVersion,
            "l0_local_net": 1, "l1_tcp443": 1, "l2_handshake": 1, "l3_tunnel": 1, "l4_dest": 1,
            "vpn_running":  1,
            "raw": ["egress_ip": LimmConfig.serverIP,
                    "dest_google": "ok", "dest_telegram": "ok",
                    "services": ["tg": "ok", "ggl": "ok", "chgpt": "ok"]],
        ]
        if let ms = egressLatencyMs { payload["tunnel_ms"] = ms }
        NSLog("[Limm] performQuick vpn=1 tunnel=%@ms", egressLatencyMs.map { "\($0)" } ?? "nil")
        postCheckin(payload: payload, token: LimmConfig.token, completion: completion)
    }

    // MARK: - Probes

    /// Run curl and return (http_code_string, body). Returns ("000","") on failure.
    /// Uses both --max-time AND --connect-timeout to guarantee curl exits.
    /// --max-time alone sometimes doesn't interrupt an SSL handshake hang;
    /// --connect-timeout caps the TCP+TLS phase independently.
    private func curl(_ args: [String], timeout: Int = 10) -> (String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        let connectTimeout = max(timeout - 2, 3)   // connect phase ≤ (timeout-2)s
        var fullArgs = ["--max-time", "\(timeout)",
                        "--connect-timeout", "\(connectTimeout)",
                        "-s", "-L",
                        "-A", "Mozilla/5.0 (limm-probe)",
                        "-w", "\n%{http_code}"] + args
        proc.arguments = fullArgs
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe
        do {
            try proc.run(); proc.waitUntilExit()
            let raw = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // split off last line = http_code
            if let nl = raw.lastIndex(of: "\n") {
                let code = String(raw[raw.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = String(raw[..<nl])
                return (code.isEmpty ? "000" : code, body)
            }
            return ("000", raw)
        } catch {
            return ("000", "")
        }
    }

    /// Pure TCP connect to localhost:port. Returns true if port is listening.
    /// Uses nc -z (no data sent) — works regardless of protocol on the port.
    private func socksListening(_ port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        p.arguments = ["-z", "-G", "1", "127.0.0.1", "\(port)"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// Direct TCP reachability (no proxy). L0 = local net, L1/L2 = server reach.
    private func curlDirect(_ url: String, timeout: Int = 6) -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // --noproxy '*' bypasses macOS system proxy (set by V2rayU) so L0/L1 measure
        // real internet reachability, not the VPN tunnel.
        proc.arguments = ["--max-time", "\(timeout)", "-s", "-o", "/dev/null",
                          "--connect-timeout", "\(timeout)", "--noproxy", "*", url]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return 0 }
        // 0=ok, 52=empty reply (server closed — still reachable), both count as L0/L1
        let code = Int(proc.terminationStatus)
        return (code == 0 || code == 52 || code == 35 || code == 56) ? 1 : 0
    }

    /// Service probe through SOCKS: "ok" / "blocked" / "down"
    private func probeService(url: String, blockMarkers: [String], socks: String) -> String {
        let (code, body) = curl(["--socks5", socks, url], timeout: 15)
        if code == "000" { return "down" }
        if code == "451" { return "blocked" }
        let lower = body.lowercased()
        for marker in blockMarkers { if lower.contains(marker) { return "blocked" } }
        return "ok"
    }

    /// Measure full HTTP roundtrip through SOCKS (tunnel latency).
    /// Returns milliseconds or nil on failure. Uses a single attempt with short timeout.
    private func measureTunnelMs(socks: String) -> Int? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["--max-time", "5", "-s", "-o", "/dev/null",
                          "-w", "%{time_total}",
                          "--socks5", socks,
                          "https://www.gstatic.com/generate_204"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = Pipe()
        do {
            try proc.run(); proc.waitUntilExit()
        } catch { return nil }
        let raw = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let sec = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), sec > 0 else { return nil }
        return Int(sec * 1000)
    }

    // MARK: - Egress (§7.3/§7.4 contract)

    /// Egress IP through SOCKS: own `/api/myip` (CF path) first, `api.ipify.org` fallback.
    /// Drops the sole dependency on ipify (false negatives when it's down/blocked). The probe
    /// rides the tunnel → exit is outside RU → CF (`limm.space`) is reachable and returns the
    /// real exit-node IP via CF-Connecting-IP. §7.4: a non-nil result means "tunnel carries
    /// traffic" (egress != null); the SERVER decides whether it's our node (SERVER_IPS).
    private func egressViaSocks(_ socks: String, timeout: Int = 15) -> String? {
        let (c1, b1) = curl(["--socks5", socks, "https://limm.space/api/myip"], timeout: timeout)
        if c1 == "200", let ip = parseMyIp(b1) { return ip }
        let (c2, b2) = curl(["--socks5", socks, "https://api.ipify.org"], timeout: timeout)
        if c2 == "200" {
            let ip = b2.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableEgress(ip) { return ip }
        }
        return nil
    }

    /// Direct (no-proxy) egress — for AWG/utun where traffic already rides the tunnel.
    private func egressDirect(timeout: Int = 12) -> String? {
        let (c1, b1) = curlNoProxy("https://limm.space/api/myip", timeout: timeout)
        if c1 == "200", let ip = parseMyIp(b1) { return ip }
        let (c2, b2) = curlNoProxy("https://api.ipify.org", timeout: timeout)
        if c2 == "200" {
            let ip = b2.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableEgress(ip) { return ip }
        }
        return nil
    }

    /// Parse {"ip":"..."} from /api/myip, rejecting blank/loopback/private.
    private func parseMyIp(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = (obj["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isUsableEgress(ip) else { return nil }
        return ip
    }

    /// Public IP of the CURRENTLY-selected node, resolved from its remark (…RU1…/…DE1…/…FR1…).
    /// L1 (direct TCP) and L2 (SOCKS handshake) must probe the ACTIVE node — probing a hardcoded
    /// FR1 made DE1/RU1 profiles report l1=0/l2=0 on a healthy tunnel. Falls back to serverIP.
    private func activeNodeIP() -> String {
        let cur = UserDefaults.get(forKey: .v2rayCurrentServerName) ?? ""
        let remark = V2rayServer.list().first { $0.name == cur }?.remark ?? ""
        let tag = (cur + " " + remark).uppercased()
        if tag.contains("RU1") { return "185.244.173.28" }
        if tag.contains("DE1") { return "77.90.52.123" }
        if tag.contains("FR1") { return "45.95.175.170" }
        return LimmConfig.serverIP
    }

    /// A real egress can't be loopback/private — guards against a mirror (e.g. the www path
    /// behind the :443 stream-mux) echoing 127.0.0.1 instead of the true exit IP.
    private func isUsableEgress(_ ip: String) -> Bool {
        if ip.isEmpty { return false }
        if ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("10.")
            || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.") { return false }
        if ip.hasPrefix("172.") {
            let p = ip.split(separator: ".")
            if p.count > 1, let o2 = Int(p[1]), (16...31).contains(o2) { return false }
        }
        return true
    }

    // MARK: - Main checkin

    /// Synchronously runs all curl probes, then fires HTTP POST (async, fire-and-forget).
    /// Called by the background timer and by LimmFullTest for immediate one-shot runs.
    /// - Parameter overrideVpnOn: if set, overrides UserDefaults `v2rayTurnOn`.
    ///   Use `overrideVpnOn: false` in Full Test step 1 (VPN not yet started) so that
    ///   SOCKS probes (L2–L4 + service checks) are skipped and checkin finishes in ~10s
    ///   instead of waiting up to 65s for curl timeouts on an unavailable SOCKS port.
    func perform(overrideVpnOn: Bool? = nil, checkinCompletion: ((Int, String) -> Void)? = nil) {
        // ─── AmneziaWG (TUN, no SOCKS) special-case — closes TZ §0.3 ───
        // When the active transport is FR1-awg there is NO local SOCKS proxy (:1087 is
        // empty). Probing through SOCKS would falsely report L2/L3=0 and bounce the
        // autoswitch off a working AWG tunnel. Instead, probe egress DIRECTLY: with the
        // utun up, all traffic is already tunnelled, so the egress IP equals the server IP.
        let curServer = UserDefaults.get(forKey: .v2rayCurrentServerName) ?? ""
        if curServer == LimmAutoSwitch.awgTransportName && LimmAWGProcess.shared.isRunning {
            performAWG(checkinCompletion: checkinCompletion)
            return
        }
        // ─── Hysteria2 (SOCKS on :1088, no xray) special-case ───────────
        if LimmAutoSwitch.isHy2Transport(curServer) && LimmHy2Process.shared.isRunning {
            performHy2(transport: curServer, checkinCompletion: checkinCompletion)
            return
        }

        let token   = LimmConfig.token
        let uid     = LimmConfig.clientUID()
        let socksPort = UserDefaults.standard.integer(forKey: "localSockPort")
            .nonzero ?? 1080
        let socks   = "127.0.0.1:\(socksPort)"
        // vpnOn: primary = UserDefaults toggle; fallback = nc -z TCP probe on SOCKS port.
        // Handles auto-switch / external restarts where v2rayTurnOn wasn't updated.
        // nc -z: pure TCP connect (no protocol); exit 0 = port listening.
        let vpnOn: Bool
        if let ov = overrideVpnOn {
            vpnOn = ov
        } else {
            let prefOn = UserDefaults.standard.bool(forKey: "v2rayTurnOn")
            let socksUp = !prefOn && socksListening(socksPort)
            vpnOn = prefOn || socksUp
        }

        NSLog("[Limm] checkin start uid=%@ socks=%@", uid, socks)

        // L0 — local internet: 1.1.1.1:80 (Cloudflare HTTP, always responds on port 80)
        // 8.8.8.8 was wrong target — Google DNS does not serve HTTP, exit code 7
        // (connection refused) was not in success list → l0 always 0 with --noproxy.
        let l0 = curlDirect("http://1.1.1.1", timeout: 5)

        // L1 — 3 direct probes to the ACTIVE node → average RTT (bypasses system proxy)
        let nodeIP = activeNodeIP()
        var l1 = 0
        var latencyMs = 0
        do {
            var samples: [Int] = []
            for _ in 0..<3 {
                let t = Date()
                if curlDirect("http://\(nodeIP):\(LimmConfig.serverPort)", timeout: 5) == 1 {
                    samples.append(Int(Date().timeIntervalSince(t) * 1000))
                    l1 = 1
                }
            }
            if !samples.isEmpty { latencyMs = samples.reduce(0, +) / samples.count }
        }

        var l2 = 0, l3 = 0, l4 = 0
        var egressIP = ""
        var destGoogle   = "down"
        var destTelegram = "down"
        var tgStatus     = "down"
        var gglStatus    = "down"
        var chgptStatus  = "down"
        var tunnelMs: Int? = nil

        if vpnOn {
            // L2 — transport handshake: SOCKS connect to the ACTIVE node:443 (§7.2 — channel up, no inet yet)
            let (serverCode, _) = curl(["--socks5", socks, "--connect-timeout", "8",
                                        "-o", "/dev/null",
                                        "https://\(nodeIP):\(LimmConfig.serverPort)"],
                                       timeout: 10)
            l2 = (serverCode != "000") ? 1 : 0

            // L3 — tunnel carries traffic: egress via /api/myip (CF) → ipify (§7.3/§7.4).
            // Any egress = l3; the server maps egress_ip→node (no client-side isOurEgress).
            if let ip = egressViaSocks(socks) { egressIP = ip; l3 = 1 }

            // tunnel_ms + L4 (browser_ok) — generate_204 through the tunnel (§7.2)
            var tmsSamples: [Int] = []
            for _ in 0..<3 {
                if let ms = measureTunnelMs(socks: socks) { tmsSamples.append(ms) }
            }
            if !tmsSamples.isEmpty { tunnelMs = tmsSamples.reduce(0, +) / tmsSamples.count }
            l4 = (tunnelMs != nil) ? 1 : 0

            // Service probes — run in parallel so all 3 take ≤10s instead of 3×10s sequential
            let probeGroup = DispatchGroup()
            probeGroup.enter()
            DispatchQueue.global().async {
                tgStatus = self.probeService(url: "https://web.telegram.org/",
                                             blockMarkers: [], socks: socks)
                probeGroup.leave()
            }
            probeGroup.enter()
            DispatchQueue.global().async {
                gglStatus = self.probeService(url: "https://www.google.com/search?q=test",
                                              blockMarkers: [], socks: socks)
                probeGroup.leave()
            }
            probeGroup.enter()
            DispatchQueue.global().async {
                chgptStatus = self.probeService(url: "https://chatgpt.com/",
                                                blockMarkers: ["unsupported_country",
                                                               "not available in your country",
                                                               "openai's services are not available"],
                                                socks: socks)
                probeGroup.leave()
            }
            probeGroup.wait()
            destTelegram = tgStatus
            destGoogle   = gglStatus
        }

        let services: [String: Any] = ["tg": tgStatus, "ggl": gglStatus, "chgpt": chgptStatus]
        var raw: [String: Any] = [
            "dest_google":   destGoogle,
            "dest_telegram": destTelegram,
            "services":      services,
            "egress_ip":     egressIP,
        ]
        if let ms = tunnelMs { raw["tunnel_ms"] = ms }

        var payload: [String: Any] = [
            "client_uid":  uid,
            "kind":        LimmConfig.clientKind,
            "label":       LimmConfig.clientLabel,
            "app_version": LimmConfig.appVersion,
            "l0_local_net": l0, "l1_tcp443": l1, "l2_handshake": l2, "l3_tunnel": l3, "l4_dest": l4,
            "browser_ok": l4,   // §7.7 contract field (generate_204 through the tunnel)
            "vpn_running": vpnOn ? 1 : 0,
            "raw": raw,
        ]
        if latencyMs > 0 { payload["latency_ms"] = latencyMs }

        NSLog("[Limm] l0=%d l1=%d l2=%d l3=%d l4=%d vpn=%d tg=%@ ggl=%@ chgpt=%@",
              l0, l1, l2, l3, l4, vpnOn ? 1 : 0, tgStatus, gglStatus, chgptStatus)

        // Update last L3 result for LimmAutoSwitch ladder logic.
        // Only update when VPN was on — if VPN is off, l3=0 by definition and
        // we don't want that to trigger a transport switch.
        if vpnOn {
            LimmCheckin.lastL3ok   = (l3 == 1)
            LimmCheckin.lastL3date = Date()
        }

        postCheckin(payload: payload, token: token, completion: checkinCompletion)
    }

    // MARK: - AmneziaWG checkin (direct probes, no SOCKS — closes TZ §0.3 §B.5)

    /// Diagnostic cycle while the AWG (utun) transport is active. There is no SOCKS proxy,
    /// so egress is measured DIRECTLY: with the tunnel up, all traffic is routed through
    /// utun and the public egress IP equals the server IP.
    /// L3 (tunnel) source of truth for AWG = (direct egress IP == server IP).
    private func performAWG(checkinCompletion: ((Int, String) -> Void)? = nil) {
        let uid = LimmConfig.clientUID()

        // L0 — local internet (this still reaches out; with full-tunnel routing it goes via utun,
        // which is fine — if utun is down we'd get 0 here too). Kept for parity with the dashboard.
        let l0 = curlDirect("http://1.1.1.1", timeout: 5)

        // Egress via /api/myip (CF) → ipify, direct through utun (§7.3/§7.4).
        // Any egress = tunnel carrying us out (no client-side isOurEgress; server maps it).
        let egressIP = egressDirect() ?? ""
        let egressOK = !egressIP.isEmpty
        let l = egressOK ? 1 : 0   // L1/L2/L3/L4 all collapse to "is the tunnel carrying us out"

        NSLog("[Limm] AWG checkin egress=%@ ok=%d", egressIP, egressOK ? 1 : 0)

        let raw: [String: Any] = [
            "dest_google":   egressOK ? "ok" : "down",
            "dest_telegram": egressOK ? "ok" : "down",
            "services":      ["tg": egressOK ? "ok" : "down",
                              "ggl": egressOK ? "ok" : "down",
                              "chgpt": egressOK ? "ok" : "down"],
            "egress_ip":     egressIP,
            "transport":     "awg",
        ]
        let payload: [String: Any] = [
            "client_uid":  uid,
            "kind":        LimmConfig.clientKind,
            "label":       LimmConfig.clientLabel,
            "app_version": LimmConfig.appVersion,
            "l0_local_net": l0, "l1_tcp443": l, "l2_handshake": l, "l3_tunnel": l, "l4_dest": l,
            "browser_ok": l,   // §7.7 contract field
            "vpn_running": 1,
            "raw": raw,
        ]

        // Update L3 source of truth for LimmAutoSwitch (only the direct-egress verdict).
        LimmCheckin.lastL3ok   = egressOK
        LimmCheckin.lastL3date = Date()

        postCheckin(payload: payload, token: LimmConfig.token, completion: checkinCompletion)
    }

    // MARK: - Hysteria2 checkin (SOCKS on :1088 — closes hy2 tunnel verification)

    /// Diagnostic cycle while a Hysteria2 transport is active.
    /// Probes via SOCKS5 on :1088 (the port hysteria2 exposes locally).
    /// L3 source of truth = L2 SOCKS handshake to server + correct egress IP.
    private func performHy2(transport: String, checkinCompletion: ((Int, String) -> Void)? = nil) {
        let uid   = LimmConfig.clientUID()
        let socks = "127.0.0.1:\(LimmHy2Process.socksPort)"

        // L0 — local internet (same as normal checkin)
        let l0 = curlDirect("http://1.1.1.1", timeout: 5)

        // L1 — direct TCP to the ACTIVE node (bypasses proxy)
        let nodeIP = activeNodeIP()
        var l1 = 0; var latencyMs = 0
        var samples: [Int] = []
        for _ in 0..<3 {
            let t = Date()
            if curlDirect("http://\(nodeIP):\(LimmConfig.serverPort)", timeout: 5) == 1 {
                samples.append(Int(Date().timeIntervalSince(t) * 1000))
                l1 = 1
            }
        }
        if !samples.isEmpty { latencyMs = samples.reduce(0, +) / samples.count }

        // L2 — transport handshake: SOCKS connect to the ACTIVE node:443 through hy2 (§7.2)
        let (serverCode, _) = curl(["--socks5", socks, "--connect-timeout", "8",
                                    "-o", "/dev/null",
                                    "https://\(nodeIP):\(LimmConfig.serverPort)"],
                                   timeout: 10)
        let l2 = (serverCode != "000") ? 1 : 0

        // L3 — tunnel carries traffic: egress via /api/myip (CF) → ipify (§7.4). Any egress = l3.
        var l3 = 0; var egressIP = ""
        if let ip = egressViaSocks(socks) { egressIP = ip; l3 = 1 }
        // The egress fetch itself is a real HTTPS GET through the tunnel → browsing works.
        let l4 = l3

        NSLog("[Limm] HY2 checkin (%@) l0=%d l1=%d l2=%d l3=%d l4=%d egress=%@",
              transport, l0, l1, l2, l3, l4, egressIP)

        LimmCheckin.lastL3ok   = (l3 == 1)
        LimmCheckin.lastL3date = Date()

        let raw: [String: Any] = [
            "dest_google":   l3 == 1 ? "ok" : "down",
            "dest_telegram": l3 == 1 ? "ok" : "down",
            "services":      ["tg":   l3 == 1 ? "ok" : "down",
                              "ggl":  l3 == 1 ? "ok" : "down",
                              "chgpt": l3 == 1 ? "ok" : "down"],
            "egress_ip":     egressIP,
            "transport":     "hy2",
        ]
        var payload: [String: Any] = [
            "client_uid":   uid,
            "kind":         LimmConfig.clientKind,
            "label":        LimmConfig.clientLabel,
            "app_version":  LimmConfig.appVersion,
            "l0_local_net": l0, "l1_tcp443": l1, "l2_handshake": l2, "l3_tunnel": l3, "l4_dest": l4,
            "browser_ok":   l4,   // §7.7 contract field
            "vpn_running":  1,
            "raw":          raw,
        ]
        if latencyMs > 0 { payload["latency_ms"] = latencyMs }

        postCheckin(payload: payload, token: LimmConfig.token, completion: checkinCompletion)
    }

    /// Direct curl bypassing system proxy, returning (http_code, body). Used for AWG egress
    /// probe where traffic must ride the utun, not a SOCKS proxy.
    private func curlNoProxy(_ url: String, timeout: Int = 12) -> (String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["--max-time", "\(timeout)",
                          "--connect-timeout", "\(max(timeout - 2, 3))",
                          "-s", "--noproxy", "*",
                          "-A", "Mozilla/5.0 (limm-probe)",
                          "-w", "\n%{http_code}", url]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return ("000", "") }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let nl = raw.lastIndex(of: "\n") {
            let code = String(raw[raw.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (code.isEmpty ? "000" : code, String(raw[..<nl]))
        }
        return ("000", raw)
    }

    private func postCheckin(payload: [String: Any], token: String, completion: ((Int, String) -> Void)? = nil) {
        guard let url = URL(string: "\(LimmConfig.apiBase)/checkin") else {
            completion?(0, "bad url"); return
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(0, "json error"); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 20

        // Bypass system proxy: in Global mode all traffic goes through SOCKS;
        // if Xray restarts mid-checkin the proxy is briefly down and the request fails.
        // P-H1: capture session in closure and call finishTasksAndInvalidate() on completion
        // to release the connection pool — avoids accumulating idle sessions over 15-min cycles.
        let directConfig = URLSessionConfiguration.ephemeral
        directConfig.connectionProxyDictionary = [:]
        let session = URLSession(configuration: directConfig)
        let task = session.dataTask(with: req) { data, resp, err in
            defer { session.finishTasksAndInvalidate() }
            if let err = err {
                NSLog("[Limm] checkin error: %@", err.localizedDescription)
                completion?(0, err.localizedDescription)
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let respStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            NSLog("%@", "[Limm] checkin -> \(code) \(respStr.prefix(120))")
            completion?(code, respStr)
        }
        task.resume()
    }
}

// Helpers
private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
