// LimmCheckin.swift — background diagnostic checkin every 15 min
// Mirrors LimmCheckinWorker.kt on Android and vpn-agent.py on Windows.
// Uses curl subprocess (always available on macOS) for probes — no extra deps.

import Foundation
import Cocoa

class LimmCheckin {
    static let shared = LimmCheckin()
    private var timer: Timer?

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
        NSLog("[Limm] starting checkin timer (%.0fs)", LimmConfig.checkinInterval)
        runAsync()   // immediate first run
        timer = Timer.scheduledTimer(withTimeInterval: LimmConfig.checkinInterval, repeats: true) { _ in
            self.runAsync()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

    // MARK: - Main checkin

    /// Synchronously runs all curl probes, then fires HTTP POST (async, fire-and-forget).
    /// Called by the background timer and by LimmFullTest for immediate one-shot runs.
    /// - Parameter overrideVpnOn: if set, overrides UserDefaults `v2rayTurnOn`.
    ///   Use `overrideVpnOn: false` in Full Test step 1 (VPN not yet started) so that
    ///   SOCKS probes (L2–L4 + service checks) are skipped and checkin finishes in ~10s
    ///   instead of waiting up to 65s for curl timeouts on an unavailable SOCKS port.
    func perform(overrideVpnOn: Bool? = nil, checkinCompletion: ((Int, String) -> Void)? = nil) {
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

        // L1 — 3 direct probes → average RTT (bypasses system proxy via --noproxy)
        var l1 = 0
        var latencyMs = 0
        do {
            var samples: [Int] = []
            for _ in 0..<3 {
                let t = Date()
                if curlDirect("http://\(LimmConfig.serverIP):\(LimmConfig.serverPort)", timeout: 5) == 1 {
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
            // L2/L3 — connect to server through SOCKS
            let (serverCode, _) = curl(["--socks5", socks, "--connect-timeout", "8",
                                        "-o", "/dev/null",
                                        "https://\(LimmConfig.serverIP):\(LimmConfig.serverPort)"],
                                       timeout: 10)
            l2 = (serverCode != "000") ? 1 : 0
            l3 = l2

            // L4 — egress IP through tunnel
            let (ipCode, ipBody) = curl(["--socks5", socks, "https://api.ipify.org"], timeout: 15)
            if ipCode == "200" {
                egressIP = ipBody.trimmingCharacters(in: .whitespacesAndNewlines)
                l4 = (egressIP == LimmConfig.serverIP) ? 1 : 0
            }

            // tunnel_ms — 3 roundtrips through VPN tunnel → average
            var tmsSamples: [Int] = []
            for _ in 0..<3 {
                if let ms = measureTunnelMs(socks: socks) { tmsSamples.append(ms) }
            }
            if !tmsSamples.isEmpty { tunnelMs = tmsSamples.reduce(0, +) / tmsSamples.count }

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
            "vpn_running": vpnOn ? 1 : 0,
            "raw": raw,
        ]
        if latencyMs > 0 { payload["latency_ms"] = latencyMs }

        NSLog("[Limm] l0=%d l1=%d l2=%d l3=%d l4=%d vpn=%d tg=%@ ggl=%@ chgpt=%@",
              l0, l1, l2, l3, l4, vpnOn ? 1 : 0, tgStatus, gglStatus, chgptStatus)

        postCheckin(payload: payload, token: token, completion: checkinCompletion)
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
