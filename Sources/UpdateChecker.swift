import Foundation
import Combine

/// Checks GitHub Releases for a newer version, at most once a day. This is the app's only network request,
/// and it sends nothing but a plain GET for the public release list.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var latestVersion: String?
    @Published private(set) var latestURL: URL?

    static let releasesPage = URL(string: "https://github.com/\(Brand.repository)/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/\(Brand.repository)/releases/latest")!
    private let lastCheckKey = "UpdateCheckLastAt"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.compare(latest, currentVersion) == .orderedDescending
    }

    func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        if Date().timeIntervalSince1970 - last > 86_400 { check() }
    }

    func check(completion: ((Bool) -> Void)? = nil) {
        var req = URLRequest(url: Self.api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AntAILauncher", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            var found = false
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = j["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let url = (j["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
                found = true
                DispatchQueue.main.async {
                    self.latestVersion = version
                    self.latestURL = url
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                }
            }
            DispatchQueue.main.async { completion?(found) }
        }.resume()
    }

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
