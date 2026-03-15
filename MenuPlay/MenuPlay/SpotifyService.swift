import AppKit

struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    let artworkURL: String
    let trackID: String
}

struct TrackEnhancementMetadata: Equatable {
    let albumID: String
    let primaryArtistID: String
    let albumReleaseYear: String?

    func albumText(for albumName: String) -> String {
        guard let albumReleaseYear, !albumReleaseYear.isEmpty else {
            return albumName
        }
        return "\(albumName) (\(albumReleaseYear))"
    }
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
    let playerPosition: Double
    let trackDuration: Double
}

final class SpotifyService {
    private struct ArtworkRequest {
        let size: CGFloat
        let completion: (NSImage?) -> Void
    }

    private static let artworkQueue = DispatchQueue(label: "com.menuplay.artwork")
    private static let originalArtworkCache = NSCache<NSString, NSImage>()
    private static let resizedArtworkCache = NSCache<NSString, NSImage>()
    private static let accentColorCache = NSCache<NSString, NSColor>()
    private static var pendingArtworkRequests: [String: [ArtworkRequest]] = [:]

    static func currentSnapshot() -> SpotifySnapshot {
        let script = """
        set playbackStateValue to "notRunning"
        set trackName to ""
        set trackArtist to ""
        set trackAlbum to ""
        set trackArtwork to ""
        set trackID to ""
        set playerPos to 0
        set trackDur to 0

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
                    set playerPos to ((player position) * 1000) as integer
                    set trackDur to duration of current track
                end if
            end tell
        end if

        return {playbackStateValue, trackName, trackArtist, trackAlbum, trackArtwork, trackID, playerPos, trackDur}
        """

        guard let appleScript = NSAppleScript(source: script) else {
            return SpotifySnapshot(playbackState: .notRunning, track: nil, playerPosition: 0, trackDuration: 0)
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil,
              result.numberOfItems == 8 else {
            return SpotifySnapshot(playbackState: .notRunning, track: nil, playerPosition: 0, trackDuration: 0)
        }

        let playbackState = SpotifyPlaybackState(
            rawValue: result.atIndex(1)?.stringValue ?? ""
        ) ?? .notRunning

        let name = result.atIndex(2)?.stringValue ?? ""
        let artist = result.atIndex(3)?.stringValue ?? ""
        let album = result.atIndex(4)?.stringValue ?? ""
        let artworkURL = result.atIndex(5)?.stringValue ?? ""
        let trackID = result.atIndex(6)?.stringValue ?? ""

        let playerPositionMs = Double(result.atIndex(7)?.int32Value ?? 0)
        let trackDurationMs = Double(result.atIndex(8)?.int32Value ?? 0)

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

        return SpotifySnapshot(playbackState: playbackState, track: track, playerPosition: playerPositionMs / 1000, trackDuration: trackDurationMs / 1000)
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

    static func seek(to positionSeconds: Double) {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify" to set player position to \(positionSeconds)
        end if
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
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

    static func accentColor(for url: String, from image: NSImage) -> NSColor {
        if let cached = accentColorCache.object(forKey: url as NSString) {
            return cached
        }
        let color = extractAccentColor(from: image)
        accentColorCache.setObject(color, forKey: url as NSString)
        return color
    }

    private static func extractAccentColor(from image: NSImage) -> NSColor {
        let sampleSize = 20
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixelData,
                  width: sampleSize,
                  height: sampleSize,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .white
        }

        let drawRect = CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .white
        }
        context.draw(cgImage, in: drawRect)

        let bucketCount = 12
        var bucketWeight = [Double](repeating: 0, count: bucketCount)
        var bucketHue = [Double](repeating: 0, count: bucketCount)
        var bucketSat = [Double](repeating: 0, count: bucketCount)
        var bucketBri = [Double](repeating: 0, count: bucketCount)

        let totalPixels = sampleSize * sampleSize
        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            let r = CGFloat(pixelData[offset]) / 255.0
            let g = CGFloat(pixelData[offset + 1]) / 255.0
            let b = CGFloat(pixelData[offset + 2]) / 255.0

            let color = NSColor(red: r, green: g, blue: b, alpha: 1.0)
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)

            if s < 0.15 || br < 0.15 || br > 0.95 { continue }

            let bucket = min(Int(h * Double(bucketCount)), bucketCount - 1)
            let weight = Double(s) * sqrt(Double(br))
            bucketWeight[bucket] += weight
            bucketHue[bucket] += Double(h) * weight
            bucketSat[bucket] += Double(s) * weight
            bucketBri[bucket] += Double(br) * weight
        }

        guard let maxBucket = bucketWeight.enumerated().max(by: { $0.element < $1.element }),
              maxBucket.element > 0 else {
            return .white
        }

        let idx = maxBucket.offset
        let w = bucketWeight[idx]
        let avgHue = bucketHue[idx] / w
        let avgSat = bucketSat[idx] / w
        let avgBri = min(max(bucketBri[idx] / w, 0.4), 0.85)

        let accent = NSColor(hue: avgHue, saturation: avgSat, brightness: avgBri, alpha: 1.0)

        // Sample bottom ~15% of bitmap (rows 17-19) to check contrast against progress bar area
        var bottomR = 0.0, bottomG = 0.0, bottomB = 0.0
        let bottomStartRow = sampleSize - 3
        let bottomPixelCount = 3 * sampleSize
        for row in bottomStartRow..<sampleSize {
            for col in 0..<sampleSize {
                let offset = (row * sampleSize + col) * bytesPerPixel
                bottomR += Double(pixelData[offset]) / 255.0
                bottomG += Double(pixelData[offset + 1]) / 255.0
                bottomB += Double(pixelData[offset + 2]) / 255.0
            }
        }
        bottomR /= Double(bottomPixelCount)
        bottomG /= Double(bottomPixelCount)
        bottomB /= Double(bottomPixelCount)
        let bottomLuminance = 0.299 * bottomR + 0.587 * bottomG + 0.114 * bottomB

        var accentR: CGFloat = 0, accentG: CGFloat = 0, accentB: CGFloat = 0, accentA: CGFloat = 0
        accent.getRed(&accentR, green: &accentG, blue: &accentB, alpha: &accentA)
        let accentLuminance = 0.299 * Double(accentR) + 0.587 * Double(accentG) + 0.114 * Double(accentB)

        if abs(accentLuminance - bottomLuminance) < 0.3 {
            return bottomLuminance < 0.5 ? .white : .black
        }

        return accent
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
