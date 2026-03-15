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

        // Phase 1: Classify pixels into chromatic/achromatic, bucket chromatic ones
        let bucketCount = 12
        var bucketWeight = [Double](repeating: 0, count: bucketCount)
        var bucketHue = [Double](repeating: 0, count: bucketCount)
        var bucketSat = [Double](repeating: 0, count: bucketCount)
        var bucketBri = [Double](repeating: 0, count: bucketCount)
        var chromaticCount = 0

        let totalPixels = sampleSize * sampleSize
        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            let r = CGFloat(pixelData[offset]) / 255.0
            let g = CGFloat(pixelData[offset + 1]) / 255.0
            let b = CGFloat(pixelData[offset + 2]) / 255.0

            let color = NSColor(red: r, green: g, blue: b, alpha: 1.0)
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)

            guard s >= 0.12, br >= 0.10 else { continue }
            chromaticCount += 1

            let bucket = min(Int(h * Double(bucketCount)), bucketCount - 1)
            let weight = Double(s) * sqrt(Double(br))
            bucketWeight[bucket] += weight
            bucketHue[bucket] += Double(h) * weight
            bucketSat[bucket] += Double(s) * weight
            bucketBri[bucket] += Double(br) * weight
        }

        // Phase 2: Analyze bottom 15% (rows 17-19)
        var bottomR = 0.0, bottomG = 0.0, bottomB = 0.0
        var bottomH = 0.0, bottomS = 0.0, bottomBr = 0.0
        let bottomStartRow = sampleSize - 3
        let bottomPixelCount = 3 * sampleSize
        for row in bottomStartRow..<sampleSize {
            for col in 0..<sampleSize {
                let offset = (row * sampleSize + col) * bytesPerPixel
                let r = Double(pixelData[offset]) / 255.0
                let g = Double(pixelData[offset + 1]) / 255.0
                let b = Double(pixelData[offset + 2]) / 255.0
                bottomR += r
                bottomG += g
                bottomB += b
                let c = NSColor(red: r, green: g, blue: b, alpha: 1.0)
                var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
                bottomH += Double(h)
                bottomS += Double(s)
                bottomBr += Double(br)
            }
        }
        bottomR /= Double(bottomPixelCount)
        bottomG /= Double(bottomPixelCount)
        bottomB /= Double(bottomPixelCount)
        let bottomLuminance = 0.299 * bottomR + 0.587 * bottomG + 0.114 * bottomB
        let bottomAvgHue = bottomH / Double(bottomPixelCount)
        let bottomAvgBri = bottomBr / Double(bottomPixelCount)

        // Phase 3: Choose color by case
        let chromaticRatio = Double(chromaticCount) / Double(totalPixels)

        // Case A: Achromatic cover
        if chromaticRatio < 0.05 {
            return bottomLuminance < 0.5 ? .white : .black
        }

        // We have chromatic content — find dominant bucket
        guard let maxBucket = bucketWeight.enumerated().max(by: { $0.element < $1.element }),
              maxBucket.element > 0 else {
            return bottomLuminance < 0.5 ? .white : .black
        }

        let idx = maxBucket.offset
        let w = bucketWeight[idx]
        let avgHue = bucketHue[idx] / w
        let avgSat = bucketSat[idx] / w
        let avgBri = bucketBri[idx] / w

        let finalHue = avgHue
        var finalSat: Double
        var finalBri: Double

        if chromaticRatio < 0.35 {
            // Case B: Accent minority (e.g. gold symbol on black)
            finalSat = max(avgSat, 0.5)
            if bottomLuminance < 0.35 {
                finalBri = min(max(avgBri, 0.65), 0.95)
            } else if bottomLuminance > 0.65 {
                finalBri = min(max(avgBri, 0.35), 0.60)
            } else {
                finalBri = min(max(avgBri, 0.50), 0.85)
            }
        } else {
            // Case C: Dominant chromatic
            let hueDiff = abs(avgHue - bottomAvgHue)
            let hueDist = min(hueDiff, 1.0 - hueDiff)

            if hueDist < 0.08 {
                // Case C1: Accent hue matches background (monochrome cover)
                finalSat = min(avgSat + 0.15, 1.0)
                if bottomAvgBri > 0.55 {
                    finalBri = bottomAvgBri - 0.30
                } else if bottomAvgBri < 0.45 {
                    finalBri = bottomAvgBri + 0.35
                } else {
                    finalBri = 0.85
                }
                finalBri = min(max(finalBri, 0.25), 0.95)
            } else {
                // Case C2: Accent hue differs from background
                finalBri = min(max(avgBri, 0.40), 0.85)
                finalSat = avgSat
                let accentLum = 0.299 * finalBri + 0.587 * finalBri + 0.114 * finalBri
                if abs(accentLum - bottomLuminance) < 0.2 {
                    finalBri += bottomLuminance < 0.5 ? 0.25 : -0.25
                    finalBri = min(max(finalBri, 0.40), 0.85)
                }
            }
        }

        // Phase 4: Final contrast safety
        let resultColor = NSColor(hue: finalHue, saturation: finalSat, brightness: finalBri, alpha: 1.0)
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        resultColor.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        let accentLuminance = 0.299 * Double(rr) + 0.587 * Double(rg) + 0.114 * Double(rb)

        if abs(accentLuminance - bottomLuminance) < 0.15 {
            if bottomLuminance < 0.5 {
                finalBri += 0.20
            } else {
                finalBri -= 0.20
            }
            finalBri = min(max(finalBri, 0.15), 0.95)
        }

        return NSColor(hue: finalHue, saturation: finalSat, brightness: finalBri, alpha: 1.0)
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
