//
//  SpotifyManager.swift
//  Maloy
//
//  Spotify Web API integration for voice-controlled music playback
//

import Foundation
import Combine

class SpotifyManager: ObservableObject {
    @Published var isAuthorized = false
    @Published var currentTrack: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpirationDate: Date?

    private let clientID = Config.spotifyClientID
    private let clientSecret = Config.spotifyClientSecret
    private let redirectURI = Config.spotifyRedirectURI

    // MARK: - OAuth Authorization

    /// Generate authorization URL for user login
    func getAuthorizationURL() -> URL? {
        let scopes = [
            "user-read-playback-state",
            "user-modify-playback-state",
            "user-read-currently-playing",
            "streaming"
        ].joined(separator: "%20")

        let urlString = "https://accounts.spotify.com/authorize?" +
            "client_id=\(clientID)" +
            "&response_type=code" +
            "&redirect_uri=\(redirectURI)" +
            "&scope=\(scopes)"

        return URL(string: urlString)
    }

    /// Exchange authorization code for access token
    func exchangeCodeForToken(code: String, completion: @escaping (Bool) -> Void) {
        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Basic auth header
        let credentials = "\(clientID):\(clientSecret)"
        let credentialsData = credentials.data(using: .utf8)!
        let base64Credentials = credentialsData.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Request body
        let bodyParams = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI
        ]
        let bodyString = bodyParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        print("🎵 Exchanging code for Spotify token...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Token exchange error: \(error)")
                completion(false)
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                print("❌ No access token in response")
                completion(false)
                return
            }

            self.accessToken = accessToken
            self.refreshToken = json["refresh_token"] as? String

            if let expiresIn = json["expires_in"] as? Int {
                self.tokenExpirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            }

            DispatchQueue.main.async {
                self.isAuthorized = true
                print("✅ Spotify authorized successfully")
                completion(true)
            }
        }.resume()
    }

    // MARK: - Playback Control

    /// Play/Resume playback
    func play(completion: @escaping (Bool) -> Void) {
        makeSpotifyRequest(endpoint: "me/player/play", method: "PUT", completion: completion)
    }

    /// Pause playback
    func pause(completion: @escaping (Bool) -> Void) {
        makeSpotifyRequest(endpoint: "me/player/pause", method: "PUT", completion: completion)
    }

    /// Skip to next track
    func next(completion: @escaping (Bool) -> Void) {
        makeSpotifyRequest(endpoint: "me/player/next", method: "POST", completion: completion)
    }

    /// Skip to previous track
    func previous(completion: @escaping (Bool) -> Void) {
        makeSpotifyRequest(endpoint: "me/player/previous", method: "POST", completion: completion)
    }

    /// Search for tracks
    func search(query: String, completion: @escaping ([String]?) -> Void) {
        guard let token = accessToken else {
            print("❌ No access token")
            completion(nil)
            return
        }

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.spotify.com/v1/search?q=\(encodedQuery)&type=track&limit=5"

        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        print("🔍 Searching Spotify: \"\(query)\"")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [String: Any],
                  let items = tracks["items"] as? [[String: Any]] else {
                print("❌ Search failed")
                completion(nil)
                return
            }

            let results = items.compactMap { item -> String? in
                guard let name = item["name"] as? String,
                      let artists = item["artists"] as? [[String: Any]],
                      let artist = artists.first?["name"] as? String else {
                    return nil
                }
                return "\(name) - \(artist)"
            }

            print("✅ Found \(results.count) tracks")
            completion(results)
        }.resume()
    }

    /// Play a specific track by URI
    func playTrack(uri: String, completion: @escaping (Bool) -> Void) {
        guard let token = accessToken else {
            completion(false)
            return
        }

        let url = URL(string: "https://api.spotify.com/v1/me/player/play")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["uris": [uri]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 204
            DispatchQueue.main.async {
                completion(success)
            }
        }.resume()
    }

    // MARK: - Helper Methods

    private func makeSpotifyRequest(endpoint: String, method: String, body: [String: Any]? = nil, completion: @escaping (Bool) -> Void) {
        guard let token = accessToken else {
            print("❌ No access token for \(endpoint)")
            completion(false)
            return
        }

        let url = URL(string: "https://api.spotify.com/v1/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        print("🎵 Spotify API: \(method) /\(endpoint)")

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("❌ Request error: \(error)")
                completion(false)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let success = statusCode == 204 || statusCode == 200

            if success {
                print("✅ \(endpoint) success")
            } else {
                print("❌ \(endpoint) failed with status \(statusCode)")
            }

            DispatchQueue.main.async {
                completion(success)
            }
        }.resume()
    }
}
