import AppKit
import CryptoKit

enum SpotifyAuthState: Equatable {
    case unauthorized
    case authorizing
    case authorized
    case failed(String)

    var isAuthorized: Bool {
        if case .authorized = self {
            return true
        }
        return false
    }

    var errorMessage: String? {
        if case let .failed(message) = self {
            return message
        }
        return nil
    }
}

final class SpotifyAPI {
    private struct TokenBundle: Codable {
        let accessToken: String
        let refreshToken: String?
    }

    private enum DefaultsKeys {
        static let clientID = "spotifyClientID"
        static let pendingAuthStartedAt = "spotifyPendingAuthStartedAt"
        static let pendingCodeVerifier = "spotifyPendingCodeVerifier"
        static let pendingOAuthState = "spotifyPendingOAuthState"
        static let hasStoredSession = "spotifyHasStoredSession"
    }

    private enum KeychainKeys {
        static let tokenBundle = "spotify.tokens"
    }

    private enum TokenRequestKind {
        case authorizationCode
        case refresh
    }

    static let shared = SpotifyAPI()

    private let redirectURI = "menuplay://callback"
    private let scopes = "user-library-read user-library-modify"
    private let authorizationTimeout: TimeInterval = 300

    private var authorizationTimeoutWorkItem: DispatchWorkItem?
    private var cachedTokenBundle: TokenBundle?
    private var hasLoadedTokenBundle = false
    private var trackMetadataCache: [String: TrackEnhancementMetadata] = [:]
    private var pendingTrackMetadataRequests: [String: [(TrackEnhancementMetadata?) -> Void]] = [:]
    private var pendingRefreshCompletions: [(Bool) -> Void]?

    private(set) var authState: SpotifyAuthState = .unauthorized

    var isAuthorized: Bool {
        authState.isAuthorized
    }

    private var clientID: String {
        UserDefaults.standard.string(forKey: DefaultsKeys.clientID) ?? ""
    }

    private var accessToken: String? {
        loadTokenBundleIfNeeded()?.accessToken
    }

    private var refreshToken: String? {
        loadTokenBundleIfNeeded()?.refreshToken
    }

    private var pendingCodeVerifier: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.pendingCodeVerifier) }
        set { updateDefaultString(newValue, forKey: DefaultsKeys.pendingCodeVerifier) }
    }

    private var pendingOAuthState: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.pendingOAuthState) }
        set { updateDefaultString(newValue, forKey: DefaultsKeys.pendingOAuthState) }
    }

    private var hasPendingAuthorization: Bool {
        pendingCodeVerifier != nil && pendingOAuthState != nil
    }

    private var pendingAuthStartedAt: Date? {
        get {
            let timestamp = UserDefaults.standard.double(forKey: DefaultsKeys.pendingAuthStartedAt)
            guard timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: DefaultsKeys.pendingAuthStartedAt)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.pendingAuthStartedAt)
            }
        }
    }

    private var hasStoredSessionHint: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.hasStoredSession) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.hasStoredSession) }
    }

    private init() {
        restoreAuthState()
    }

    // MARK: - Auth

    func authorize() {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            setAuthState(.failed("Enter a Spotify Client ID before connecting."))
            return
        }

        let verifier = generateRandomString(length: 64)
        let state = generateRandomString(length: 32)

        persistPendingAuthorization(verifier: verifier, state: state)

        let queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: sha256Base64(verifier)),
            URLQueryItem(name: "state", value: state),
        ]

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = queryItems

        guard let url = components?.url, NSWorkspace.shared.open(url) else {
            clearPendingAuthorization()
            setAuthState(.failed("Couldn't open Spotify authorization in the browser."))
            return
        }

        scheduleAuthorizationTimeout()
        setAuthState(.authorizing)
    }

    func handleCallback(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            clearPendingAuthorization()
            setAuthState(.failed(messageForAuthorizationError(error)))
            return
        }

        guard let returnedState = components?.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == pendingOAuthState else {
            clearPendingAuthorization()
            setAuthState(.failed("Rejected an unexpected Spotify callback. Try connecting again."))
            return
        }

        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier = pendingCodeVerifier else {
            clearPendingAuthorization()
            setAuthState(.failed("Spotify callback did not include a valid authorization code."))
            return
        }

        exchangeCode(code, verifier: verifier)
    }

    func logout() {
        clearTokens()
        clearPendingAuthorization()
        setAuthState(.unauthorized)
    }

    func cancelAuthorization() {
        clearPendingAuthorization()
        setAuthState(hasStoredSessionHint ? .authorized : .unauthorized)
    }

    private func exchangeCode(_ code: String, verifier: String) {
        let params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            "code_verifier": verifier,
        ]

        tokenRequest(params: params, kind: .authorizationCode) { success, message in
            guard !success, let message else { return }
            self.clearPendingAuthorization()
            self.setAuthState(.failed(message))
        }
    }

    private func refreshAccessToken(completion: @escaping (Bool) -> Void) {
        if pendingRefreshCompletions != nil {
            pendingRefreshCompletions?.append(completion)
            return
        }

        guard let refresh = refreshToken else {
            clearTokens()
            setAuthState(.failed("Spotify session expired. Connect again."))
            completion(false)
            return
        }

        pendingRefreshCompletions = [completion]

        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
        ]

        tokenRequest(params: params, kind: .refresh) { success, message in
            if !success {
                self.clearTokens()
                self.setAuthState(.failed(message ?? "Couldn't refresh the Spotify session."))
            }
            let completions = self.pendingRefreshCompletions ?? []
            self.pendingRefreshCompletions = nil
            completions.forEach { $0(success) }
        }
    }

    private func tokenRequest(
        params: [String: String],
        kind: TokenRequestKind,
        completion: @escaping (Bool, String?) -> Void
    ) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(encodedValue)"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = data.flatMap(Self.parseJSONObject)

            guard error == nil, (200..<300).contains(statusCode),
                  let payload,
                  let token = payload["access_token"] as? String else {
                let message = Self.spotifyAPIErrorMessage(
                    payload: payload,
                    fallback: error?.localizedDescription ?? "Spotify rejected the request."
                )
                DispatchQueue.main.async {
                    completion(false, message)
                }
                return
            }

            DispatchQueue.main.async {
                let persisted = self.persistTokenBundle(
                    TokenBundle(
                        accessToken: token,
                        refreshToken: payload["refresh_token"] as? String ?? self.cachedTokenBundle?.refreshToken
                    )
                )

                guard persisted else {
                    self.clearPendingAuthorization()
                    self.setAuthState(.failed("Couldn't store the Spotify session in Keychain."))
                    completion(false, "Couldn't store the Spotify session in Keychain.")
                    return
                }

                if kind == .authorizationCode {
                    self.clearPendingAuthorization()
                }
                self.setAuthState(.authorized)
                completion(true, nil)
            }
        }.resume()
    }

    // MARK: - Library API

    private func encodedTrackURI(_ trackID: String) -> String {
        "spotify:track:\(trackID)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
    }

    func isTrackSaved(trackID: String, completion: @escaping (Bool) -> Void) {
        let uri = encodedTrackURI(trackID)
        apiRequest(path: "/v1/me/library/contains?uris=\(uri)") { data in
            guard let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Bool] else {
                completion(false)
                return
            }
            completion(arr.first ?? false)
        }
    }

    func saveTrack(trackID: String, completion: @escaping (Bool) -> Void) {
        let uri = encodedTrackURI(trackID)
        apiRequest(path: "/v1/me/library?uris=\(uri)", method: "PUT") { data in
            completion(data != nil)
        }
    }

    func removeTrack(trackID: String, completion: @escaping (Bool) -> Void) {
        let uri = encodedTrackURI(trackID)
        apiRequest(path: "/v1/me/library?uris=\(uri)", method: "DELETE") { data in
            completion(data != nil)
        }
    }

    func fetchTrackMetadata(trackID: String, completion: @escaping (TrackEnhancementMetadata?) -> Void) {
        guard isAuthorized else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let bareID = SpotifyService.bareTrackID(trackID)
        if let cached = trackMetadataCache[bareID] {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        if pendingTrackMetadataRequests[bareID] != nil {
            pendingTrackMetadataRequests[bareID]?.append(completion)
            return
        }

        pendingTrackMetadataRequests[bareID] = [completion]
        apiRequest(path: "/v1/tracks/\(bareID)") { [weak self] data in
            guard let self else { return }
            let metadata = data.flatMap(Self.parseTrackMetadata)

            if let metadata {
                self.trackMetadataCache[bareID] = metadata
            }

            let completions = self.pendingTrackMetadataRequests.removeValue(forKey: bareID) ?? []
            completions.forEach { $0(metadata) }
        }
    }

    private func apiRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        retried: Bool = false,
        completion: @escaping (Data?) -> Void
    ) {
        guard let token = accessToken else {
            if authState.isAuthorized {
                clearTokens()
                setAuthState(.failed("Couldn't access the saved Spotify session. Connect again."))
            }
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: URL(string: "https://api.spotify.com\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && !retried {
                DispatchQueue.main.async {
                    self.refreshAccessToken { refreshed in
                        guard refreshed else {
                            DispatchQueue.main.async { completion(nil) }
                            return
                        }
                        self.apiRequest(path: path, method: method, body: body, retried: true, completion: completion)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                completion((200..<300).contains(status) ? (data ?? Data()) : nil)
            }
        }.resume()
    }

    // MARK: - Persistence

    private func restoreAuthState() {
        if hasPendingAuthorization {
            guard let startedAt = pendingAuthStartedAt else {
                clearPendingAuthorization()
                setAuthState(hasStoredSessionHint ? .authorized : .failed("Spotify authorization timed out. Connect again."))
                return
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed < authorizationTimeout else {
                clearPendingAuthorization()
                setAuthState(hasStoredSessionHint ? .authorized : .failed("Spotify authorization timed out. Connect again."))
                return
            }

            scheduleAuthorizationTimeout(from: startedAt)
            setAuthState(.authorizing)
            return
        }

        setAuthState(hasStoredSessionHint ? .authorized : .unauthorized)
    }

    private func persistPendingAuthorization(verifier: String, state: String) {
        pendingCodeVerifier = verifier
        pendingOAuthState = state
        pendingAuthStartedAt = Date()
    }

    private func clearTokens() {
        cachedTokenBundle = nil
        hasLoadedTokenBundle = true
        hasStoredSessionHint = false
        _ = KeychainStore.delete(KeychainKeys.tokenBundle)
    }

    private func clearPendingAuthorization() {
        authorizationTimeoutWorkItem?.cancel()
        authorizationTimeoutWorkItem = nil
        pendingCodeVerifier = nil
        pendingOAuthState = nil
        pendingAuthStartedAt = nil
    }

    private func loadTokenBundleIfNeeded() -> TokenBundle? {
        if hasLoadedTokenBundle {
            return cachedTokenBundle
        }

        guard let data = KeychainStore.data(for: KeychainKeys.tokenBundle),
              let bundle = try? JSONDecoder().decode(TokenBundle.self, from: data) else {
            cachedTokenBundle = nil
            hasLoadedTokenBundle = true
            hasStoredSessionHint = false
            return nil
        }

        cachedTokenBundle = bundle
        hasLoadedTokenBundle = true
        hasStoredSessionHint = true
        return bundle
    }

    private func persistTokenBundle(_ bundle: TokenBundle) -> Bool {
        guard let data = try? JSONEncoder().encode(bundle),
              KeychainStore.set(data, for: KeychainKeys.tokenBundle) else {
            return false
        }

        cachedTokenBundle = bundle
        hasLoadedTokenBundle = true
        hasStoredSessionHint = true
        return true
    }

    private func updateDefaultString(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    private func scheduleAuthorizationTimeout(from startedAt: Date = Date()) {
        authorizationTimeoutWorkItem?.cancel()

        let remaining = authorizationTimeout - Date().timeIntervalSince(startedAt)
        guard remaining > 0 else {
            clearPendingAuthorization()
            setAuthState(hasStoredSessionHint ? .authorized : .failed("Spotify authorization timed out. Connect again."))
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.hasPendingAuthorization else { return }
            self.clearPendingAuthorization()
            self.setAuthState(self.hasStoredSessionHint ? .authorized : .failed("Spotify authorization timed out. Connect again."))
        }

        authorizationTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
    }

    private func setAuthState(_ newState: SpotifyAuthState) {
        let apply = {
            guard self.authState != newState else { return }
            self.authState = newState
            NotificationCenter.default.post(name: .spotifyAuthChanged, object: nil)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private static func parseJSONObject(data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parseTrackMetadata(data: Data) -> TrackEnhancementMetadata? {
        guard let payload = parseJSONObject(data: data),
              let album = payload["album"] as? [String: Any],
              let albumID = album["id"] as? String,
              !albumID.isEmpty,
              let artists = payload["artists"] as? [[String: Any]],
              let primaryArtist = artists.first,
              let primaryArtistID = primaryArtist["id"] as? String,
              !primaryArtistID.isEmpty else {
            return nil
        }

        let releaseDate = album["release_date"] as? String
        let releaseYear = releaseDate.flatMap { date -> String? in
            let trimmedDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedDate.count >= 4 else { return nil }
            return String(trimmedDate.prefix(4))
        }

        return TrackEnhancementMetadata(
            albumID: albumID,
            primaryArtistID: primaryArtistID,
            albumReleaseYear: releaseYear
        )
    }

    private static func spotifyAPIErrorMessage(payload: [String: Any]?, fallback: String) -> String {
        if let description = payload?["error_description"] as? String, !description.isEmpty {
            return description
        }
        if let error = payload?["error"] as? String, !error.isEmpty {
            return error
        }
        return fallback
    }

    private func messageForAuthorizationError(_ error: String) -> String {
        switch error {
        case "access_denied":
            return "Spotify authorization was cancelled."
        default:
            return "Spotify authorization failed: \(error)."
        }
    }

    private func generateRandomString(length: Int) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    private func sha256Base64(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Notification.Name {
    static let spotifyAuthChanged = Notification.Name("spotifyAuthChanged")
}
