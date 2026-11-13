import Foundation
import AppKit

/// Checks GitHub for a newer build and, if you say yes, downloads it,
/// swaps it in place of this app, and reopens it.
///
/// Every build publishes a release whose notes start with "build=N".
/// The app's own build number is CFBundleVersion (set by the GitHub Action).
/// Set by the Run tab while scanning/copying so an update never interrupts a copy.
enum CopyState { static var inProgress = false }

final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "LNFPP/drone-file-transfer"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    private static let assetName = "DroneFileTransfer-mac.zip"

    @Published var busy = false
    @Published var status = ""

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    var currentVersionText: String {
        currentBuild > 0 ? "Build \(currentBuild)" : "Development build"
    }

    // MARK: Check

    func checkForUpdates() {
        Task { @MainActor in await self.runCheck() }
    }

    @MainActor
    private func runCheck() async {
        guard !busy else { return }
        busy = true
        status = "Checking for updates\u{2026}"
        do {
            defer { busy = false }
            do {
                let (build, zipURL) = try await fetchLatest()
                status = ""
                if build <= currentBuild {
                    alert("You're up to date", "Drone File Transfer build \(currentBuild) is the newest version.")
                    return
                }
                let a = NSAlert()
                a.messageText = "An update is available"
                a.informativeText = "Build \(build) is available. You have \(currentBuild > 0 ? "build \(currentBuild)" : "a development build").\n\nInstall it now? The app will close, update, and reopen."
                a.addButton(withTitle: "Install Update")
                a.addButton(withTitle: "Not Now")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                try await install(from: zipURL, build: build)
            } catch {
                status = ""
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Couldn't update"
                a.informativeText = error.localizedDescription
                a.addButton(withTitle: "OK")
                a.addButton(withTitle: "Open Download Page")
                if a.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(Self.releasesPage)
                }
            }
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let body: String?
        let assets: [Asset]
    }

    private func fetchLatest() async throws -> (Int, URL) {
        var req = URLRequest(url: Self.latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw fail("GitHub didn't answer. Check your internet connection and try again.")
        }
        let rel = try JSONDecoder().decode(Release.self, from: data)
        guard let body = rel.body,
              let r = body.range(of: #"build=(\d+)"#, options: .regularExpression),
              let build = Int(body[r].dropFirst("build=".count)) else {
            throw fail("Couldn't read the build number of the latest release.")
        }
        guard let asset = rel.assets.first(where: { $0.name == Self.assetName }) else {
            throw fail("The latest release doesn't have \(Self.assetName) yet. Try again in a minute.")
        }
        return (build, asset.browser_download_url)
    }

    // MARK: Install

    @MainActor
    private func install(from zipURL: URL, build: Int) async throws {
        if CopyState.inProgress {
            throw fail("A copy is running. Let it finish, then check for updates again.")
        }

        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let appPath = appURL.path
        guard appURL.pathExtension == "app" else {
            throw fail("This copy of the app isn't a normal .app, so it can't update itself.")
        }
        if appPath.contains("/AppTranslocation/") {
            throw fail("macOS is running the app from a temporary spot, so it can't replace itself.\n\nDrag Drone File Transfer into your Applications folder, open it from there, and try again.")
        }
        let parent = appURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw fail("Don't have permission to replace the app in \(parent).")
        }

        busy = true
        status = "Downloading build \(build)\u{2026}"

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroneFileTransfer-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let (tmp, resp) = try await URLSession.shared.download(from: zipURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw fail("The download failed. Try again.")
        }
        let zip = work.appendingPathComponent(Self.assetName)
        try FileManager.default.moveItem(at: tmp, to: zip)

        status = "Unpacking\u{2026}"
        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let newApp = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/DroneFileTransfer").path) else {
            throw fail("The downloaded update looks incomplete. Nothing was changed.")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // Stage the new app next to the old one (same drive, so the swap is instant).
        let staged = appURL.deletingLastPathComponent()
            .appendingPathComponent(".DroneFileTransfer-update.app")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: newApp, to: staged)

        // After this app quits: old -> backup, new -> old name, delete backup, reopen.
        // If anything goes wrong, the old app is put back.
        let backup = appPath + ".old"
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(backup))
        if mv \(q(appPath)) \(q(backup)); then
          if mv \(q(staged.path)) \(q(appPath)); then
            rm -rf \(q(backup))
          else
            mv \(q(backup)) \(q(appPath))
            rm -rf \(q(staged.path))
          fi
        else
          rm -rf \(q(staged.path))
        fi
        rm -rf \(q(work.path))
        open \(q(appPath))
        """
        let scriptURL = work.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        try p.run()

        status = "Restarting\u{2026}"
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 && tool != "/usr/bin/xattr" {
            throw fail("\((tool as NSString).lastPathComponent) failed (code \(p.terminationStatus)).")
        }
        return p.terminationStatus
    }

    private func fail(_ msg: String) -> NSError {
        NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    @MainActor
    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
