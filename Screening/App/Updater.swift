import AppKit
import CryptoKit
import Observation

/// Looks for a newer release on GitHub, downloads its disk image and swaps it in for this copy of the app.
@Observable
final class Updater {
    static let shared = Updater()

    static let repository = "TheRoben-Dev/Screening"
    private static let checkInterval: Duration = .seconds(24 * 60 * 60)

    enum State: Equatable {
        case idle
        case checking
        case downloading(version: String)
        /// Downloaded and unpacked, waiting for the user to restart into it.
        case ready(version: String)
        case failed(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var staged: (version: String, app: URL)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks now and then once a day, while the setting is on.
    func startAutomaticChecks() {
        schedule?.cancel()
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, AppSettings.shared.checksForUpdates else { return }
                await self.check(userInitiated: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func stopAutomaticChecks() {
        schedule?.cancel()
        schedule = nil
    }

    func checkFromMenu() {
        if case .ready = state {
            promptToInstall()
            return
        }
        Task { await check(userInitiated: true) }
    }

    // MARK: Checking

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }

        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var diskImage: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
        /// The release notes carry the disk image's checksum, so a damaged download is caught before installing.
        var sha256: String? {
            guard let body, let match = body.firstMatch(of: /SHA-256:\**\s*`?([0-9a-fA-F]{64})/) else { return nil }
            return String(match.1).lowercased()
        }
    }

    private func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading: return
        case .ready:
            if userInitiated { promptToInstall() }
            return
        case .idle, .failed: break
        }
        state = .checking
        do {
            let release = try await latestRelease()
            guard Self.isVersion(release.version, newerThan: currentVersion) else {
                state = .idle
                if userInitiated { GlassMessage.show("Screening \(currentVersion) is the latest version") }
                return
            }
            guard let asset = release.diskImage else { throw UpdateError.noDiskImage(release.version) }
            state = .downloading(version: release.version)
            if userInitiated { GlassMessage.show("Downloading Screening \(release.version)…") }
            let app = try await download(asset, expectedSHA256: release.sha256, version: release.version)
            staged = (release.version, app)
            state = .ready(version: release.version)
            promptToInstall()
        } catch {
            state = .failed(error.localizedDescription)
            if userInitiated { Alerts.show(error, title: "Couldn’t check for updates") }
        }
    }

    private func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Screening/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        // No release published yet looks like a 404.
        if http.statusCode == 404 { throw UpdateError.noReleases }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { throw UpdateError.noReleases }
        return release
    }

    /// Compares dotted numbers, so 1.10 is newer than 1.9 and 1.0 equals 1.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        var a = parts(candidate), b = parts(current)
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return b.lexicographicallyPrecedes(a)
    }

    // MARK: Downloading

    private func download(_ asset: Release.Asset, expectedSHA256: String?, version: String) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: asset.browser_download_url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreeningUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporary, to: dmg)

        if let expectedSHA256 {
            let digest = try await Task.detached(priority: .utility) {
                SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }.joined()
            }.value
            guard digest == expectedSHA256 else { throw UpdateError.checksumMismatch }
        }

        // Copy the app out of the disk image, then let the image go.
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                "-mountpoint", mount.path])
        defer { Task.detached { try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) } }

        let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let source = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noApp }
        let app = work.appendingPathComponent(source.lastPathComponent)
        try await Self.run("/usr/bin/ditto", [source.path, app.path])

        // Only ever replace this app with the same app, at the version the release promised.
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp }
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        guard Self.isVersion(appVersion, newerThan: currentVersion) else { throw UpdateError.versionMismatch(version) }
        return app
    }

    // MARK: Installing

    private func promptToInstall() {
        guard let staged else { return }
        let alert = NSAlert()
        alert.messageText = "Screening \(staged.version) is ready to install"
        alert.informativeText = "Screening will quit, update itself and open again. "
            + "macOS may ask you to allow Screen Recording again afterwards."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try install(staged.app)
        } catch {
            Alerts.show(error, title: "Couldn’t install the update")
        }
    }

    /// Swaps the bundle once this process has quit, since a running app shouldn't be replaced under itself.
    private func install(_ newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let folder = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError.notWritable(folder.path)
        }
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2.old"
        /bin/mv "$2" "$2.old" || exit 1
        if /usr/bin/ditto "$3" "$2"; then
          /bin/rm -rf "$2.old"
        else
          /bin/rm -rf "$2"; /bin/mv "$2.old" "$2"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        /usr/bin/open "$2"
        /bin/rm -rf "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             current.path, newApp.path, newApp.deletingLastPathComponent().path]
        try process.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent)
            }
        }.value
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case http(Int)
    case noReleases
    case noDiskImage(String)
    case checksumMismatch
    case noApp
    case wrongApp
    case versionMismatch(String)
    case notWritable(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: "GitHub sent an unexpected response."
        case .http(let code): "GitHub answered with error \(code). Try again later."
        case .noReleases: "No release has been published yet."
        case .noDiskImage(let version): "Release \(version) has no disk image to install."
        case .checksumMismatch: "The download didn’t match its published checksum, so it wasn’t installed."
        case .noApp: "The disk image didn’t contain the app."
        case .wrongApp: "The downloaded app isn’t Screening, so it wasn’t installed."
        case .versionMismatch(let version): "The downloaded app isn’t version \(version)."
        case .notWritable(let path): "Screening can’t write to \(path). Download the update from GitHub instead."
        case .toolFailed(let tool): "\(tool) failed while preparing the update."
        }
    }
}
