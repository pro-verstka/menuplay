import AppKit

struct TrackInfo: Equatable {
    let name: String
    let artist: String
    let album: String
    let artworkURL: String
    let trackID: String
}

final class SpotifyService {

    private static let separator = "|||"

    static func getCurrentTrack() -> TrackInfo? {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is not stopped then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackArtwork to artwork url of current track
                    set trackID to id of current track
                    return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackArtwork & "|||" & trackID
                end if
            end tell
        end if
        return ""
        """

        guard let appleScript = NSAppleScript(source: script) else { return nil }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        guard error == nil else { return nil }

        let output = result.stringValue ?? ""
        let parts = output.components(separatedBy: separator)
        guard parts.count == 5, !parts[0].isEmpty else { return nil }

        return TrackInfo(name: parts[0], artist: parts[1], album: parts[2], artworkURL: parts[3], trackID: parts[4])
    }

    /// Extract bare Spotify ID from URI like "spotify:track:ABC123"
    static func bareTrackID(_ spotifyURI: String) -> String {
        spotifyURI.components(separatedBy: ":").last ?? spotifyURI
    }

    static func isPlaying() -> Bool {
        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then return "1"
            end tell
        end if
        return "0"
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        return result.stringValue == "1"
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
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let resized = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
            resized.isTemplate = false

            DispatchQueue.main.async { completion(resized) }
        }.resume()
    }
}
