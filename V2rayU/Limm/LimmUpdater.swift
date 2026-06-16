// LimmUpdater.swift — check lexx633/vpn-mac GitHub releases for new .dmg
// Replaces Sparkle auto-update with our own release check.
// Called from AppDelegate when "Check for updates automatically" is on.

import Foundation
import Cocoa

struct LimmRelease: Codable {
    let tag_name: String
    let name: String
    let html_url: String
    let assets: [LimmAsset]
}

struct LimmAsset: Codable {
    let name: String
    let browser_download_url: String
}

class LimmUpdater {
    static let shared = LimmUpdater()

    /// Installed version = LimmBuildInfo.version (e.g. "4.2.8.13", 4 components).
    /// CI injects this via add_limm_files.rb at build time — matches what proxy-mac-info.json reports.
    var currentVersion: String {
        LimmBuildInfo.version
    }

    func checkForUpdates(silent: Bool = false) {
        // Try each mirror (direct www first, then CF) until one returns a decodable release.
        fetchRelease(LimmConfig.releasesURLs, index: 0, silent: silent)
    }

    /// Recursively tries the mirror list; on failure falls through to the next host.
    private func fetchRelease(_ urls: [String], index: Int, silent: Bool) {
        guard index < urls.count, let url = URL(string: urls[index]) else {
            if !silent { self.showError("Не удалось проверить обновления") }
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        // P-M2: use ephemeral direct session (bypass system SOCKS proxy set by V2rayU);
        // check statusCode == 200 before decode — 404/500 HTML bodies crash JSONDecoder silently.
        // Capture session in closure for finishTasksAndInvalidate() after completion.
        let directCfg = URLSessionConfiguration.ephemeral
        directCfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: directCfg)
        session.dataTask(with: req) { data, resp, err in
            defer { session.finishTasksAndInvalidate() }
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let release = try? JSONDecoder().decode(LimmRelease.self, from: data)
            else {
                // This mirror failed — try the next one (e.g. CF blocked → fall back to www).
                self.fetchRelease(urls, index: index + 1, silent: silent)
                return
            }
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst())
                                                          : release.tag_name
            // Числовое сравнение (как Android UpdateCheckerManager): апдейт только если строго новее.
            if Self.compareVersions(latest, self.currentVersion) <= 0 {
                if !silent {
                    DispatchQueue.main.async { self.showUpToDate() }
                }
                return
            }
            // Find .dmg asset
            let dmgURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browser_download_url
                      ?? release.html_url
            DispatchQueue.main.async {
                self.showUpdateAlert(tag: release.tag_name, name: release.name, downloadURL: dmgURL)
            }
        }.resume()
    }

    /// Сравнивает "4.2.7" vs "4.2.8" покомпонентно; нечисловые части → 0.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let n1 = i < x.count ? x[i] : 0
            let n2 = i < y.count ? y[i] : 0
            if n1 != n2 { return n1 - n2 }
        }
        return 0
    }

    private func showUpdateAlert(tag: String, name: String, downloadURL: String) {
        let alert = NSAlert()
        alert.messageText    = "Доступно обновление limm VPN"
        alert.informativeText = "Версия \(tag)\n\(name)"
        alert.addButton(withTitle: "Скачать")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            openFirstReachable(LimmConfig.mirrorURLs(downloadURL))
        }
    }

    /// Opens the first reachable mirror (direct www first, then CF). Probes each with a short
    /// HEAD so a CF-blocked host doesn't dump the user onto a dead download; opens the first
    /// candidate as a last resort if none probe OK.
    private func openFirstReachable(_ urls: [String], index: Int = 0) {
        guard index < urls.count, let url = URL(string: urls[index]) else {
            if let first = urls.first, let u = URL(string: first) { NSWorkspace.shared.open(u) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 6
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { _, resp, err in
            defer { session.finishTasksAndInvalidate() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if err == nil, (200..<400).contains(code) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            } else {
                self.openFirstReachable(urls, index: index + 1)
            }
        }.resume()
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText     = "limm VPN актуален"
        alert.informativeText = "Установлена последняя версия (\(currentVersion))."
        alert.runModal()
    }

    private func showError(_ msg: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Ошибка проверки обновлений"
            alert.informativeText = msg
            alert.runModal()
        }
    }
}
