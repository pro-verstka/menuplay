import AppKit
import CryptoKit

final class SpotifyAPI {
    static let shared = SpotifyAPI()

    private let redirectURI = "menuplay://callback"
    private let scopes = "user-library-read user-library-modify"
    private var codeVerifier: String?

    var isAuthorized: Bool {
        accessToken != nil
    }

    private var clientID: String {
        UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
    }

    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: "spotifyAccessToken") }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyAccessToken") }
    }

    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: "spotifyRefreshToken") }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyRefreshToken") }
    }

    // MARK: - Auth

    func authorize() {
        let id = clientID
        guard !id.isEmpty else { return }

        let verifier = generateRandomString(length: 64)
        codeVerifier = verifier
        let challenge = sha256Base64(verifier)

        let encodedRedirect = redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let urlString = "https://accounts.spotify.com/authorize"
            + "?client_id=\(id)"
            + "&response_type=code"
            + "&redirect_uri=\(encodedRedirect)"
            + "&scope=user-library-read%20user-library-modify"
            + "&code_challenge_method=S256"
            + "&code_challenge=\(challenge)"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    func handleCallback(url: URL) {
        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier = codeVerifier else { return }

        exchangeCode(code, verifier: verifier)
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
    }

    private func exchangeCode(_ code: String, verifier: String) {
        let params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        tokenRequest(params: params)
    }

    private func refreshAccessToken(completion: (() -> Void)? = nil) {
        guard let refresh = refreshToken else { return }
        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
        ]
        tokenRequest(params: params, completion: completion)
    }

    private func tokenRequest(params: [String: String], completion: (() -> Void)? = nil) {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&").data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                DispatchQueue.main.async { completion?() }
                return
            }
            DispatchQueue.main.async {
                self.accessToken = token
                if let refresh = json["refresh_token"] as? String {
                    self.refreshToken = refresh
                }
                NotificationCenter.default.post(name: .spotifyAuthChanged, object: nil)
                completion?()
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
            guard let data = data,
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

    private func apiRequest(path: String, method: String = "GET", body: Data? = nil, retried: Bool = false, completion: @escaping (Data?) -> Void) {
        guard let token = accessToken else {
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
                self.refreshAccessToken {
                    self.apiRequest(path: path, method: method, body: body, retried: true, completion: completion)
                }
                return
            }
            DispatchQueue.main.async {
                completion(status >= 200 && status < 300 ? (data ?? Data()) : nil)
            }
        }.resume()
    }

    // MARK: - PKCE helpers

    private func generateRandomString(length: Int) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        return String((0..<length).map { _ in chars.randomElement()! })
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
