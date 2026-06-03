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
        func curl(_ args: [String], timeout: Int = 12) -> (String, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["--max-time", "\(timeout)", "-s", "-L",
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

        func directOk(_ url: String) -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["--max-time", "6", "-s", "-o", "/dev/null", url]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let c = Int(p.terminationStatus)
            return (c == 0 || c == 52 || c == 35) ? 1 : 0
        }

        let l0 = directOk("http://8.8.8.8")
        let l1 = directOk("http://\(LimmConfig.serverIP):\(LimmConfig.serverPort)")

        let (_, ip) = curl(["--socks5", socks, "https://api.ipify.org"], timeout: 15)
        let egressIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let l4 = egressIP == LimmConfig.serverIP ? 1 : 0

        func svc(_ url: String, markers: [String]) -> String {
            let (code, body) = curl(["--socks5", socks, url], timeout: 15)
            if code == "000" { return "down" }
            if code == "451" { return "blocked" }
            let lower = body.lowercased()
            for m in markers { if lower.contains(m) { return "blocked" } }
            return "ok"
        }

        return [
            "l0": l0, "l1": l1, "l4": l4,
            "egress_ip": egressIP,
            "vpn_running": UserDefaults.standard.bool(forKey: "v2rayTurnOn") ? 1 : 0,
            "tg":    svc("https://web.telegram.org/", markers: []),
            "ggl":   svc("https://www.google.com/search?q=test", markers: []),
            "chgpt": svc("https://chatgpt.com/", markers: ["unsupported_country",
                                                             "not available in your country"]),
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
        let logPath = NSHomeDirectory() + "/.V2rayU/v2ray.log"
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else { return "" }
        // Last 200 lines
        let lines = text.components(separatedBy: "\n")
        return lines.suffix(200).joined(separator: "\n")
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
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { data, resp, err in
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
