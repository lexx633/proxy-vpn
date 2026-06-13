// LimmFullTest.swift — пошаговая диагностика VPN с тимингами.
// Запуск: MainMenu → «Full Test...»
// Шаги: очистка лога → чекин (без VPN) → цикл по профилям (start→IP→stop) → отправка лога.

import Cocoa

// MARK: - Window

final class LimmFullTestWindowController: NSWindowController {

    private let scrollView = NSScrollView()
    private let textView   = NSTextView()
    private let closeBtn   = NSButton(title: "Закрыть", target: nil, action: nil)
    private let spinner    = NSProgressIndicator()

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false)
        win.title                    = "limm VPN — Full Test"
        win.isReleasedWhenClosed     = false
        win.minSize                  = NSSize(width: 400, height: 300)
        win.center()
        self.init(window: win)
        buildUI()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // ── Scroll + text view ────────────────────────────────────────
        // NSTextView inside NSScrollView needs explicit sizing to render text.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller   = true
        scrollView.borderType            = .bezelBorder
        scrollView.autohidesScrollers    = true
        cv.addSubview(scrollView)

        let initialW: CGFloat = 580
        textView.frame                   = NSRect(x: 0, y: 0, width: initialW, height: 0)
        textView.isEditable              = false
        textView.isRichText              = true
        textView.isSelectable            = true
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask        = [.width]
        textView.minSize                 = NSSize(width: 0, height: 0)
        textView.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: initialW,
                                                        height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font                    = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor         = NSColor(srgbRed: 0.05, green: 0.08, blue: 0.11, alpha: 1)
        textView.drawsBackground         = true
        textView.textContainerInset      = NSSize(width: 8, height: 8)
        scrollView.documentView          = textView

        // ── Spinner ───────────────────────────────────────────────────
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style                    = .spinning
        spinner.controlSize              = .small
        spinner.isDisplayedWhenStopped   = false
        spinner.startAnimation(nil)
        cv.addSubview(spinner)

        // ── Close button ──────────────────────────────────────────────
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle              = .rounded
        closeBtn.isEnabled               = false
        closeBtn.target                  = self
        closeBtn.action                  = #selector(closeWindow)
        cv.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: closeBtn.topAnchor, constant: -10),

            spinner.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),

            closeBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -10),
            closeBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -10),
            closeBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    // MARK: - Logging

    func appendLine(_ text: String, color: NSColor? = nil) {
        // Strong capture [self]: keeps the window controller alive until the closure
        // executes on the main thread. Without this, execute() returning on the
        // background thread may release the last strong reference to the controller
        // before main processes the queued closures, causing [weak self] to be nil
        // and silently dropping all text (including the footer) + blocking markDone.
        let run = { [self] in
            let c = color ?? self.palette(text)
            let attrs: [NSAttributedString.Key: Any] = [
                .font:            NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: c,
            ]
            self.textView.textStorage?.append(NSAttributedString(string: text, attributes: attrs))
            self.textView.scrollToEndOfDocument(nil)
        }
        Thread.isMainThread ? run() : DispatchQueue.main.async(execute: run)
    }

    private func palette(_ t: String) -> NSColor {
        let lead = t.trimmingCharacters(in: .whitespaces).prefix(1)
        switch lead {
        case "✓": return NSColor(srgbRed: 0.30, green: 0.90, blue: 0.55, alpha: 1)
        case "✗": return NSColor(srgbRed: 1.00, green: 0.35, blue: 0.35, alpha: 1)
        case "⏳": return NSColor(srgbRed: 0.55, green: 0.70, blue: 0.85, alpha: 1)
        case "─": return NSColor(srgbRed: 0.35, green: 0.40, blue: 0.48, alpha: 1)
        default:  return NSColor(srgbRed: 0.80, green: 0.85, blue: 0.90, alpha: 1)
        }
    }

    func markDone() {
        // Strong capture [self] — same reason as appendLine above.
        let run = { [self] in
            self.spinner.stopAnimation(nil)
            self.closeBtn.isEnabled = true
        }
        Thread.isMainThread ? run() : DispatchQueue.main.async(execute: run)
    }

    @objc private func closeWindow() { window?.orderOut(nil) }
}

// MARK: - Runner

final class LimmFullTest {
    static let shared = LimmFullTest()
    private var isRunning = false
    private weak var wc: LimmFullTestWindowController?

    func run() {
        guard !isRunning else {
            DispatchQueue.main.async { self.wc?.window?.makeKeyAndOrderFront(nil) }
            return
        }
        isRunning = true

        let w = LimmFullTestWindowController()
        wc = w
        DispatchQueue.main.async {
            showDock(state: true)
            w.showWindow(nil)
            w.window?.makeKeyAndOrderFront(nil)
        }

        DispatchQueue.global(qos: .userInitiated).async { self.execute(w) }
    }

    // MARK: - Fulltest results upload

    private func postFullTestResults(_ profiles: [(name: String, ok: Bool, latencyMs: Int?)]) {
        guard !profiles.isEmpty else { return }
        let token = LimmConfig.token
        guard !token.isEmpty, token != "__LIMM_TOKEN__" else { return }
        let profilesArr = profiles.map { p -> [String: Any] in
            var d: [String: Any] = ["name": p.name, "ok": p.ok ? 1 : 0]
            if let ms = p.latencyMs { d["latency_ms"] = ms }
            return d
        }
        let payload: [String: Any] = [
            "client_uid": LimmConfig.clientUID(),
            "kind": LimmConfig.clientKind,
            "profiles": profilesArr,
        ]
        guard let url  = URL(string: "\(LimmConfig.apiBase)/fulltest"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 20
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        // P-H2: capture session to call finishTasksAndInvalidate(); log non-200 for observability.
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { _, resp, err in
            defer { session.finishTasksAndInvalidate() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err = err { NSLog("[Limm] postFullTestResults error: %@", err.localizedDescription) }
            else if code != 200 { NSLog("[Limm] postFullTestResults: server returned %d", code) }
        }.resume()
    }

    // MARK: - Execution

    private func execute(_ w: LimmFullTestWindowController) {
        let globalStart = Date()
        var allOK = true

        func step(_ name: String, _ body: () -> (Bool, String)) {
            w.appendLine("⏳ \(name)…\n")
            let t = Date()
            let (ok, detail) = body()
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            let mark = ok ? "✓" : "✗"
            let extra = detail.isEmpty ? "" : "  (\(detail))"
            w.appendLine("\(mark) \(name)\(extra)  [\(ms)ms]\n")
            if !ok { allOK = false }
        }

        w.appendLine("── Full Test начат \(timestamp()) ──\n\n")

        // 1. Очистить лог ─────────────────────────────────────────────
        step("Очистка лога") {
            DispatchQueue.main.sync { V2rayLaunch.clearLogFile() }
            return (true, "")
        }

        // 2. Чекин без VPN (l0/l1 direct, SOCKS-пробы пропускаются → ~10s) ─
        step("Чекин (без VPN)") {
            let sem = DispatchSemaphore(value: 0)
            var httpCode = 0; var httpMsg = ""
            LimmCheckin.shared.perform(overrideVpnOn: false) { code, msg in
                httpCode = code; httpMsg = msg
                sem.signal()
            }
            let r = sem.wait(timeout: .now() + 25)
            if r == .timedOut { return (false, "timeout 25s") }
            return (httpCode == 200, httpCode == 200 ? "ok \(httpCode)" : "fail \(httpCode) \(httpMsg.prefix(40))")
        }

        // 3. Цикл по профилям ─────────────────────────────────────────
        // Получаем список на main-потоке, затем тестируем каждый профиль.
        // DE1 первым в полном тесте (приоритетная нода), порядок внутри групп сохраняется.
        // V2rayU не переставляет существующие серверы при обновлении подписки, поэтому
        // локальный порядок мог застрять с FR1 впереди — пересортируем здесь явно.
        let allServers = DispatchQueue.main.sync { V2rayServer.list() }.filter { $0.isValid }
        func isDe1(_ s: V2rayItem) -> Bool {
            (s.remark.isEmpty ? s.name : s.remark).uppercased().contains("DE1")
        }
        let servers = allServers.filter { isDe1($0) } + allServers.filter { !isDe1($0) }
        let savedServer = UserDefaults.standard.string(forKey: "v2rayCurrentServerName") ?? ""
        let wasVpnOn = UserDefaults.standard.bool(forKey: "v2rayTurnOn")
        let wasAutoSwitch = LimmAutoSwitch.shared.isEnabled
        // Останавливаем автопереключение на время теста
        if wasAutoSwitch { DispatchQueue.main.sync { LimmAutoSwitch.shared.stop() } }

        w.appendLine("\n── Профили (\(servers.count)) ──\n\n")

        var profileResults: [(name: String, ok: Bool, latencyMs: Int?)] = []

        for server in servers {
            let label = server.remark.isEmpty ? server.name : server.remark
            let isHy2 = LimmAutoSwitch.isHy2Transport(label) || LimmAutoSwitch.isHy2Transport(server.name)
            var profileOk = false
            var profileMs: Int? = nil

            step("▸ \(label)") {
                if isHy2 {
                    // ── Hysteria2 profile: bypass xray, use hy2 binary + SOCKS :1088 ──
                    DispatchQueue.main.sync {
                        UserDefaults.set(forKey: .v2rayCurrentServerName, value: server.name)
                        // Do NOT call startV2rayCore() — xray crashes on hysteria2 config.
                    }
                    // Stop any running xray/hy2 first.
                    DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() }
                    if LimmHy2Process.shared.isRunning { LimmHy2Process.shared.stop() }

                    let ok = LimmHy2Process.shared.start(transport: label)
                    guard ok else {
                        Thread.sleep(forTimeInterval: 0.5)
                        return (false, "hysteria2 binary не запустился")
                    }

                    let hy2Port = LimmHy2Process.socksPort
                    guard waitForSocks(port: hy2Port, maxSec: 12) else {
                        LimmHy2Process.shared.stop()
                        Thread.sleep(forTimeInterval: 0.5)
                        return (false, "SOCKS :1088 не поднялся за 12s")
                    }

                    let t0 = Date()
                    let (ok2, detail) = testEgressIP(socksPortOverride: hy2Port)
                    if ok2 { profileMs = Int(Date().timeIntervalSince(t0) * 1000) }
                    profileOk = ok2

                    LimmHy2Process.shared.stop()
                    Thread.sleep(forTimeInterval: 0.5)
                    return (ok2, detail)
                } else {
                    // ── Standard xray profile ──────────────────────────────────────
                    DispatchQueue.main.sync {
                        UserDefaults.set(forKey: .v2rayCurrentServerName, value: server.name)
                        V2rayLaunch.startV2rayCore()
                    }
                    let port = UserDefaults.standard.integer(forKey: "localSockPort").nonzero ?? 1080

                    guard waitForSocks(port: port, maxSec: 10) else {
                        DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() }
                        Thread.sleep(forTimeInterval: 0.5)
                        return (false, "SOCKS не поднялся за 10s")
                    }

                    let t0 = Date()
                    let (ok, detail) = testEgressIP()
                    if ok { profileMs = Int(Date().timeIntervalSince(t0) * 1000) }
                    profileOk = ok

                    DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() }
                    Thread.sleep(forTimeInterval: 0.5)
                    return (ok, detail)
                }
            }
            profileResults.append((name: label, ok: profileOk, latencyMs: profileMs))
        }

        // 4. Загружаем результаты профилей на сервер ─────────────────
        postFullTestResults(profileResults)

        // 4.5. Чекин с рабочим профилем → заполняет Статус/Сервисы/Пинг в дашборде.
        // Начало Full Test делало чекин с vpnOn=false; здесь отправляем финальный
        // чекин с поднятым VPN чтобы дашборд не застрял в «VPN выключен».
        //
        // ВАЖНО: не используем perform() — он запускает все curl-пробы синхронно
        // (L1 ×3 по 5s при ISP-блоке = 15s + L4 + tunnel×3 + services = до 70s),
        // что вешает шаг. Вместо этого — performQuick(): прямой POST без проб, <1s.
        var logUploaded = false   // true когда лог ушёл через рабочий туннель (см. ниже)
        // «Лучший» = самый быстрый рабочий профиль (min latency), а НЕ первый по списку — иначе
        // при DE1-first чекин/дашборд шли бы через медленный DE1. Порядок теста (DE1 сверху) на это не влияет.
        let bestIdx = profileResults.enumerated()
            .filter { $0.element.ok }
            .min { ($0.element.latencyMs ?? Int.max) < ($1.element.latencyMs ?? Int.max) }?
            .offset
        if let bestIdx = bestIdx {
            let bestServer  = servers[bestIdx]
            let bestLabel   = bestServer.remark.isEmpty ? bestServer.name : bestServer.remark
            let bestLatency = profileResults[bestIdx].latencyMs   // egress latency из теста
            let bestIsHy2   = LimmAutoSwitch.isHy2Transport(bestLabel) ||
                              LimmAutoSwitch.isHy2Transport(bestServer.name)
            w.appendLine("\n")
            step("Чекин (VPN on · \(bestLabel))") {
                DispatchQueue.main.sync {
                    UserDefaults.set(forKey: .v2rayCurrentServerName, value: bestServer.name)
                }
                let socksPort: Int
                if bestIsHy2 {
                    // For hy2: start hysteria2 binary, wait for SOCKS :1088
                    DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() }
                    guard LimmHy2Process.shared.start(transport: bestLabel) else {
                        Thread.sleep(forTimeInterval: 0.5)
                        return (false, "hysteria2 не запустился для финального чекина")
                    }
                    socksPort = LimmHy2Process.socksPort
                } else {
                    DispatchQueue.main.sync { V2rayLaunch.startV2rayCore() }
                    socksPort = (UserDefaults.standard.integer(forKey: "localSockPort")).nonzero ?? 1080
                }

                guard waitForSocks(port: socksPort, maxSec: 25) else {
                    if bestIsHy2 { LimmHy2Process.shared.stop() }
                    else { DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() } }
                    Thread.sleep(forTimeInterval: 0.5)
                    return (false, "SOCKS не поднялся за 25s")
                }
                let sem = DispatchSemaphore(value: 0)
                var httpCode = 0; var httpMsg = ""
                LimmCheckin.shared.performQuick(egressLatencyMs: bestLatency) { code, msg in
                    httpCode = code; httpMsg = msg; sem.signal()
                }
                let r = sem.wait(timeout: .now() + 10)

                // Лог отправляем ПОКА туннель ещё поднят на рабочем профиле — через SOCKS
                // (--socks5), т.к. прямой RU→Cloudflare путь флапает. Гасим ядро только после.
                let lsem = DispatchSemaphore(value: 0)
                var logOk = false; var logDetail = ""
                LimmLogReporter.shared.send(socksPort: socksPort) { ok, msg in
                    logOk = ok; logDetail = msg; lsem.signal()
                }
                _ = lsem.wait(timeout: .now() + 40)
                logUploaded = logOk

                if bestIsHy2 { LimmHy2Process.shared.stop() }
                else { DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() } }
                Thread.sleep(forTimeInterval: 0.5)
                let logNote = logOk ? "лог ушёл (туннель)" : "лог нет: \(logDetail.prefix(30))"
                if r == .timedOut { return (false, "timeout 10s · \(logNote)") }
                let base = httpCode == 200 ? "ok \(httpCode)" : "fail \(httpCode) \(httpMsg.prefix(40))"
                return (httpCode == 200, "\(base) · \(logNote)")
            }
        }

        // Восстанавливаем исходный профиль и автопереключение.
        // VPN НЕ запускаем здесь — startV2rayCore может заблокировать main thread
        // и тогда appendLine (DispatchQueue.main.async) не выполнится → тест зависнет.
        // Перезапуск делаем ПОСЛЕ markDone (см. ниже).
        DispatchQueue.main.sync {
            if !savedServer.isEmpty {
                UserDefaults.set(forKey: .v2rayCurrentServerName, value: savedServer)
            }
            if wasAutoSwitch { LimmAutoSwitch.shared.enable() }
        }

        // 5. Фолбэк-аплоад лога прямым каналом (VPN выкл) — ТОЛЬКО если через туннель не ушёл
        //    (ни один профиль не ожил, либо tunnel-upload не удался).
        if !logUploaded {
            w.appendLine("\n")
            step("Отправка лога (фолбэк · прямой)") {
                let sem = DispatchSemaphore(value: 0)
                var ok = false; var detail = ""
                LimmLogReporter.shared.send { success, msg in
                    ok = success; detail = msg; sem.signal()
                }
                let res = sem.wait(timeout: .now() + 30)
                if res == .timedOut { return (false, "timeout") }
                return (ok, detail)
            }
        }

        // ── Итог ─────────────────────────────────────────────────────
        let total = Int(Date().timeIntervalSince(globalStart))
        w.appendLine("\n─────────────────────────────────────────\n")
        let verdict = allOK ? "✓ Все шаги OK" : "✗ Есть ошибки — см. выше"
        w.appendLine("\(verdict)  [всего \(total)s]\n")
        w.appendLine("── Full Test завершён \(timestamp()) ──\n")

        DispatchQueue.main.async { self.isRunning = false }
        w.markDone()

        // Перезапускаем VPN если он был включён до теста — делаем это ПОСЛЕ markDone
        // (async, не блокируя фоновый поток и не мешая main thread обрабатывать appendLine).
        if wasVpnOn {
            DispatchQueue.main.async { V2rayLaunch.startV2rayCore() }
        }
    }

    // MARK: - IP probe through SOCKS

    /// XHTTP может вернуть пустой ответ на первый запрос (~15s timeout) — делаем до 3 попыток.
    private let egressRetryMax = 3

    /// - Parameter socksPortOverride: if set, uses this port instead of reading UserDefaults.
    ///   Pass `LimmHy2Process.socksPort` (1088) for hy2 profiles.
    private func testEgressIP(socksPortOverride: Int? = nil) -> (Bool, String) {
        let port = UserDefaults.standard.integer(forKey: "localSockPort")
        let socksPort = socksPortOverride ?? (port > 0 ? port : 1080)

        for attempt in 1...egressRetryMax {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            // 20s per attempt: XHTTP may delay first response up to ~15s.
            proc.arguments = [
                "--max-time", "20", "-s",
                "--socks5", "127.0.0.1:\(socksPort)",
                "https://api.ipify.org",
            ]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = Pipe()

            do {
                try proc.run()
                proc.waitUntilExit()
                let raw = outPipe.fileHandleForReading.readDataToEndOfFile()
                let ip  = (String(data: raw, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !ip.isEmpty {
                    let isVPN = LimmConfig.isOurEgress(ip)
                    let tag   = isVPN ? "VPN ✓" : "не VPN ✗"
                    return (isVPN, tag)
                }
            } catch {
                return (false, error.localizedDescription)
            }

            if attempt < egressRetryMax {
                NSLog("[Limm] testEgressIP: attempt %d/%d empty, retrying", attempt, egressRetryMax)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return (false, "нет ответа от api.ipify.org (\(egressRetryMax) попытки)")
    }

    // MARK: - Helpers

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// Poll 127.0.0.1:port every 300ms until it accepts a TCP connection or maxSec elapses.
    private func waitForSocks(port: Int, maxSec: Double) -> Bool {
        let deadline = Date().addingTimeInterval(maxSec)
        while Date() < deadline {
            if socksPortOpen(port: port) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func socksPortOpen(port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["--max-time", "1", "-s", "-o", "/dev/null",
                       "--connect-timeout", "1", "http://127.0.0.1:\(port)"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        // P-M1: explicit do/catch — if curl fails to launch, terminationStatus defaults to 0
        // which is in the success set {0,52,56} and would falsely report SOCKS as open.
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let c = Int(p.terminationStatus)
        return c == 0 || c == 52 || c == 56
    }
}

private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
