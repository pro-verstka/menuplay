import SwiftUI
import ServiceManagement

private let defaultMaxChars = 20
private let maxCharsRange = 10...80

private func clampedMaxChars(_ value: Int) -> Int {
    min(max(value, maxCharsRange.lowerBound), maxCharsRange.upperBound)
}

private struct InfoMenuLine {
    let text: String
    let font: NSFont
    let color: NSColor
    let action: (() -> Void)?
}

@main
struct MenuPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

private final class ArtworkMenuView: NSView {
    private let onClick: () -> Void

    init(image: NSImage, size: CGFloat, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: size + 24, height: size + 6))

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 12, y: 0, width: size, height: size)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true

        addSubview(imageView)
        toolTip = "Play/Pause"
        setAccessibilityElement(true)
        setAccessibilityLabel("Play/Pause")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        onClick()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

private final class TrackInfoLineView: NSView {
    private let action: (() -> Void)?

    init(text: String, font: NSFont, color: NSColor, action: (() -> Void)? = nil) {
        self.action = action
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ])

        if action != nil {
            toolTip = "Open in Spotify"
            setAccessibilityElement(true)
            setAccessibilityLabel(text)
            setAccessibilityRole(.button)
        } else {
            setAccessibilityElement(true)
            setAccessibilityLabel(text)
            setAccessibilityRole(.staticText)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        guard action != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard let action else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        action()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastTrack: TrackInfo?
    private var lastTrackMetadata: TrackEnhancementMetadata?
    private var lastArtworkURL: String?
    private var artworkMenuItem: NSMenuItem!
    private var trackInfoMenuItem: NSMenuItem!
    private var playPauseMenuItem: NSMenuItem!
    private var nextTrackMenuItem: NSMenuItem!
    private var previousTrackMenuItem: NSMenuItem!
    private var likeMenuItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var currentLikedState: Bool = false

    private var maxChars: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "maxChars") != nil else { return defaultMaxChars }
        return clampedMaxChars(defaults.integer(forKey: "maxChars"))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "maxChars") == nil {
            defaults.set(defaultMaxChars, forKey: "maxChars")
        } else {
            let sanitizedMaxChars = clampedMaxChars(defaults.integer(forKey: "maxChars"))
            defaults.set(sanitizedMaxChars, forKey: "maxChars")
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

        let aboutMenuItem = NSMenuItem(title: "About", action: #selector(openAbout), keyEquivalent: "")
        aboutMenuItem.image = nil
        menu.addItem(aboutMenuItem)

        let settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.image = nil
        menu.addItem(settingsMenuItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(authChanged),
            name: .spotifyAuthChanged,
            object: nil
        )

        refreshNowPlaying(forceLikeRefresh: true)
    }

    @objc private func authChanged() {
        if SpotifyAPI.shared.isAuthorized {
            checkLikeState()
            if let track = lastTrack {
                if let metadata = lastTrackMetadata {
                    showEnhancedTrackInfo(for: track, metadata: metadata)
                } else {
                    requestTrackMetadata(for: track)
                }
            }
        } else {
            lastTrackMetadata = nil
            updateLikeMenuItem(liked: false)
            if let track = lastTrack {
                showLegacyTrackInfo(for: track)
            }
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        SpotifyAPI.shared.handleCallback(url: url)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNowPlaying(forceLikeRefresh: true)
    }

    private func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "..."
    }

    private func refreshNowPlaying(forceLikeRefresh: Bool = false) {
        let snapshot = SpotifyService.currentSnapshot()
        applySnapshot(snapshot, forceLikeRefresh: forceLikeRefresh)
        scheduleNextUpdate(for: snapshot.playbackState)
    }

    private func applySnapshot(_ snapshot: SpotifySnapshot, forceLikeRefresh: Bool) {
        updatePlaybackControls(for: snapshot.playbackState)

        guard let track = snapshot.track else {
            showPlaybackStatus(snapshot.playbackState)
            return
        }

        let shouldRefreshLikeState = forceLikeRefresh || track.trackID != lastTrack?.trackID
        if track == lastTrack {
            if shouldRefreshLikeState {
                checkLikeState()
            }
            return
        }

        lastTrack = track
        lastTrackMetadata = nil

        let displayText = truncate("\(track.name) — \(track.artist)", max: maxChars)
        statusItem.button?.title = " \(displayText)"

        showLegacyTrackInfo(for: track)

        if shouldRefreshLikeState {
            checkLikeState()
        }

        if SpotifyAPI.shared.isAuthorized {
            requestTrackMetadata(for: track)
        }

        if track.artworkURL != lastArtworkURL {
            lastArtworkURL = track.artworkURL
            statusItem.button?.image = makeTextImage("♪")
            artworkMenuItem.isHidden = true

            SpotifyService.loadArtwork(from: track.artworkURL, size: 18) { [weak self] image in
                guard let self, self.lastArtworkURL == track.artworkURL else { return }
                self.statusItem.button?.image = image.map(Self.roundedImage(_:)) ?? self.makeTextImage("♪")
            }

            let artworkSize: CGFloat = 250
            SpotifyService.loadArtwork(from: track.artworkURL, size: artworkSize) { [weak self] image in
                guard let self, self.lastArtworkURL == track.artworkURL else { return }
                guard let image else { return }
                self.updateArtworkMenuItem(image: image, size: artworkSize)
            }
        }
    }

    private func scheduleNextUpdate(for playbackState: SpotifyPlaybackState) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: playbackState.pollInterval, repeats: false) { [weak self] _ in
            self?.refreshNowPlaying()
        }
    }

    private func updatePlaybackControls(for playbackState: SpotifyPlaybackState) {
        playPauseMenuItem.title = playbackState.playPauseTitle
        playPauseMenuItem.image = NSImage(
            systemSymbolName: playbackState.playPauseSymbolName,
            accessibilityDescription: nil
        )
        playPauseMenuItem.isEnabled = playbackState != .notRunning
        nextTrackMenuItem.isEnabled = playbackState.canControlPlayback
        previousTrackMenuItem.isEnabled = playbackState.canControlPlayback
    }

    private func updateLikeMenuItem(liked: Bool) {
        currentLikedState = liked
        likeMenuItem.title = liked ? "Dislike" : "Like"
        likeMenuItem.image = NSImage(
            systemSymbolName: liked ? "heart.slash" : "heart",
            accessibilityDescription: nil
        )
        likeMenuItem.isEnabled = SpotifyAPI.shared.isAuthorized && lastTrack != nil
    }

    private func checkLikeState() {
        guard SpotifyAPI.shared.isAuthorized,
              let track = lastTrack else {
            updateLikeMenuItem(liked: false)
            return
        }

        updateLikeMenuItem(liked: false)

        let currentTrackID = track.trackID
        let bareID = SpotifyService.bareTrackID(currentTrackID)
        SpotifyAPI.shared.isTrackSaved(trackID: bareID) { [weak self] saved in
            guard let self,
                  self.lastTrack?.trackID == currentTrackID else { return }
            self.updateLikeMenuItem(liked: saved)
        }
    }

    private func showPlaybackStatus(_ playbackState: SpotifyPlaybackState) {
        statusItem.button?.title = ""
        statusItem.button?.image = makeTextImage("♪")
        lastTrack = nil
        lastTrackMetadata = nil
        lastArtworkURL = nil
        artworkMenuItem.isHidden = true
        updateLikeMenuItem(liked: false)
        updateInfoMenu(lines: [
            InfoMenuLine(
                text: playbackState.statusTitle,
                font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                color: .labelColor,
                action: nil
            ),
            InfoMenuLine(
                text: playbackState.statusSubtitle,
                font: NSFont.systemFont(ofSize: 11),
                color: .secondaryLabelColor,
                action: nil
            ),
        ].filter { !$0.text.isEmpty })
    }

    private func updateInfoMenu(lines: [InfoMenuLine]) {
        let width: CGFloat = 250
        let padding: CGFloat = 12
        let lineHeight: CGFloat = 16
        let containerHeight = CGFloat(lines.count) * lineHeight + 20
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: containerHeight))

        let views = lines.map { line in
            TrackInfoLineView(text: line.text, font: line.font, color: line.color, action: line.action)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        trackInfoMenuItem.view = container
        trackInfoMenuItem.isHidden = false
    }

    private func showLegacyTrackInfo(for track: TrackInfo) {
        updateInfoMenu(lines: [
            InfoMenuLine(
                text: track.name,
                font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                color: .labelColor,
                action: nil
            ),
            InfoMenuLine(
                text: track.artist,
                font: NSFont.systemFont(ofSize: 11),
                color: .secondaryLabelColor,
                action: nil
            ),
            InfoMenuLine(
                text: track.album,
                font: NSFont.systemFont(ofSize: 11),
                color: .tertiaryLabelColor,
                action: nil
            ),
        ].filter { !$0.text.isEmpty })
    }

    private func showEnhancedTrackInfo(for track: TrackInfo, metadata: TrackEnhancementMetadata) {
        let bareTrackID = SpotifyService.bareTrackID(track.trackID)
        updateInfoMenu(lines: [
            InfoMenuLine(
                text: track.name,
                font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                color: .labelColor,
                action: { [weak self] in
                    self?.openSpotifyResource(
                        appURLString: "spotify:track:\(bareTrackID)",
                        webURLString: "https://open.spotify.com/track/\(bareTrackID)"
                    )
                }
            ),
            InfoMenuLine(
                text: track.artist,
                font: NSFont.systemFont(ofSize: 11),
                color: .secondaryLabelColor,
                action: { [weak self] in
                    self?.openSpotifyResource(
                        appURLString: "spotify:artist:\(metadata.primaryArtistID)",
                        webURLString: "https://open.spotify.com/artist/\(metadata.primaryArtistID)"
                    )
                }
            ),
            InfoMenuLine(
                text: metadata.albumText(for: track.album),
                font: NSFont.systemFont(ofSize: 11),
                color: .tertiaryLabelColor,
                action: { [weak self] in
                    self?.openSpotifyResource(
                        appURLString: "spotify:album:\(metadata.albumID)",
                        webURLString: "https://open.spotify.com/album/\(metadata.albumID)"
                    )
                }
            ),
        ].filter { !$0.text.isEmpty })
    }

    private func requestTrackMetadata(for track: TrackInfo) {
        let currentTrackID = track.trackID
        SpotifyAPI.shared.fetchTrackMetadata(trackID: currentTrackID) { [weak self] metadata in
            guard let self,
                  SpotifyAPI.shared.isAuthorized,
                  self.lastTrack?.trackID == currentTrackID,
                  let metadata else { return }

            self.lastTrackMetadata = metadata
            self.showEnhancedTrackInfo(for: track, metadata: metadata)
        }
    }

    private func openSpotifyResource(appURLString: String, webURLString: String) {
        if let appURL = URL(string: appURLString),
           NSWorkspace.shared.open(appURL) {
            return
        }

        guard let webURL = URL(string: webURLString) else { return }
        NSWorkspace.shared.open(webURL)
    }

    private func updateArtworkMenuItem(image: NSImage, size: CGFloat) {
        artworkMenuItem.view = ArtworkMenuView(image: image, size: size) { [weak self] in
            self?.playPause()
        }
        artworkMenuItem.isHidden = false
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let image = NSImage(size: size, flipped: false) { rect in
            (text as NSString).draw(in: rect, withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func previousTrack() {
        SpotifyService.previousTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lastTrack = nil
            self?.refreshNowPlaying(forceLikeRefresh: true)
        }
    }

    @objc private func playPause() {
        SpotifyService.playPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lastTrack = nil
            self?.refreshNowPlaying(forceLikeRefresh: true)
        }
    }

    @objc private func nextTrack() {
        SpotifyService.nextTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lastTrack = nil
            self?.refreshNowPlaying(forceLikeRefresh: true)
        }
    }

    @objc private func toggleLike() {
        guard SpotifyAPI.shared.isAuthorized, let track = lastTrack else { return }
        let currentTrackID = track.trackID
        let bareID = SpotifyService.bareTrackID(track.trackID)

        if currentLikedState {
            SpotifyAPI.shared.removeTrack(trackID: bareID) { [weak self] success in
                guard let self,
                      success,
                      self.lastTrack?.trackID == currentTrackID else { return }
                self.updateLikeMenuItem(liked: false)
            }
        } else {
            SpotifyAPI.shared.saveTrack(trackID: bareID) { [weak self] success in
                guard let self,
                      success,
                      self.lastTrack?.trackID == currentTrackID else { return }
                self.updateLikeMenuItem(liked: true)
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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 390),
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

    @objc private func openAbout() {
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About MenuPlay"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

struct SettingsView: View {
    @AppStorage("maxChars") private var maxChars: Int = defaultMaxChars
    @AppStorage("spotifyClientID") private var clientID: String = ""
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var authState: SpotifyAuthState = SpotifyAPI.shared.authState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Max characters")
                Spacer()
                TextField("", value: $maxChars, format: .number)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Limits the track title length in the menu bar (\(maxCharsRange.lowerBound)-\(maxCharsRange.upperBound)).")
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
                        launchAtLoginError = nil
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        launchAtLoginError = error.localizedDescription
                    }
                }

            if let launchAtLoginError {
                Text("Launch at login failed: \(launchAtLoginError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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

            if let errorMessage = authState.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if authState.isAuthorized {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect") {
                        SpotifyAPI.shared.logout()
                    }
                } else if authState == .authorizing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for Spotify callback...")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        SpotifyAPI.shared.cancelAuthorization()
                    }
                } else {
                    Button("Connect to Spotify") {
                        SpotifyAPI.shared.authorize()
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            maxChars = clampedMaxChars(maxChars)
            launchAtLogin = SMAppService.mainApp.status == .enabled
            authState = SpotifyAPI.shared.authState
        }
        .onChange(of: maxChars) { _, newValue in
            let clampedValue = clampedMaxChars(newValue)
            if newValue != clampedValue {
                maxChars = clampedValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spotifyAuthChanged)) { _ in
            authState = SpotifyAPI.shared.authState
        }
    }
}

struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/pro-verstka/menuplay")!
    private let versionText: String = {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let shortVersion, let buildVersion {
            return "\(shortVersion) (\(buildVersion))"
        }
        if let shortVersion {
            return shortVersion
        }
        if let buildVersion {
            return buildVersion
        }
        return "Unknown"
    }()

    var body: some View {
        VStack(spacing: 12) {
            Text("MenuPlay")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Spotify Now Playing in your macOS menu bar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            HStack {
                Text("Version")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(versionText)
            }

            HStack {
                Text("Author")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("pro-verstka")
            }

            HStack {
                Text("Git")
                    .foregroundStyle(.secondary)
                Spacer()
                Link("github.com/pro-verstka/menuplay", destination: repositoryURL)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 340, height: 200)
    }
}
