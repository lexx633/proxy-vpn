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

    /// Current app version tag — matches GitHub release tag, e.g. "v1.0.0-limm"
    var currentTag: String { LimmConfig.appVersion }

    func checkForUpdates(silent: Bool = false) {
        guard let url = URL(string: LimmConfig.releasesURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data = data,
                  let release = try? JSONDecoder().decode(LimmRelease.self, from: data)
            else {
                if !silent { self.showError("Не удалось проверить обновления") }
                return
            }
            let latestTag = release.tag_name
            if latestTag == self.currentTag {
                if !silent {
                    DispatchQueue.main.async { self.showUpToDate() }
                }
                return
            }
            // Find .dmg asset
            let dmgURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browser_download_url
                      ?? release.html_url
            DispatchQueue.main.async {
                self.showUpdateAlert(tag: latestTag, name: release.name, downloadURL: dmgURL)
            }
        }.resume()
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
        alert.informativeText = "Установлена последняя версия (\(currentTag))."
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
