// LimmHy2Process.swift — manages hysteria2 binary as a child Process.
//
// Hysteria2 is a QUIC-based proxy protocol not natively supported by Xray-core.
// When DE1-hy2 or FR1-hy2 transport is selected:
//   (a) stop xray  (b) write YAML config  (c) run hysteria2 binary
//   (d) probe L2/L3/L4 through its SOCKS5 on :1088.
//
// Binary: hysteria2 is NOT in the repo. CI downloads a universal (arm64+amd64)
//   release from github.com/apernet/hysteria and bundles it into the app's
//   Resources (folder reference "hy2-core"). See .github/workflows/build.yml.
//   Falls back gracefully if the binary is absent (e.g. dev builds).
//
// SOCKS port: 1088 (xray uses :1087; hy2 gets :1088 to avoid conflict).
//
// Mirrors LimmAWGProcess.swift structure (AWG uses TUN; hy2 uses SOCKS5).

import Foundation

final class LimmHy2Process {
    static let shared = LimmHy2Process()
    private init() {}

    // MARK: - SOCKS port exposed by hysteria2 locally
    static let socksPort = 1088

    // MARK: - Per-server constants (passwords are in sub-ru.json, not secrets)
    private enum HY2 {
        // DE1 — 77.90.52.123
        static let de1Server       = "77.90.52.123:443"
        static let de1Auth         = "238e538743fa7e42552457dd95f1a4ef"
        static let de1ObfsPassword = "725574d0caabd0fe07858a649f18fa53"
        // FR1 — 45.95.175.170
        static let fr1Server       = "45.95.175.170:443"
        static let fr1Auth         = "wT2HgRNnTJauLQd6eHjpfBd7"
        static let fr1ObfsPassword = "FKtE5ePLMt5USnNgGZVQMhnB"
        // TLS (both servers share SNI; insecure=true, pinSHA256 omitted for simplicity)
        static let tlsSNI          = "www.bing.com"
    }

    // MARK: - State
    private var process: Process?
    private let queue = DispatchQueue(label: "space.limm.hy2", qos: .userInitiated)

    /// True if hysteria2 process is currently running.
    var isRunning: Bool {
        queue.sync { (process?.isRunning ?? false) }
    }

    /// Transport name that is currently running (nil if stopped).
    private(set) var activeTransport: String?

    // MARK: - Bundled binary

    private var hy2Binary: String? {
        if let p = Bundle.main.path(forResource: "hysteria2", ofType: nil) { return p }
        let p = AppResourcesPath + "/hy2-core/hysteria2"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    // MARK: - Config builder

    /// Build a hysteria2 YAML client config for the given transport tag.
    func buildConfig(for transport: String) -> String {
        let isDE1 = transport.uppercased().contains("DE1")
        let server       = isDE1 ? HY2.de1Server       : HY2.fr1Server
        let auth         = isDE1 ? HY2.de1Auth         : HY2.fr1Auth
        let obfsPassword = isDE1 ? HY2.de1ObfsPassword : HY2.fr1ObfsPassword
        return """
        server: \(server)

        auth: \(auth)

        tls:
          insecure: true
          sni: \(HY2.tlsSNI)

        obfs:
          type: salamander
          salamander:
            password: \(obfsPassword)

        socks5:
          listen: 127.0.0.1:\(LimmHy2Process.socksPort)
        """
    }

    // MARK: - Start / Stop

    /// Start hysteria2 for the given transport tag.
    /// Idempotent if already running the same transport.
    @discardableResult
    func start(transport: String) -> Bool {
        return queue.sync { _start(transport: transport) }
    }

    func stop() {
        queue.sync { teardown() }
    }

    // MARK: - Internals (must be called on `queue`)

    private func _start(transport: String) -> Bool {
        // Idempotent only for the SAME transport; otherwise tear down and switch.
        if let p = process, p.isRunning {
            if activeTransport == transport {
                NSLog("[HY2] already running same transport (%@)", transport)
                return true
            }
            NSLog("[HY2] switching transport %@ -> %@", activeTransport ?? "?", transport)
            teardown()
        }

        guard let bin = hy2Binary else {
            NSLog("[HY2] hysteria2 binary not found in Resources — cannot start. " +
                  "FR1-hy2/DE1-hy2 requires hysteria2 bundled via CI (hy2-core/).")
            return false
        }

        // A stray hysteria2 (from a crashed run or an untracked process) may still
        // hold :1088, which makes the new client fail to bind its SOCKS listener
        // ("SOCKS :1088 не поднялся"). Free the port before launching.
        freeSocksPort(binary: bin)

        // Write YAML config to a temp file.
        let conf    = buildConfig(for: transport)
        let tmpConf = NSTemporaryDirectory() + "limm_hy2_\(UUID().uuidString).yaml"
        do {
            try conf.write(toFile: tmpConf, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[HY2] failed to write config: %@", error.localizedDescription)
            return false
        }
        // Clean up temp config after hysteria2 has read it.
        defer {
            queue.asyncAfter(deadline: .now() + 15) {
                try? FileManager.default.removeItem(atPath: tmpConf)
            }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["client", "--config", tmpConf]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.isEmpty {
                NSLog("[HY2] %@", s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        p.terminationHandler = { [weak self] proc in
            NSLog("[HY2] hysteria2 exited (status %d)", proc.terminationStatus)
            self?.queue.async { if self?.process === proc { self?.process = nil; self?.activeTransport = nil } }
        }
        do {
            try p.run()
        } catch {
            NSLog("[HY2] failed to launch hysteria2: %@", error.localizedDescription)
            return false
        }
        process = p
        activeTransport = transport
        NSLog("[HY2] started (transport: %@, pid: %d, socks5: :%d)",
              transport, p.processIdentifier, LimmHy2Process.socksPort)

        // Give hysteria2 a moment to bind its SOCKS5 port.
        Thread.sleep(forTimeInterval: 1.0)

        if !p.isRunning {
            NSLog("[HY2] hysteria2 died immediately — check config or binary")
            process = nil
            activeTransport = nil
            return false
        }
        return true
    }

    /// True if something is already listening on the local SOCKS port.
    /// Uses curl --connect-timeout (same proven approach as LimmFullTest).
    private func socksPortInUse() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["--max-time", "1", "-s", "-o", "/dev/null",
                       "--connect-timeout", "1", "http://127.0.0.1:\(LimmHy2Process.socksPort)"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let c = Int(p.terminationStatus)
        // 0/52/56 => connection established (something is listening)
        return c == 0 || c == 52 || c == 56
    }

    /// Run a CLI tool to completion, ignoring output/errors.
    private func runTool(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch {
            NSLog("[HY2] %@ failed: %@", path, error.localizedDescription)
        }
    }

    /// SIGKILL whatever process currently holds the given TCP port (by port, any
    /// name) — the most reliable way to clear a stuck :1088 from a prior run.
    private func killByPort(_ port: Int) {
        let out = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-ti", "tcp:\(port)"]
        p.standardOutput = out; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return }
        for tok in s.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
            if let pid = Int32(tok.trimmingCharacters(in: .whitespaces)), pid > 0 {
                NSLog("[HY2] killing pid %d holding :%d", pid, port)
                kill(pid, SIGKILL)
            }
        }
    }

    /// Ensure the SOCKS port is free before launching. Kills by port (lsof, any
    /// process) AND pkills stray hysteria2 from our binary, then waits for release.
    private func freeSocksPort(binary: String) {
        if !socksPortInUse() { return }
        NSLog("[HY2] :%d busy — freeing", LimmHy2Process.socksPort)
        killByPort(LimmHy2Process.socksPort)
        runTool("/usr/bin/pkill", ["-f", binary])
        let deadline = Date().addingTimeInterval(4)
        while socksPortInUse() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            killByPort(LimmHy2Process.socksPort)
        }
    }

    private func teardown() {
        guard let p = process else { return }
        if p.isRunning {
            NSLog("[HY2] stopping hysteria2 (pid %d)", p.processIdentifier)
            p.terminate()
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning {
                NSLog("[HY2] hysteria2 did not exit — SIGKILL")
                kill(p.processIdentifier, SIGKILL)
            }
        }
        process = nil
        activeTransport = nil
        // Wait for the SOCKS port to actually be released so a subsequent hy2
        // start (e.g. DE1-hy2 -> FR1-hy2 back-to-back) doesn't fail to bind :1088.
        let deadline = Date().addingTimeInterval(3)
        while socksPortInUse() && Date() < deadline { Thread.sleep(forTimeInterval: 0.15) }
        if socksPortInUse() { killByPort(LimmHy2Process.socksPort) }
        NSLog("[HY2] stopped")
    }
}
