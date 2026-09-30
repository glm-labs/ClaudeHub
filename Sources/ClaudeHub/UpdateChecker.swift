import AppKit
import Combine
import Foundation

/// Checks the GitHub releases feed for a newer version and installs it:
/// the zip is downloaded and staged, a small helper waits for the app to
/// quit, swaps /Applications/ClaudeHub.app, and relaunches.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var isInstalling = false
    @Published var errorMessage: String?

    private var downloadURL: URL?
    // The repo moved to the glm-labs organisation; the old URL redirects,
    // but a redirect is one deprecation away from a broken updater.
    private let releasesAPI = URL(string: "https://api.github.com/repos/glm-labs/ClaudeHub/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private init() {}

    func check() {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = release["assets"] as? [[String: Any]] ?? []
            let zipURL = assets
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".zip") }
                .flatMap(URL.init(string:))
            DispatchQueue.main.async {
                self.latestVersion = version
                self.downloadURL = zipURL
                self.updateAvailable = zipURL != nil
                    && Self.isNewer(version, than: Self.currentVersion)
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func downloadAndInstall() {
        guard let url = downloadURL, !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        URLSession.shared.downloadTask(with: url) { tmp, _, error in
            DispatchQueue.main.async { self.stageAndRelaunch(tmp: tmp, error: error) }
        }.resume()
    }

    private func stageAndRelaunch(tmp: URL?, error: Error?) {
        guard let tmp else {
            errorMessage = error?.localizedDescription ?? "Download failed"
            isInstalling = false
            return
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("ClaudeHubUpdate-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let zip = staging.appendingPathComponent("update.zip")
            try fm.moveItem(at: tmp, to: zip)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-xk", zip.path, staging.path]
            try unzip.run()
            unzip.waitUntilExit()

            let newApp = staging.appendingPathComponent("ClaudeHub.app")
            guard fm.fileExists(atPath: newApp.path) else {
                errorMessage = "Update zip did not contain ClaudeHub.app"
                isInstalling = false
                return
            }

            // The swap must happen after this instance exits; a detached
            // helper waits for that, installs, and relaunches.
            let script = """
            while /usr/bin/pgrep -x ClaudeHub >/dev/null; do /bin/sleep 1; done
            /bin/rm -rf '/Applications/ClaudeHub.app'
            /usr/bin/ditto '\(newApp.path)' '/Applications/ClaudeHub.app'
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '/Applications/ClaudeHub.app'
            /usr/bin/open '/Applications/ClaudeHub.app'
            /bin/rm -rf '\(staging.path)'
            """
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
            helper.arguments = ["-c", script]
            try helper.run()

            // Quit protection may still ask about running terminals; the
            // helper simply waits until the app actually exits.
            NSApp.terminate(nil)
            isInstalling = false
        } catch {
            errorMessage = error.localizedDescription
            isInstalling = false
        }
    }
}
