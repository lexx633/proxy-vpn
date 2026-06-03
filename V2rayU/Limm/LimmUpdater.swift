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

    /// Installed version = CFBundleShortVersionString (= MARKETING_VERSION, e.g. "4.2.7").
    /// Единый источник: CI печёт ту же версию в бандл и в mac-info.json (см. build.yml).
    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    func checkForUpdates(silent: Bool = false) {
        guard let url = URL(string: LimmConfig.releasesURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data = data,
                  let release = try? JSONDecoder().decode(LimmRelease.self, from: data)
            else {
                if !silent { self.showError("Не удалось проверить обновления") }
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
            if let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
        }
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
