// LimmFullTest.swift — пошаговая диагностика VPN с тимингами.
// Запуск: MainMenu → «Full Test...»
// Шаги: очистка лога → чекин #1 → старт VPN → тест IP → стоп →
//        старт VPN #2 → тест IP → чекин #2 → стоп → отправка лога.

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
        let run = { [weak self] in
            guard let self = self else { return }
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
        let run = { [weak self] in
            self?.spinner.stopAnimation(nil)
            self?.closeBtn.isEnabled = true
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

    // MARK: - Execution

    private func execute(_ w: LimmFullTestWindowController) {
        let globalStart = Date()
        var allOK = true

        /// Запустить один шаг, вывести статус + тайминг.
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

        // 2. Чекин #1 (VPN может быть выключен — l0/l1 без туннеля) ──
        step("Чекин #1") {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { LimmCheckin.shared.perform(); sem.signal() }
            let r = sem.wait(timeout: .now() + 30)
            return (true, r == .success ? "probes done" : "timeout 30s")
        }

        // 3. Запуск VPN ───────────────────────────────────────────────
        step("Запуск VPN") {
            DispatchQueue.main.sync { V2rayLaunch.startV2rayCore() }
            Thread.sleep(forTimeInterval: 4)
            let on = UserDefaults.standard.bool(forKey: "v2rayTurnOn")
            return (on, on ? "running" : "не запустился")
        }

        // 4. Тест IP #1 ───────────────────────────────────────────────
        step("Тест IP — запуск #1") { testEgressIP() }

        // 5. Остановка VPN ────────────────────────────────────────────
        step("Остановка VPN") {
            DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() }
            Thread.sleep(forTimeInterval: 2)
            let off = !UserDefaults.standard.bool(forKey: "v2rayTurnOn")
            return (off, off ? "stopped" : "всё ещё работает?")
        }

        // 6. Запуск VPN #2 ────────────────────────────────────────────
        // Extra sleep: after stop+restart, xray needs ~6s to rebind SOCKS port.
        step("Запуск VPN #2") {
            DispatchQueue.main.sync { V2rayLaunch.startV2rayCore() }
            Thread.sleep(forTimeInterval: 7)
            let on = UserDefaults.standard.bool(forKey: "v2rayTurnOn")
            return (on, on ? "running" : "не запустился")
        }

        // 7. Тест IP #2 ───────────────────────────────────────────────
        step("Тест IP — запуск #2") { testEgressIP() }

        // 8. Чекин #2 (VPN включён — l0-l4 + сервисы через туннель) ──
        step("Чекин #2") {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { LimmCheckin.shared.perform(); sem.signal() }
            let r = sem.wait(timeout: .now() + 30)
            return (true, r == .success ? "probes done" : "timeout 30s")
        }

        // 9. Финальная остановка VPN ──────────────────────────────────
        step("Остановка VPN (финал)") {
            DispatchQueue.main.sync { V2rayLaunch.stopV2rayCore() }
            Thread.sleep(forTimeInterval: 1)
            return (true, "")
        }

        // 10. Отправка лога ───────────────────────────────────────────
        step("Отправка диагностического лога") {
            let sem = DispatchSemaphore(value: 0)
            var ok = false; var detail = ""
            LimmLogReporter.shared.send { success, msg in
                ok = success; detail = msg; sem.signal()
            }
            let res = sem.wait(timeout: .now() + 50)
            if res == .timedOut { return (false, "timeout") }
            return (ok, detail)
        }

        // ── Итог ─────────────────────────────────────────────────────
        let total = Int(Date().timeIntervalSince(globalStart))
        w.appendLine("\n─────────────────────────────────────────\n")
        let verdict = allOK ? "✓ Все шаги OK" : "✗ Есть ошибки — см. выше"
        w.appendLine("\(verdict)  [всего \(total)s]\n")
        w.appendLine("── Full Test завершён \(timestamp()) ──\n")

        DispatchQueue.main.async { self.isRunning = false }
        w.markDone()
    }

    // MARK: - IP probe through SOCKS

    private func testEgressIP() -> (Bool, String) {
        let port = UserDefaults.standard.integer(forKey: "localSockPort")
        let socksPort = port > 0 ? port : 1080

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // 35s: XHTTP server closes first POST after ~20s on reconnect, client retries → need slack.
        proc.arguments = [
            "--max-time", "35", "-s",
            "--socks5", "127.0.0.1:\(socksPort)",
            "https://api.ipify.org",
        ]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            let raw  = outPipe.fileHandleForReading.readDataToEndOfFile()
            let ip   = (String(data: raw, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty else { return (false, "нет ответа от api.ipify.org") }
            let isVPN = (ip == LimmConfig.serverIP)
            let tag   = isVPN ? "= VPN ✓" : "= клиент IP ✗"
            return (isVPN, "\(ip)  \(tag)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
