// LimmLogReporter.swift — collect diagnostic bundle and upload to limm.space/api/applog
// Equivalent to Android's LimmLogReporter.kt and macOS send-log.py agent script.

import Foundation

class LimmLogReporter {
    static let shared = LimmLogReporter()

    // MARK: - Entry point

    func send(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let bundle = self.collectBundle()
            self.upload(bundle: bundle, completion: completion)
        }
    }

    // MARK: - Bundle collection

    private func collectBundle() -> [String: Any] {
        let socksPort = UserDefaults.standard.integer(forKey: "localSockPort").nonzero ?? 1080
        let socks     = "127.0.0.1:\(socksPort)"

        var bundle: [String: Any] = [
            "client_uid":   LimmConfig.clientUID(),
            "kind":         LimmConfig.clientKind,
            "app_version":  LimmConfig.appVersion,
            "ts":           ISO8601DateFormatter().string(from: Date()),
        ]

        // --- Live probe ---
        bundle["probe"] = collectProbe(socks: socks)

        // --- System network ---
        bundle["system_net"] = collectSystemNet()

        // --- V2rayU log tail ---
        bundle["v2rayu_log"] = collectV2rayLog()

        return bundle
    }

    private func collectProbe(socks: String) -> [String: Any] {
        // Timeouts are kept short: this runs inside the 55s log-button window.
        // Worst case: 3s(l0) + 3s(l1) + 5s(ipify) + 5s(parallel services) + 20s(upload) = ~36s.
        func curl(_ args: [String], timeout: Int = 5) -> (String, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["--max-time", "\(timeout)",
                           "--connect-timeout", "\(max(timeout - 1, 2))",
                           "-s", "-L",
                           "-A", "Mozilla/5.0 (limm-log)",
                           "-w", "\n%{http_code}"] + args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit() } catch { return ("000", "") }
            let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let nl = raw.lastIndex(of: "\n") {
                return (String(raw[raw.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines),
                        String(raw[..<nl]))
            }
            return ("000", raw)
        }

        // --noproxy '*' bypasses macOS system proxy (set by V2rayU) for direct reachability probes.
        func directOk(_ url: String) -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["--max-time", "3", "--connect-timeout", "3",
                           "-s", "-o", "/dev/null", "--noproxy", "*", url]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let c = Int(p.terminationStatus)
            return (c == 0 || c == 52 || c == 35) ? 1 : 0
        }

        let l0 = directOk("http://1.1.1.1")
        let l1 = directOk("http://\(LimmConfig.serverIP):\(LimmConfig.serverPort)")

        let (_, ipRaw) = curl(["--socks5", socks, "https://api.ipify.org"])
        let egressIP = ipRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let l4 = egressIP == LimmConfig.serverIP ? 1 : 0

        // Service probes run in parallel — max time = 1 probe timeout (5s) instead of 3×timeout.
        var tgStat = "down"; var gglStat = "down"; var chgptStat = "down"
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            let (code, _) = curl(["--socks5", socks, "https://web.telegram.org/"])
            tgStat = code == "000" ? "down" : code == "451" ? "blocked" : "ok"
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            let (code, _) = curl(["--socks5", socks, "https://www.google.com/search?q=test"])
            gglStat = code == "000" ? "down" : code == "451" ? "blocked" : "ok"
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            let (code, body) = curl(["--socks5", socks, "https://chatgpt.com/"])
            let lower = body.lowercased()
            let isBlocked = code == "451" || ["unsupported_country", "not available in your country",
                                               "openai's services are not available"]
                .contains { lower.contains($0) }
            chgptStat = code == "000" ? "down" : isBlocked ? "blocked" : "ok"
            group.leave()
        }

        group.wait()

        return [
            "l0": l0, "l1": l1, "l4": l4,
            "egress_ip": egressIP,
            "vpn_running": UserDefaults.standard.bool(forKey: "v2rayTurnOn") ? 1 : 0,
            "tg": tgStat, "ggl": gglStat, "chgpt": chgptStat,
        ]
    }

    private func collectSystemNet() -> [String: Any] {
        func run(_ path: String, _ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        return [
            "scutil_proxy":   run("/usr/sbin/scutil", ["--proxy"]),
            "netstat_route":  run("/usr/sbin/netstat", ["-rn", "-f", "inet"]),
            "ifconfig_utun":  run("/sbin/ifconfig", ["utun0"]),
        ]
    }

    private func collectV2rayLog() -> String {
        let logPath = NSHomeDirectory() + "/.V2rayU/v2ray-core.log"
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: "\n")
        // Find the last Xray version header (banner line before "[Warning] core: Xray X.Y.Z started")
        let versionLine = lines.reversed().first { $0.contains("Xray") && $0.contains("Penetrates Everything") } ?? ""
        let startedLine = lines.reversed().first { $0.contains("[Warning] core: Xray") && $0.contains("started") } ?? ""
        let header = [versionLine, startedLine].filter { !$0.isEmpty }.joined(separator: "\n")
        let tail = lines.suffix(200).joined(separator: "\n")
        return header.isEmpty ? tail : "=== Xray version ===\n\(header)\n=== Log (last 200 lines) ===\n\(tail)"
    }

    // MARK: - Upload

    private func upload(bundle: [String: Any], completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "\(LimmConfig.apiBase)/applog") else {
            completion(false, "bad url"); return
        }
        guard let body = try? JSONSerialization.data(withJSONObject: bundle) else {
            completion(false, "json error"); return
        }

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(LimmConfig.token)", forHTTPHeaderField: "Authorization")
        req.httpBody    = body
        req.timeoutInterval = 20

        // Use ephemeral session with no proxy — avoids "network connection was lost"
        // when VPN is stopped but system proxy (127.0.0.1:1080) is still configured.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 20
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, err in
            if let err = err { completion(false, err.localizedDescription); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let msg  = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(code == 200, "\(code) \(msg.prefix(80))")
        }.resume()
    }
}

private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
