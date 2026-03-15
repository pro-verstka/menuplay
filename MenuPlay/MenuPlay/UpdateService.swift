import AppKit

struct AppRelease {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
    let htmlURL: String
}

enum UpdateState {
    case idle
    case checking
    case available(AppRelease)
    case downloading
    case installing
    case failed(String)
}

final class UpdateService {
    static let shared = UpdateService()

    private var checkTimer: Timer?
    private var downloadObservation: NSKeyValueObservation?

    private(set) var state: UpdateState = .idle {
        didSet {
            NotificationCenter.default.post(name: .updateStateChanged, object: nil)
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var autoCheckEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "updateAutoCheckEnabled") == nil
            ? true
            : defaults.bool(forKey: "updateAutoCheckEnabled")
    }

    private var lastCheckDate: Date? {
        get {
            let ts = UserDefaults.standard.double(forKey: "updateLastCheckDate")
            return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "updateLastCheckDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "updateLastCheckDate")
            }
        }
    }

    private init() {}

    // MARK: - Periodic checks

    func startPeriodicChecks() {
        guard autoCheckEnabled else { return }
        checkForUpdate(manual: false)
    }

    func stopPeriodicChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func scheduleTimer(interval: TimeInterval) {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.checkForUpdate(manual: false)
        }
    }

    // MARK: - Check

    func checkForUpdate(manual: Bool) {
        state = .checking
        fetchLatestRelease { [weak self] release in
            guard let self else { return }
            self.lastCheckDate = Date()

            guard let release else {
                self.state = .idle
                if manual {
                    self.showUpToDateAlert()
                }
                self.scheduleTimer(interval: 24 * 60 * 60)
                return
            }

            if self.compareVersions(release.version, isNewerThan: self.currentVersion) {
                self.state = .available(release)
                if manual {
                    self.downloadAndInstall(release)
                }
                self.scheduleTimer(interval: 24 * 60 * 60)
            } else {
                self.state = .idle
                if manual {
                    self.showUpToDateAlert()
                }
                self.scheduleTimer(interval: 24 * 60 * 60)
            }
        }
    }

    // MARK: - GitHub API

    private func fetchLatestRelease(completion: @escaping (AppRelease?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/pro-verstka/menuplay/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil, (200..<300).contains(statusCode),
                  let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let tagName = payload["tag_name"] as? String,
                  let assets = payload["assets"] as? [[String: Any]],
                  let htmlURL = payload["html_url"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let releaseNotes = payload["body"] as? String ?? ""

            guard let asset = assets.first(where: { ($0["name"] as? String) == "MenuPlay-macos.zip" }),
                  let downloadURLString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let release = AppRelease(
                version: version,
                downloadURL: downloadURL,
                releaseNotes: releaseNotes,
                htmlURL: htmlURL
            )
            DispatchQueue.main.async { completion(release) }
        }.resume()
    }

    // MARK: - Version comparison

    func compareVersions(_ new: String, isNewerThan current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let count = max(newParts.count, currentParts.count)

        for i in 0..<count {
            let n = i < newParts.count ? newParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if n > c { return true }
            if n < c { return false }
        }
        return false
    }

    // MARK: - Download & install

    private func downloadAndInstall(_ release: AppRelease) {
        state = .downloading

        let task = URLSession.shared.downloadTask(with: release.downloadURL) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                guard error == nil, let tempURL else {
                    self.state = .failed("Download failed: \(error?.localizedDescription ?? "unknown error")")
                    self.scheduleTimer(interval: 24 * 60 * 60)
                    return
                }

                self.state = .installing
                self.install(from: tempURL)
            }
        }

        downloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            // Progress is being tracked; state stays .downloading
            _ = progress.fractionCompleted
            _ = self
        }

        task.resume()
    }

    private func install(from zipURL: URL) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("MenuPlayUpdate-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            state = .failed("Failed to create temp directory: \(error.localizedDescription)")
            return
        }

        // Unzip
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", zipURL.path, tempDir.path]

        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            state = .failed("Failed to unzip update: \(error.localizedDescription)")
            return
        }

        guard ditto.terminationStatus == 0 else {
            state = .failed("Unzip failed with status \(ditto.terminationStatus)")
            return
        }

        // Find .app in extracted contents
        guard let extractedApp = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            state = .failed("No .app found in update archive")
            return
        }

        // Remove quarantine
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-rd", "com.apple.quarantine", extractedApp.path]
        try? xattr.run()
        xattr.waitUntilExit()

        // Self-replace via helper script
        guard let currentAppPath = Bundle.main.bundlePath as String? else { return }
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
        rm -rf "\(currentAppPath)"
        mv "\(extractedApp.path)" "\(currentAppPath)"
        /usr/bin/xattr -rd com.apple.quarantine "\(currentAppPath)" 2>/dev/null
        open "\(currentAppPath)"
        rm -f "$0"
        """

        let scriptPath = fileManager.temporaryDirectory
            .appendingPathComponent("menuplay_update_\(UUID().uuidString).sh").path

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            state = .failed("Failed to create update script: \(error.localizedDescription)")
            return
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptPath]
        do {
            try helper.run()
        } catch {
            state = .failed("Failed to launch update helper: \(error.localizedDescription)")
            return
        }

        NSApp.terminate(nil)
    }

    // MARK: - UI

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "MenuPlay \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension Notification.Name {
    static let updateStateChanged = Notification.Name("updateStateChanged")
}
