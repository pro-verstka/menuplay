import SwiftUI
import ServiceManagement

@main
struct MenuPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastTrack: TrackInfo?
    private var lastArtworkURL: String?
    private var artworkMenuItem: NSMenuItem!
    private var trackInfoMenuItem: NSMenuItem!
    private var playPauseMenuItem: NSMenuItem!
    private var nextTrackMenuItem: NSMenuItem!
    private var previousTrackMenuItem: NSMenuItem!
    private var likeMenuItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var currentLikedState: Bool = false

    private var maxChars: Int {
        let val = UserDefaults.standard.integer(forKey: "maxChars")
        return val > 0 ? val : 20
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.object(forKey: "maxChars") == nil {
            UserDefaults.standard.set(20, forKey: "maxChars")
        }

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        artworkMenuItem = NSMenuItem()
        artworkMenuItem.isEnabled = false
        artworkMenuItem.isHidden = true
        menu.addItem(artworkMenuItem)

        trackInfoMenuItem = NSMenuItem()
        trackInfoMenuItem.isEnabled = false
        trackInfoMenuItem.isHidden = true
        menu.addItem(trackInfoMenuItem)

        menu.addItem(.separator())

        nextTrackMenuItem = NSMenuItem(title: "Next Track", action: #selector(nextTrack), keyEquivalent: "n")
        nextTrackMenuItem.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
        menu.addItem(nextTrackMenuItem)

        previousTrackMenuItem = NSMenuItem(title: "Previous Track", action: #selector(previousTrack), keyEquivalent: "p")
        previousTrackMenuItem.image = NSImage(systemSymbolName: "backward.end.fill", accessibilityDescription: nil)
        menu.addItem(previousTrackMenuItem)

        playPauseMenuItem = NSMenuItem(title: "Pause", action: #selector(playPause), keyEquivalent: " ")
        playPauseMenuItem.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        menu.addItem(playPauseMenuItem)

        menu.addItem(.separator())

        likeMenuItem = NSMenuItem(title: "Like", action: #selector(toggleLike), keyEquivalent: "l")
        likeMenuItem.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        likeMenuItem.isEnabled = SpotifyAPI.shared.isAuthorized
        menu.addItem(likeMenuItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(authChanged),
            name: .spotifyAuthChanged, object: nil
        )

        updateNowPlaying()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.updateNowPlaying()
        }
    }

    @objc private func authChanged() {
        likeMenuItem.isEnabled = SpotifyAPI.shared.isAuthorized
        if SpotifyAPI.shared.isAuthorized {
            checkLikeState()
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        SpotifyAPI.shared.handleCallback(url: url)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updatePlayPauseState()
        checkLikeState()
    }

    // MARK: - State updates

    private func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "..."
    }

    private func updatePlayPauseState() {
        let playing = SpotifyService.isPlaying()
        playPauseMenuItem.title = playing ? "Pause" : "Play"
        playPauseMenuItem.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )
    }

    private func updateLikeMenuItem(liked: Bool) {
        currentLikedState = liked
        likeMenuItem.title = liked ? "Dislike" : "Like"
        likeMenuItem.image = NSImage(
            systemSymbolName: liked ? "heart.slash" : "heart",
            accessibilityDescription: nil
        )
        likeMenuItem.isEnabled = SpotifyAPI.shared.isAuthorized
    }

    private func checkLikeState() {
        guard SpotifyAPI.shared.isAuthorized,
              let track = lastTrack else {
            updateLikeMenuItem(liked: false)
            return
        }
        let bareID = SpotifyService.bareTrackID(track.trackID)
        SpotifyAPI.shared.isTrackSaved(trackID: bareID) { [weak self] saved in
            self?.updateLikeMenuItem(liked: saved)
        }
    }

    private func updateNowPlaying() {
        guard let track = SpotifyService.getCurrentTrack() else {
            statusItem.button?.title = ""
            statusItem.button?.image = makeTextImage("♪")
            lastTrack = nil
            lastArtworkURL = nil
            artworkMenuItem.isHidden = true
            trackInfoMenuItem.isHidden = true
            return
        }

        if track == lastTrack { return }
        lastTrack = track

        let limit = maxChars
        let displayText = truncate("\(track.name) — \(track.artist)", max: limit)
        statusItem.button?.title = " \(displayText)"

        updateTrackInfoView(track)
        checkLikeState()

        if track.artworkURL != lastArtworkURL {
            lastArtworkURL = track.artworkURL
            statusItem.button?.image = makeTextImage("♪")
            artworkMenuItem.isHidden = true

            SpotifyService.loadArtwork(from: track.artworkURL, size: 18) { [weak self] image in
                guard let self, self.lastArtworkURL == track.artworkURL else { return }
                self.statusItem.button?.image = image.map(Self.roundedImage(_:)) ?? self.makeTextImage("♪")
            }

            let artSize: CGFloat = 250
            SpotifyService.loadArtwork(from: track.artworkURL, size: artSize) { [weak self] image in
                guard let self, self.lastArtworkURL == track.artworkURL else { return }
                guard let image else { return }
                let padding: CGFloat = 12
                let imageView = NSImageView(image: image)
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.frame = NSRect(x: padding, y: 0, width: artSize, height: artSize)
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.masksToBounds = true
                let container = NSView(frame: NSRect(x: 0, y: 0, width: artSize + padding * 2, height: artSize + 6))
                container.addSubview(imageView)
                self.artworkMenuItem.view = container
                self.artworkMenuItem.isHidden = false
            }
        }
    }

    private func updateTrackInfoView(_ track: TrackInfo) {
        let width: CGFloat = 250
        let padding: CGFloat = 12

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))

        let nameLabel = NSTextField(labelWithString: track.name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        let artistLabel = NSTextField(labelWithString: track.artist)
        artistLabel.font = NSFont.systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail

        let albumLabel = NSTextField(labelWithString: track.album)
        albumLabel.font = NSFont.systemFont(ofSize: 11)
        albumLabel.textColor = .tertiaryLabelColor
        albumLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [nameLabel, artistLabel, albumLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])

        trackInfoMenuItem.view = container
        trackInfoMenuItem.isHidden = false
    }

    private static func roundedImage(_ image: NSImage) -> NSImage {
        let size = image.size
        let result = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.addClip()
            image.draw(in: rect)
            return true
        }
        result.isTemplate = false
        return result
    }

    private func makeTextImage(_ text: String) -> NSImage {
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        let size = (text as NSString).size(withAttributes: attr)
        let image = NSImage(size: size, flipped: false) { rect in
            (text as NSString).draw(in: rect, withAttributes: attr)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Actions

    @objc private func previousTrack() {
        SpotifyService.previousTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lastTrack = nil
            self?.updateNowPlaying()
        }
    }

    @objc private func playPause() {
        SpotifyService.playPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lastTrack = nil
            self?.updateNowPlaying()
        }
    }

    @objc private func nextTrack() {
        SpotifyService.nextTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lastTrack = nil
            self?.updateNowPlaying()
        }
    }

    @objc private func toggleLike() {
        guard SpotifyAPI.shared.isAuthorized, let track = lastTrack else { return }
        let bareID = SpotifyService.bareTrackID(track.trackID)

        if currentLikedState {
            SpotifyAPI.shared.removeTrack(trackID: bareID) { [weak self] success in
                if success { self?.updateLikeMenuItem(liked: false) }
            }
        } else {
            SpotifyAPI.shared.saveTrack(trackID: bareID) { [weak self] success in
                if success { self?.updateLikeMenuItem(liked: true) }
            }
        }
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("maxChars") private var maxChars: Int = 20
    @AppStorage("spotifyClientID") private var clientID: String = ""
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var isConnected: Bool = SpotifyAPI.shared.isAuthorized

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Max characters")
                Spacer()
                TextField("", value: $maxChars, format: .number)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Limits the track title length in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Divider()

            Text("Spotify API (for Like/Dislike)")
                .font(.headline)

            HStack {
                Text("Client ID")
                TextField("Paste your Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 4) {
                Text("Create app at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("developer.spotify.com", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    .font(.caption)
            }
            Text("Set redirect URI to menuplay://callback")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect") {
                        SpotifyAPI.shared.logout()
                        isConnected = false
                    }
                } else {
                    Button("Connect to Spotify") {
                        SpotifyAPI.shared.authorize()
                    }
                    .disabled(clientID.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .onReceive(NotificationCenter.default.publisher(for: .spotifyAuthChanged)) { _ in
            isConnected = SpotifyAPI.shared.isAuthorized
        }
    }
}
