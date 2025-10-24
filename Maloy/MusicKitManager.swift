//
//  MusicKitManager.swift
//  Maloy
//
//  Apple Music integration using MusicKit
//  Provides embedded music player with full control
//

import Foundation
import MusicKit
import Combine

@available(iOS 15.0, *)
class MusicKitManager: ObservableObject {
    @Published var isAuthorized = false
    @Published var currentSong: String?

    private let player = ApplicationMusicPlayer.shared

    init() {
        // Check authorization status on init
        checkAuthorization()
    }

    // MARK: - Authorization

    /// Check and request MusicKit authorization
    func checkAuthorization() {
        Task {
            let status = await MusicAuthorization.request()

            await MainActor.run {
                switch status {
                case .authorized:
                    self.isAuthorized = true
                    print("✅ MusicKit authorized")
                case .denied:
                    self.isAuthorized = false
                    print("❌ MusicKit access denied")
                case .restricted:
                    self.isAuthorized = false
                    print("⚠️ MusicKit access restricted")
                case .notDetermined:
                    self.isAuthorized = false
                    print("⚠️ MusicKit authorization not determined")
                @unknown default:
                    self.isAuthorized = false
                    print("⚠️ Unknown MusicKit authorization status")
                }
            }
        }
    }

    // MARK: - Search and Playback

    /// Search for a song and play it
    func searchAndPlay(query: String, completion: @escaping (Bool, String) -> Void) {
        print("🎵 searchAndPlay called with query: \"\(query)\"")
        print("🎵 isAuthorized: \(isAuthorized)")

        guard isAuthorized else {
            print("❌ MusicKit not authorized!")
            completion(false, "Нужен доступ к Apple Music. Проверь настройки.")
            return
        }

        print("🔍 Searching Apple Music: \"\(query)\"")

        Task {
            do {
                // Check subscription status
                let subscription = try await MusicSubscription.current
                let canPlay = subscription.canPlayCatalogContent
                print("📱 Subscription canPlayCatalogContent: \(canPlay)")
                print("📱 Subscription canBecomeSubscriber: \(subscription.canBecomeSubscriber)")

                // CRITICAL: If can't play catalog, fail immediately with clear message
                guard canPlay else {
                    await MainActor.run {
                        completion(false, "Нужна активная подписка Apple Music")
                    }
                    return
                }

                // Try CATALOG search first (requires Developer Token)
                print("🔍 Trying CATALOG search...")
                var catalogRequest = MusicCatalogSearchRequest(term: query, types: [Song.self])
                catalogRequest.limit = 10

                do {
                    let catalogResponse = try await catalogRequest.response()
                    let count = catalogResponse.songs.count
                    print("✅ CATALOG search succeeded! Songs count: \(count)")

                    guard let song = catalogResponse.songs.first else {
                        await MainActor.run {
                            completion(false, "Не нашёл '\(query)' в Apple Music")
                        }
                        return
                    }

                    let songTitle = song.title
                    let artistName = song.artistName
                    print("✅ Found: \(songTitle) - \(artistName)")

                    // Set player queue and play
                    player.queue = [song]
                    try await player.play()

                    await MainActor.run {
                        self.currentSong = "\(songTitle) - \(artistName)"
                        completion(true, "Включаю \(songTitle) — \(artistName)")
                    }
                    return

                } catch {
                    print("⚠️ CATALOG search failed: \(error)")
                    print("⚠️ This is expected without MusicKit Identifier")
                    print("🔄 Falling back to LIBRARY search...")
                }

                // Fallback: Search in user's personal library
                print("🔍 Searching in user's LIBRARY...")
                var libraryRequest = MusicLibraryRequest<Song>()
                libraryRequest.limit = 100 // Get more songs to filter

                let libraryResponse = try await libraryRequest.response()
                print("📚 Library has \(libraryResponse.items.count) songs total")

                // Filter by query
                let queryLower = query.lowercased()
                let matchingSongs = libraryResponse.items.filter { song in
                    let titleMatch = song.title.lowercased().contains(queryLower)
                    let artistMatch = song.artistName.lowercased().contains(queryLower)
                    return titleMatch || artistMatch
                }

                print("✅ Found \(matchingSongs.count) matching songs in library")

                guard let song = matchingSongs.first else {
                    await MainActor.run {
                        completion(false, "Не нашёл '\(query)' ни в каталоге, ни в твоей библиотеке")
                    }
                    return
                }

                let songTitle = song.title
                let artistName = song.artistName
                print("✅ Found in library: \(songTitle) - \(artistName)")

                // Set player queue and play
                player.queue = [song]
                try await player.play()

                await MainActor.run {
                    self.currentSong = "\(songTitle) - \(artistName)"
                    completion(true, "Включаю \(songTitle) — \(artistName)")
                }

            } catch {
                print("❌ MusicKit search error: \(error)")
                print("❌ Error type: \(type(of: error))")
                print("❌ Error details: \(String(describing: error))")
                await MainActor.run {
                    completion(false, "Ошибка поиска музыки: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Play/Resume playback
    func play() {
        Task {
            do {
                try await player.play()
                print("▶️ Resumed playback")
            } catch {
                print("❌ Play error: \(error)")
            }
        }
    }

    /// Pause playback
    func pause() {
        player.pause()
        print("⏸️ Paused playback")
    }

    /// Skip to next track
    func next() {
        Task {
            do {
                try await player.skipToNextEntry()
                print("⏭️ Skipped to next track")
            } catch {
                print("❌ Skip next error: \(error)")
            }
        }
    }

    /// Skip to previous track
    func previous() {
        Task {
            do {
                try await player.skipToPreviousEntry()
                print("⏮️ Skipped to previous track")
            } catch {
                print("❌ Skip previous error: \(error)")
            }
        }
    }

    /// Stop playback completely
    func stop() {
        player.stop()
        currentSong = nil
        print("⏹️ Playback stopped")
    }
}
