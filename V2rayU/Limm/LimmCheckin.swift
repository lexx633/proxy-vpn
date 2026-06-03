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

    // MARK: - Probes

    /// Run curl and return (http_code_string, body). Returns ("000","") on failure.
    private func curl(_ args: [String], timeout: Int = 10) -> (String, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // append http_code after body separated by newline
        var fullArgs = ["--max-time", "\(timeout)", "-s", "-L",
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

    /// Direct TCP reachability (no proxy). L0 = local net, L1/L2 = server reach.
    private func curlDirect(_ url: String, timeout: Int = 6) -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["--max-time", "\(timeout)", "-s", "-o", "/dev/null",
                          "--connect-timeout", "\(timeout)", url]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return 0 }
        // 0=ok, 52=empty reply (server closed — still reachable), both count as L0/L1
        let code = Int(proc.terminationStatus)
        return (code == 0 || code == 52 || code == 35 || code == 56) ? 1 : 0
    }

    /// Service probe through SOCKS: "ok" / "blocked" / "down"
    private func probeService(url: String, blockMarkers: [String], socks: String) -> String {
        let (code, body) = curl(["--socks5", socks, "--max-time", "15", url], timeout: 15)
        if code == "000" { return "down" }
        if code == "451" { return "blocked" }
        let lower = body.lowercased()
        for marker in blockMarkers { if lower.contains(marker) { return "blocked" } }
        return "ok"
    }

    // MARK: - Main checkin

    private func perform() {
        let token   = LimmConfig.token
        let uid     = LimmConfig.clientUID()
        let socksPort = UserDefaults.standard.integer(forKey: "localSockPort")
            .nonzero ?? 1080
        let socks   = "127.0.0.1:\(socksPort)"
        let vpnOn   = UserDefaults.standard.bool(forKey: "v2rayTurnOn")

        NSLog("[Limm] checkin start uid=%@ socks=%@", uid, socks)

        // L0 — local internet (DNS server, direct)
        let l0 = curlDirect("http://8.8.8.8", timeout: 5)

        // L1 — server TCP reachability (direct, no proxy)
        let l1 = curlDirect("http://\(LimmConfig.serverIP):\(LimmConfig.serverPort)", timeout: 5)

        var l2 = 0, l3 = 0, l4 = 0
        var egressIP = ""
        var destGoogle   = "down"
        var destTelegram = "down"
        var tgStatus     = "down"
        var gglStatus    = "down"
        var chgptStatus  = "down"

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

            // Service probes
            tgStatus    = probeService(url: "https://web.telegram.org/",
                                       blockMarkers: [],
                                       socks: socks)
            gglStatus   = probeService(url: "https://www.google.com/search?q=test",
                                       blockMarkers: [],
                                       socks: socks)
            chgptStatus = probeService(url: "https://chatgpt.com/",
                                       blockMarkers: ["unsupported_country",
                                                      "not available in your country",
                                                      "openai's services are not available"],
                                       socks: socks)
            destTelegram = tgStatus
            destGoogle   = gglStatus
        }

        let services: [String: Any] = ["tg": tgStatus, "ggl": gglStatus, "chgpt": chgptStatus]
        let raw: [String: Any] = [
            "dest_google":   destGoogle,
            "dest_telegram": destTelegram,
            "services":      services,
            "egress_ip":     egressIP,
        ]

        let payload: [String: Any] = [
            "client_uid":  uid,
            "kind":        LimmConfig.clientKind,
            "label":       LimmConfig.clientLabel,
            "app_version": LimmConfig.appVersion,
            "l0": l0, "l1": l1, "l2": l2, "l3": l3, "l4": l4,
            "vpn_running": vpnOn ? 1 : 0,
            "raw": raw,
        ]

        NSLog("[Limm] l0=%d l1=%d l2=%d l3=%d l4=%d vpn=%d tg=%@ ggl=%@ chgpt=%@",
              l0, l1, l2, l3, l4, vpnOn ? 1 : 0, tgStatus, gglStatus, chgptStatus)

        postCheckin(payload: payload, token: token)
    }

    private func postCheckin(payload: [String: Any], token: String) {
        guard let url = URL(string: "\(LimmConfig.apiBase)/checkin") else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 20

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                NSLog("[Limm] checkin error: %@", err.localizedDescription)
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let respStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            NSLog("[Limm] checkin -> %d %@", code, respStr.prefix(120))
        }
        task.resume()
    }
}

// Helpers
private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
