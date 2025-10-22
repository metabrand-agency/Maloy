//
//  MaloyApp.swift
//  Maloy
//
//  Created by dmitry.komissarov on 19/10/2025.
//

import SwiftUI

@main
struct MaloyApp: App {
    @StateObject private var spotifyManager = SpotifyManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(spotifyManager)
                .onOpenURL { url in
                    handleSpotifyCallback(url: url)
                }
        }
    }

    /// Handle Spotify OAuth callback deep link
    private func handleSpotifyCallback(url: URL) {
        print("🔗 Deep link received: \(url)")

        // Check if it's our maloy:// callback
        guard url.scheme == "maloy",
              url.host == "callback" else {
            print("⚠️ Not a Spotify callback URL")
            return
        }

        // Extract authorization code from URL
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            print("❌ No authorization code in callback URL")
            return
        }

        print("✅ Got authorization code, exchanging for token...")

        // Exchange code for access token
        spotifyManager.exchangeCodeForToken(code: code) { success in
            if success {
                print("🎉 Spotify authorization complete!")
            } else {
                print("❌ Failed to exchange code for token")
            }
        }
    }
}
