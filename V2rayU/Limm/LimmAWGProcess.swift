// LimmAWGProcess.swift — manages amneziawg-go (userspace AmneziaWG TUN) as a child Process.
//
// Why this exists (read docs/TZ-amneziawg-clients.md §0.3 first):
//   The rest of V2rayU is built around xray exposing a local SOCKS proxy on :1087.
//   AmneziaWG is different: amneziawg-go is a userspace WireGuard-with-obfuscation
//   implementation that brings up a SYSTEM utun interface and routes ALL traffic
//   through it — there is NO local SOCKS proxy. So when the "FR1-awg" transport is
//   active we must (a) stop xray, (b) run amneziawg-go, (c) probe egress DIRECTLY
//   (LimmCheckin handles the probe side — see its AWG branch).
//
// Binary: amneziawg-go is NOT in the repo. CI downloads a universal (arm64+amd64)
//   build from github.com/amnezia-vpn/amneziawg-go and bundles it into the app's
//   Resources (alongside the `awg` userspace config tool). See .github/workflows/build.yml.
//
// Lifecycle model (mirrors how wireguard-go is driven on macOS):
//   1. amneziawg-go utun<N>            → creates the utun device, opens a UAPI socket,
//                                        stays in foreground (we keep the Process handle).
//   2. awg setconf utun<N> <tmpfile>   → applies [Interface]/[Peer]+obfuscation params.
//   3. ifconfig / route                → assign address 10.8.0.2/24 + default route.
//   stop() tears the device down (killing amneziawg-go removes the utun and routes).
//
// All actions log into the shared Limm log channel (NSLog, "[AWG]" prefix), same as
// the other Limm components.

import Foundation

final class LimmAWGProcess {
    static let shared = LimmAWGProcess()
    private init() {}

    // MARK: - Static AWG endpoint constants (server-side facts, see .env / awg-fr1.conf)
    // These MUST match the server's /etc/amnezia/amneziawg/awg0.conf obfuscation params.
    // The private key is the ONLY secret — it is baked from a CI secret via LimmSecrets.
    private enum AWG {
        static let interfaceName  = "utun7"          // dedicated utun index for AWG
        static let clientAddress  = "10.8.0.2/24"
        static let dns            = "1.1.1.1"
        static let serverPubKey   = "VK14+twr8V7X5hCDhHwYI4pGAMJ8pmNV0L0Xvm+6D1w="
        static let endpoint       = "45.95.175.170:51820"
        static let allowedIPs     = "0.0.0.0/0"
        static let keepalive      = "25"
        // Obfuscation (Jc/Jmin/Jmax/S1/S2/H1-H4) — must equal server.
        static let jc   = "4",  jmin = "40", jmax = "70"
        static let s1   = "0",  s2   = "0"
        static let h1   = "601260931"
        static let h2   = "578771134"
        static let h3   = "1732336072"
        static let h4   = "2588686224"
    }

    // MARK: - State
    private var process: Process?
    private let queue = DispatchQueue(label: "space.limm.awg", qos: .userInitiated)

    /// True if amneziawg-go is currently running.
    var isRunning: Bool {
        queue.sync { (process?.isRunning ?? false) }
    }

    // MARK: - Bundled binary paths
    // Bundled into Contents/Resources by CI (folder reference "awg-core", like "v2ray-core").
    private var awgGoBinary: String? {
        // Prefer Bundle resource lookup; fall back to the explicit Resources path.
        if let p = Bundle.main.path(forResource: "amneziawg-go", ofType: nil) { return p }
        let p = AppResourcesPath + "/awg-core/amneziawg-go"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// `awg` userspace config tool (wg(8)-compatible). Bundled next to amneziawg-go.
    private var awgTool: String? {
        if let p = Bundle.main.path(forResource: "awg", ofType: nil) { return p }
        let p = AppResourcesPath + "/awg-core/awg"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    // MARK: - Config

    /// Build the wg(8)-style setconf file (without [Interface] Address/DNS — those are
    /// applied separately via ifconfig/route, exactly like wg-quick does).
    /// The private key is injected from the build-time CI secret (LimmSecrets.awgPrivateKey).
    func buildConfig() -> String {
        let priv = LimmSecrets.awgPrivateKey
        return """
        [Interface]
        PrivateKey = \(priv)
        Jc = \(AWG.jc)
        Jmin = \(AWG.jmin)
        Jmax = \(AWG.jmax)
        S1 = \(AWG.s1)
        S2 = \(AWG.s2)
        H1 = \(AWG.h1)
        H2 = \(AWG.h2)
        H3 = \(AWG.h3)
        H4 = \(AWG.h4)

        [Peer]
        PublicKey = \(AWG.serverPubKey)
        Endpoint = \(AWG.endpoint)
        AllowedIPs = \(AWG.allowedIPs)
        PersistentKeepalive = \(AWG.keepalive)
        """
    }

    // MARK: - Start / Stop

    /// Start amneziawg-go and bring up the AWG tunnel.
    /// `config` defaults to buildConfig() with the baked-in private key.
    @discardableResult
    func start(config: String? = nil) -> Bool {
        queue.sync {
            // Already running → idempotent.
            if let p = process, p.isRunning {
                NSLog("[AWG] already running on \(AWG.interfaceName)")
                return true
            }

            guard !LimmSecrets.awgPrivateKey.isEmpty else {
                NSLog("[AWG] no private key baked (dev build?) — cannot start AWG")
                return false
            }
            guard let goBin = awgGoBinary else {
                NSLog("[AWG] amneziawg-go binary not found in Resources — cannot start")
                return false
            }

            let conf = config ?? buildConfig()

            // 1. Write config to a temp file (mirrors how V2rayU writes xray config.json).
            let tmpConf = NSTemporaryDirectory() + "limm_awg_\(UUID().uuidString).conf"
            do {
                try conf.write(toFile: tmpConf, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[AWG] failed to write config: \(error.localizedDescription)")
                return false
            }
            // Best-effort cleanup of the secret-bearing temp file once setconf has read it.
            defer {
                queue.asyncAfter(deadline: .now() + 5) {
                    try? FileManager.default.removeItem(atPath: tmpConf)
                }
            }

            // 2. Launch amneziawg-go in foreground; it creates the utun and a UAPI socket.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: goBin)
            p.arguments = [AWG.interfaceName]
            var env = ProcessInfo.processInfo.environment
            env["WG_PROCESS_FOREGROUND"] = "1"      // stay attached so we own the lifecycle
            env["LOG_LEVEL"] = "info"
            p.environment = env
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError  = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                if !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.isEmpty {
                    NSLog("[AWG] %@", s.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            p.terminationHandler = { proc in
                NSLog("[AWG] amneziawg-go exited (status %d)", proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                NSLog("[AWG] failed to launch amneziawg-go: \(error.localizedDescription)")
                return false
            }
            process = p
            NSLog("[AWG] amneziawg-go started on \(AWG.interfaceName) (pid \(p.processIdentifier))")

            // Give the userspace device a moment to create the UAPI socket.
            Thread.sleep(forTimeInterval: 0.5)

            // 3. Apply wg config via the `awg` tool.
            if let tool = awgTool {
                if !run(tool, ["setconf", AWG.interfaceName, tmpConf]) {
                    NSLog("[AWG] awg setconf failed — tearing down")
                    teardown()
                    return false
                }
            } else {
                NSLog("[AWG] WARNING: `awg` config tool not bundled — tunnel created but unconfigured")
            }

            // 4. Assign address + bring interface up + default route through utun.
            //    (wg-quick equivalent; amneziawg-go does not do this itself.)
            _ = run("/sbin/ifconfig", [AWG.interfaceName, "inet",
                                       AWG.clientAddress.components(separatedBy: "/").first ?? "10.8.0.2",
                                       AWG.clientAddress.components(separatedBy: "/").first ?? "10.8.0.2",
                                       "up"])
            // Route all traffic into the tunnel (AllowedIPs = 0.0.0.0/0).
            _ = run("/sbin/route", ["-n", "add", "-net", "0.0.0.0/1", "-interface", AWG.interfaceName])
            _ = run("/sbin/route", ["-n", "add", "-net", "128.0.0.0/1", "-interface", AWG.interfaceName])

            // Verify the process survived configuration.
            if !p.isRunning {
                NSLog("[AWG] amneziawg-go died during setup")
                process = nil
                return false
            }
            NSLog("[AWG] tunnel up on \(AWG.interfaceName) → \(AWG.endpoint)")
            return true
        }
    }

    /// Stop amneziawg-go and remove the AWG tunnel (utun + routes go away with the process).
    func stop() {
        queue.sync { teardown() }
    }

    // MARK: - Internals (must be called on `queue`)

    private func teardown() {
        guard let p = process else { return }
        if p.isRunning {
            NSLog("[AWG] stopping amneziawg-go (pid \(p.processIdentifier))")
            p.terminate()                  // SIGTERM → amneziawg-go removes utun + routes
            // Give it a moment; force-kill if it lingers.
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning {
                NSLog("[AWG] amneziawg-go did not exit — SIGKILL")
                kill(p.processIdentifier, SIGKILL)
            }
        }
        process = nil
        NSLog("[AWG] stopped")
    }

    /// Run a helper command synchronously, logging failures. Returns true on exit 0.
    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run(); p.waitUntilExit()
        } catch {
            NSLog("[AWG] run \(path) failed: \(error.localizedDescription)")
            return false
        }
        if p.terminationStatus != 0 {
            let msg = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("[AWG] %@ %@ → exit %d %@", path, args.joined(separator: " "),
                  p.terminationStatus, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return p.terminationStatus == 0
    }
}
