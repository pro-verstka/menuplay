import AppKit

struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    let artworkURL: String
    let trackID: String
}

enum SpotifyPlaybackState: String, Equatable {
    case notRunning
    case stopped
    case paused
    case playing

    var pollInterval: TimeInterval {
        switch self {
        case .playing:
            return 3
        case .paused:
            return 8
        case .stopped:
            return 12
        case .notRunning:
            return 20
        }
    }

    var playPauseTitle: String {
        self == .playing ? "Pause" : "Play"
    }

    var playPauseSymbolName: String {
        self == .playing ? "pause.fill" : "play.fill"
    }

    var canControlPlayback: Bool {
        self == .playing || self == .paused
    }

    var statusTitle: String {
        switch self {
        case .notRunning:
            return "Spotify is not running"
        case .stopped:
            return "Playback stopped"
        case .paused:
            return "Playback paused"
        case .playing:
            return "Now playing"
        }
    }

    var statusSubtitle: String {
        switch self {
        case .notRunning:
            return "Open Spotify to see track info and controls."
        case .stopped:
            return "Start playback to show the current track."
        case .paused:
            return "Resume playback or choose another track."
        case .playing:
            return ""
        }
    }
}

struct SpotifySnapshot {
    let playbackState: SpotifyPlaybackState
    let track: TrackInfo?
}

final class SpotifyService {
    private struct ArtworkRequest {
        let size: CGFloat
        let completion: (NSImage?) -> Void
    }

    private static let artworkQueue = DispatchQueue(label: "com.menuplay.artwork")
    private static let originalArtworkCache = NSCache<NSString, NSImage>()
    private static let resizedArtworkCache = NSCache<NSString, NSImage>()
    private static var pendingArtworkRequests: [String: [ArtworkRequest]] = [:]

    static func currentSnapshot() -> SpotifySnapshot {
        let script = """
        set playbackStateValue to "notRunning"
        set trackName to ""
        set trackArtist to ""
        set trackAlbum to ""
        set trackArtwork to ""
        set trackID to ""

        if application "Spotify" is running then
            tell application "Spotify"
                if player state is stopped then
                    set playbackStateValue to "stopped"
                else
                    if player state is playing then
                        set playbackStateValue to "playing"
                    else
                        set playbackStateValue to "paused"
                    end if
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackArtwork to artwork url of current track
                    set trackID to id of current track
                end if
            end tell
        end if

        return {playbackStateValue, trackName, trackArtist, trackAlbum, trackArtwork, trackID}
        """

        guard let appleScript = NSAppleScript(source: script) else {
            return SpotifySnapshot(playbackState: .notRunning, track: nil)
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil,
              result.numberOfItems == 6 else {
            return SpotifySnapshot(playbackState: .notRunning, track: nil)
        }

        let playbackState = SpotifyPlaybackState(
            rawValue: result.atIndex(1)?.stringValue ?? ""
        ) ?? .notRunning

        let name = result.atIndex(2)?.stringValue ?? ""
        let artist = result.atIndex(3)?.stringValue ?? ""
        let album = result.atIndex(4)?.stringValue ?? ""
        let artworkURL = result.atIndex(5)?.stringValue ?? ""
        let trackID = result.atIndex(6)?.stringValue ?? ""

        let track: TrackInfo?
        if name.isEmpty {
            track = nil
        } else {
            track = TrackInfo(
                name: name,
                artist: artist,
                album: album,
                artworkURL: artworkURL,
                trackID: trackID
            )
        }

        return SpotifySnapshot(playbackState: playbackState, track: track)
    }

    /// Extract bare Spotify ID from URI like "spotify:track:ABC123"
    static func bareTrackID(_ spotifyURI: String) -> String {
        spotifyURI.components(separatedBy: ":").last ?? spotifyURI
    }

    static func previousTrack() {
        runSpotifyCommand("previous track")
    }

    static func playPause() {
        runSpotifyCommand("playpause")
    }

    static func nextTrack() {
        runSpotifyCommand("next track")
    }

    private static func runSpotifyCommand(_ command: String) {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify" to \(command)
        end if
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }

    static func loadArtwork(from urlString: String, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let resizedKey = resizedCacheKey(urlString: urlString, size: size)
        if let cachedResized = resizedArtworkCache.object(forKey: resizedKey as NSString) {
            DispatchQueue.main.async { completion(cachedResized) }
            return
        }

        if let originalImage = originalArtworkCache.object(forKey: urlString as NSString) {
            let resized = resizedArtwork(for: originalImage, size: size)
            resizedArtworkCache.setObject(resized, forKey: resizedKey as NSString)
            DispatchQueue.main.async { completion(resized) }
            return
        }

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let request = ArtworkRequest(size: size, completion: completion)
        var shouldStartDownload = false

        artworkQueue.sync {
            if pendingArtworkRequests[urlString] != nil {
                pendingArtworkRequests[urlString]?.append(request)
            } else {
                pendingArtworkRequests[urlString] = [request]
                shouldStartDownload = true
            }
        }

        guard shouldStartDownload else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            let baseImage = data.flatMap(NSImage.init(data:))
            if let baseImage {
                originalArtworkCache.setObject(baseImage, forKey: urlString as NSString)
            }

            let requests = artworkQueue.sync { () -> [ArtworkRequest] in
                let requests = pendingArtworkRequests[urlString] ?? []
                pendingArtworkRequests[urlString] = nil
                return requests
            }

            for request in requests {
                let image = baseImage.map { image in
                    let resized = resizedArtwork(for: image, size: request.size)
                    let key = resizedCacheKey(urlString: urlString, size: request.size)
                    resizedArtworkCache.setObject(resized, forKey: key as NSString)
                    return resized
                }

                DispatchQueue.main.async {
                    request.completion(image)
                }
            }
        }.resume()
    }

    private static func resizedCacheKey(urlString: String, size: CGFloat) -> String {
        "\(urlString)#\(Int(size.rounded()))"
    }

    private static func resizedArtwork(for image: NSImage, size: CGFloat) -> NSImage {
        let resized = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        resized.isTemplate = false
        return resized
    }
}
