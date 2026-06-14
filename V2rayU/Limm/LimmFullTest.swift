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
                    guard waitForSocks(port: hy2Port, maxSec: 20) else {
                        LimmHy2Process.shared.stop()
                        Thread.sleep(forTimeInterval: 0.5)
                        return (false, "SOCKS :1088 не поднялся за 20s")
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

        // 4.5 + 5 (объединено). Финальный чекин (заполняет Статус/Сервисы/Пинг на дашборде)
        // И отправка лога идут через рабочий VPN-туннель — прямой RU→Cloudflare путь флапает.
        // Перебираем рабочие профили по возрастанию latency: на каждом поднимаем туннель,
        // делаем чекин (один раз, как только удался) и шлём лог; СТОП, как только ЛОГ доставлен.
        // Так hy2 (быстрый egress, но медленный/блокируемый к limm.space/api) не съедает
        // доставку — следующий xray-профиль довезёт и чекин, и лог.
        //
        // performQuick() (не perform()) — прямой POST без curl-проб, <1s, не вешает шаг.
        var logUploaded = false
        var checkinDone = false
        // Кандидаты-носители для чекина+лога. Приоритет НЕ по чистой скорости:
        //   1) xray раньше hy2 — hy2 рвёт длинную заливку лога (sustained upload);
        //   2) НЕ-DE1 раньше DE1 — limm.space живёт на DE1, заливка через DE1-туннель
        //      деградирует/хайрпинит (короткий чекин проходит, длинный лог — нет);
        //   3) затем по latency.
        // Перебираем по очереди, пока лог не доставлен → обычно уходит с 1-й попытки (FR1).
        let workingProfiles: [(server: V2rayItem, label: String, isHy2: Bool, latency: Int?)] =
            profileResults.enumerated()
                .filter { $0.element.ok }
                .map { entry -> (server: V2rayItem, label: String, isHy2: Bool, latency: Int?) in
                    let s = servers[entry.offset]
                    let lbl = s.remark.isEmpty ? s.name : s.remark
                    let isH = LimmAutoSwitch.isHy2Transport(lbl) || LimmAutoSwitch.isHy2Transport(s.name)
                    return (s, lbl, isH, entry.element.latencyMs)
                }
                .sorted { a, b in
                    if a.isHy2 != b.isHy2 { return !a.isHy2 }
                    let aDE1 = isDe1(a.server), bDE1 = isDe1(b.server)
                    if aDE1 != bDE1 { return !aDE1 }
                    return (a.latency ?? Int.max) < (b.latency ?? Int.max)
                }

        w.appendLine("\n")
        if workingProfiles.isEmpty {
            // Нет рабочих профилей — последний шанс: прямой аплоад (RU→CF, ненадёжно).
            step("Отправка лога (фолбэк · прямой)") {
                let sem = DispatchSemaphore(value: 0)
                var ok = false; var detail = ""
                LimmLogReporter.shared.send { success, msg in
                    ok = success; detail = msg; sem.signal()
                }
                let res = sem.wait(timeout: .now() + 38)
                if res == .timedOut { return (false, "timeout") }
                return (ok, detail)
            }
        } else {
            for prof in workingProfiles {
                if logUploaded { break }
                step("Чекин+лог (VPN · \(prof.label))") {
                    // Поднять туннель профиля.
                    if prof.isHy2 {
                        DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() }
                        guard LimmHy2Process.shared.start(transport: prof.label) else {
                            Thread.sleep(forTimeInterval: 0.5)
                            return (false, "hy2 не запустился")
                        }
                    } else {
                        DispatchQueue.main.sync {
                            UserDefaults.set(forKey: .v2rayCurrentServerName, value: prof.server.name)
                            V2rayLaunch.startV2rayCore()
                        }
                    }
                    let sp = prof.isHy2 ? LimmHy2Process.socksPort
                                        : (UserDefaults.standard.integer(forKey: "localSockPort")).nonzero ?? 1080
                    func teardown() {
                        if prof.isHy2 { LimmHy2Process.shared.stop() }
                        else { DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() } }
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    guard waitForSocks(port: sp, maxSec: 20) else {
                        teardown()
                        return (false, "SOCKS не поднялся за 20s")
                    }

                    // Чекин (один раз — как только удался; заполняет дашборд). Не фатально.
                    var checkinNote = "чекин уже ok"
                    if !checkinDone {
                        let sem = DispatchSemaphore(value: 0)
                        var code = 0
                        LimmCheckin.shared.performQuick(egressLatencyMs: prof.latency) { c, _ in
                            code = c; sem.signal()
                        }
                        if sem.wait(timeout: .now() + 10) == .timedOut {
                            checkinNote = "чекин timeout"
                        } else if code == 200 {
                            checkinDone = true; checkinNote = "чекин ok"
                        } else {
                            checkinNote = "чекин \(code)"
                        }
                    }

                    // Лог (критичный артефакт) — пока туннель поднят.
                    let lsem = DispatchSemaphore(value: 0)
                    var logOk = false; var logDetail = ""
                    LimmLogReporter.shared.send(socksPort: sp) { ok, msg in
                        logOk = ok; logDetail = msg; lsem.signal()
                    }
                    let lres = lsem.wait(timeout: .now() + 55)
                    teardown()

                    if logOk { logUploaded = true }
                    let logNote = lres == .timedOut ? "лог timeout"
                                : (logOk ? "лог ушёл" : "лог: \(logDetail.prefix(30))")
                    return (logOk, "\(checkinNote) · \(logNote)")
                }
            }
        }

        // Вернуть исходный профиль и автопереключение (перебор мог оставить последний).
        // VPN НЕ запускаем здесь — startV2rayCore может заблокировать main thread; рестарт
        // делаем ПОСЛЕ markDone (см. ниже).
        DispatchQueue.main.sync {
            if !savedServer.isEmpty {
                UserDefaults.set(forKey: .v2rayCurrentServerName, value: savedServer)
            }
            if wasAutoSwitch { LimmAutoSwitch.shared.enable() }
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
