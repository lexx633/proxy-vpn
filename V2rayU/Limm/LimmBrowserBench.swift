// LimmBrowserBench.swift — browser-based bench built into V2rayU.
// Loads test URLs via WKWebView (= system proxy = VPN tunnel), extracts
// Navigation Timing API, posts results to /api/fulltest.
// Launch: MainMenu → «Browser Bench…»

import Cocoa
import WebKit

// MARK: - Window Controller

final class LimmBrowserBenchWindowController: NSWindowController {

    private let scrollView = NSScrollView()
    private let textView   = NSTextView()
    private let closeBtn   = NSButton(title: "Закрыть", target: nil, action: nil)
    private let spinner    = NSProgressIndicator()

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false)
        win.title                = "limm VPN — Browser Bench"
        win.isReleasedWhenClosed = false
        win.minSize              = NSSize(width: 420, height: 260)
        win.center()
        self.init(window: win)
        buildUI()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // ── Scroll + text view ────────────────────────────────────────
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller  = true
        scrollView.borderType           = .bezelBorder
        scrollView.autohidesScrollers   = true
        cv.addSubview(scrollView)

        let initialW: CGFloat = 600
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
        textView.textContainer?.containerSize =
            NSSize(width: initialW, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font                    = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor         = NSColor(srgbRed: 0.05, green: 0.08, blue: 0.11, alpha: 1)
        textView.drawsBackground         = true
        textView.textContainerInset      = NSSize(width: 8, height: 8)
        scrollView.documentView          = textView

        // ── Spinner ───────────────────────────────────────────────────
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style                  = .spinning
        spinner.controlSize            = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        cv.addSubview(spinner)

        // ── Close button ──────────────────────────────────────────────
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .rounded
        closeBtn.isEnabled  = false
        closeBtn.target     = self
        closeBtn.action     = #selector(closeWindow)
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
        // Strong capture [self]: keeps window controller alive until the closure executes
        // on main thread (same pattern as LimmFullTest).
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
        switch t.trimmingCharacters(in: .whitespaces).prefix(1) {
        case "✓": return NSColor(srgbRed: 0.30, green: 0.90, blue: 0.55, alpha: 1)
        case "✗": return NSColor(srgbRed: 1.00, green: 0.35, blue: 0.35, alpha: 1)
        case "⏳": return NSColor(srgbRed: 0.55, green: 0.70, blue: 0.85, alpha: 1)
        case "─": return NSColor(srgbRed: 0.35, green: 0.40, blue: 0.48, alpha: 1)
        default:  return NSColor(srgbRed: 0.80, green: 0.85, blue: 0.90, alpha: 1)
        }
    }

    func markDone() {
        let run = { [self] in
            self.spinner.stopAnimation(nil)
            self.closeBtn.isEnabled = true
        }
        Thread.isMainThread ? run() : DispatchQueue.main.async(execute: run)
    }

    @objc private func closeWindow() { window?.orderOut(nil) }
}

// MARK: - Runner

final class LimmBrowserBench: NSObject, WKNavigationDelegate {
    static let shared = LimmBrowserBench()
    private override init() {}

    private let testURLs: [String] = [
        "https://vk.com",
        "https://www.gosuslugi.ru",
    ]

    private var isRunning: Bool = false
    private weak var wc: LimmBrowserBenchWindowController?

    // Per-run state — accessed only on main thread (WKWebView requirement)
    private var webView:     WKWebView?
    private var urlQueue:    [String] = []
    private var results:     [(name: String, ok: Bool, navMs: Double)] = []
    private var currentURL:  String = ""
    private var navStart:    CFAbsoluteTime = 0
    private var navTimer:    Timer?

    // MARK: - Entry point

    func run() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isRunning {
                self.wc?.window?.makeKeyAndOrderFront(nil)
                return
            }
            self.isRunning = true

            let w = LimmBrowserBenchWindowController()
            self.wc = w
            showDock(state: true)
            w.showWindow(nil)
            w.window?.makeKeyAndOrderFront(nil)

            self.startBench(w)
        }
    }

    // MARK: - Bench flow (main thread — WKWebView requirement)

    private func startBench(_ w: LimmBrowserBenchWindowController) {
        results  = []
        urlQueue = testURLs

        w.appendLine("=== Browser Bench ===\n")

        let isVpnOn = UserDefaults.getBool(forKey: .v2rayTurnOn)
        if isVpnOn {
            w.appendLine("  Трафик через VPN (системный прокси)\n")
        } else {
            w.appendLine("  ⚠️  VPN выключен — прямое соединение\n",
                         color: NSColor(srgbRed: 1.0, green: 0.75, blue: 0.3, alpha: 1))
        }
        w.appendLine("─────────────────────────────────────────────────────\n")

        // WKWebView must be created on main thread and kept alive for the whole run.
        // Attaching it off-screen to the window content view prevents ARC release.
        let wv = WKWebView(frame: NSRect(x: -4000, y: -4000, width: 1280, height: 800))
        wv.navigationDelegate = self
        w.window?.contentView?.addSubview(wv)
        webView = wv

        loadNext()
    }

    private func loadNext() {
        guard !urlQueue.isEmpty else { finish(); return }

        currentURL = urlQueue.removeFirst()
        navStart   = CFAbsoluteTimeGetCurrent()

        let host = URL(string: currentURL)?.host ?? currentURL
        wc?.appendLine("⏳ \(host) …\n")

        // Timeout timer: if WKWebView stalls (blocked host, no network), fire after 12 s
        navTimer?.invalidate()
        navTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }

        let req = URLRequest(url: URL(string: currentURL)!,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 12)
        webView?.load(req)
    }

    private func handleTimeout() {
        navTimer = nil
        let host = URL(string: currentURL)?.host ?? currentURL
        wc?.appendLine("✗ \(host)  [timeout]\n")
        results.append((name: host, ok: false, navMs: 12_000))
        webView?.stopLoading()
        loadNext()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navTimer?.invalidate(); navTimer = nil
        let wallMs = (CFAbsoluteTimeGetCurrent() - navStart) * 1_000
        let host   = URL(string: currentURL)?.host ?? currentURL

        // Navigation Timing API — same metrics as proxy-bench.py
        let js = """
        (() => {
            const n = performance.getEntriesByType('navigation')[0];
            if (!n) return null;
            const f = v => Math.round(v * 10) / 10;
            return {
                dns:   f(n.domainLookupEnd  - n.domainLookupStart),
                tcp:   f(n.connectEnd       - n.connectStart),
                ssl:   n.secureConnectionStart > 0
                         ? f(n.connectEnd - n.secureConnectionStart) : -1,
                ttfb:  f(n.responseStart   - n.requestStart),
                dom:   f(n.domContentLoadedEventEnd),
                proto: n.nextHopProtocol || '',
                reqs:  performance.getEntriesByType('resource').length,
            };
        })()
        """

        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            let p     = result as? [String: Any]
            let ttfb  = p?["ttfb"]  as? Double ?? -1
            let dom   = p?["dom"]   as? Double ?? wallMs
            let proto = p?["proto"] as? String ?? ""
            let reqs  = p?["reqs"]  as? Int    ?? 0
            // Prefer JS dom-ready over wall clock; JS is relative to navigation start
            let navMs = dom > 0 ? dom : wallMs

            let ttfbStr  = ttfb  >= 0 ? "\(Int(ttfb))ms"  : "—"
            let protoStr = proto.isEmpty ? "" : "  \(proto)"
            self.wc?.appendLine(
                "✓ \(host)  nav \(Int(navMs))ms  TTFB \(ttfbStr)  DOM \(Int(dom))ms\(protoStr)  req:\(reqs)\n")

            self.results.append((name: host, ok: true, navMs: navMs))
            self.loadNext()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navTimer?.invalidate(); navTimer = nil
        let host = URL(string: currentURL)?.host ?? currentURL
        let msg  = (error as NSError).localizedDescription
        wc?.appendLine("✗ \(host)  \(msg.prefix(60))\n")
        results.append((name: host, ok: false, navMs: 0))
        loadNext()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!,
                 withError error: Error) {
        self.webView(webView, didFail: nav, withError: error)
    }

    // MARK: - Finish

    private func finish() {
        // Detach WKWebView — no longer needed
        webView?.removeFromSuperview()
        webView = nil

        wc?.appendLine("─────────────────────────────────────────────────────\n")

        let okCount = results.filter { $0.ok }.count
        wc?.appendLine("  Итог: \(okCount)/\(results.count) OK\n")

        let token = LimmConfig.token
        guard !token.isEmpty, token != "__LIMM_TOKEN__" else {
            wc?.appendLine("  (токен не задан — не отправлено)\n",
                           color: NSColor(srgbRed: 0.35, green: 0.40, blue: 0.48, alpha: 1))
            wc?.markDone()
            isRunning = false
            return
        }

        wc?.appendLine("⏳ Отправляем в /api/fulltest …\n")
        postFulltest(results: results, token: token)
    }

    // MARK: - Upload (direct egress, same pattern as LimmCheckin.postCheckin)

    private func postFulltest(results: [(name: String, ok: Bool, navMs: Double)], token: String) {
        let profiles: [[String: Any]] = results.map { r in
            var d: [String: Any] = ["name": "browser:\(r.name)", "ok": r.ok ? 1 : 0]
            if r.ok { d["latency_ms"] = Int(r.navMs) }
            return d
        }
        let payload: [String: Any] = [
            "client_uid": LimmConfig.clientUID(),
            "kind":       "macos-browser",
            "profiles":   profiles,
        ]
        guard let url  = URL(string: "\(LimmConfig.apiBase)/fulltest"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            wc?.appendLine("✗ сериализация не удалась\n")
            wc?.markDone(); isRunning = false; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.httpBody        = body
        req.timeoutInterval = 20

        // Bypass system SOCKS proxy — same pattern as LimmCheckin (direct to limm.space via CF)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { [weak self] data, resp, err in
            defer { session.finishTasksAndInvalidate() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.wc?.appendLine("✗ \(err.localizedDescription.prefix(70))\n")
                } else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        let ans = data.flatMap {
                            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                        }
                        self.wc?.appendLine("✓ Отправлено: \(ans?["saved"] ?? "")\n")
                    } else {
                        let txt = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        self.wc?.appendLine("✗ HTTP \(code): \(txt.prefix(60))\n")
                    }
                }
                self.wc?.markDone()
                self.isRunning = false
            }
        }.resume()
    }
}
