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
    private var currentPlaylist: [Song] = []
    private var currentTrackIndex: Int = 0

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

    /// Helper: Create playlist from songs collection
    private func createPlaylist(from songs: MusicItemCollection<Song>, maxSize: Int) -> [Song] {
        let size = min(maxSize, songs.count)
        var result: [Song] = []
        result.reserveCapacity(size)
        var idx = 0
        for song in songs {
            if idx >= size { break }
            result.append(song)
            idx += 1
        }
        return result
    }

    /// Helper: Create playlist from array of songs
    private func createPlaylistFromArray(from songs: [Song], maxSize: Int) -> [Song] {
        let size = min(maxSize, songs.count)
        var result: [Song] = []
        result.reserveCapacity(size)
        var idx = 0
        for song in songs {
            if idx >= size { break }
            result.append(song)
            idx += 1
        }
        return result
    }

    /// Async helper for searchAndPlay
    private func performSearch(query: String, completion: @escaping (Bool, String) -> Void) async {
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
                catalogRequest.limit = 20  // Get more songs for variety

                do {
                    let catalogResponse = try await catalogRequest.response()
                    let count = catalogResponse.songs.count
                    print("✅ CATALOG search succeeded! Songs count: \(count)")

                    guard count > 0 else {
                        await MainActor.run {
                            completion(false, "Не нашёл '\(query)' в Apple Music")
                        }
                        return
                    }

                    // Create playlist using helper function
                    let playlistSongs = self.createPlaylist(from: catalogResponse.songs, maxSize: 10)

                    // Save playlist for track navigation
                    self.currentPlaylist = playlistSongs
                    self.currentTrackIndex = 0

                    let firstSong = playlistSongs[0]
                    let songTitle = firstSong.title
                    let artistName = firstSong.artistName
                    print("✅ Found: \(songTitle) - \(artistName)")
                    print("🎵 Creating playlist with \(playlistSongs.count) songs")

                    // Set player queue with multiple songs and play
                    let queueToSet: ApplicationMusicPlayer.Queue = ApplicationMusicPlayer.Queue(for: playlistSongs)
                    player.queue = queueToSet
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

                guard matchingSongs.count > 0 else {
                    await MainActor.run {
                        completion(false, "Не нашёл '\(query)' ни в каталоге, ни в твоей библиотеке")
                    }
                    return
                }

                // Create playlist using helper function
                let playlistSongs = self.createPlaylistFromArray(from: matchingSongs, maxSize: 10)

                // Save playlist for track navigation
                self.currentPlaylist = playlistSongs
                self.currentTrackIndex = 0

                let firstSong = playlistSongs[0]
                let songTitle = firstSong.title
                let artistName = firstSong.artistName
                print("✅ Found in library: \(songTitle) - \(artistName)")
                print("🎵 Creating playlist with \(playlistSongs.count) songs")

                // Set player queue with multiple songs and play
                let queueToSet: ApplicationMusicPlayer.Queue = ApplicationMusicPlayer.Queue(for: playlistSongs)
                player.queue = queueToSet
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
            await performSearch(query: query, completion: completion)
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
    func next(completion: ((String) -> Void)? = nil) {
        Task {
            print("⏭️ Next track button pressed")

            // Increment track index
            currentTrackIndex += 1

            // Check if we have the next song in our saved playlist
            guard currentTrackIndex < currentPlaylist.count else {
                print("⚠️ No more tracks in playlist")
                await MainActor.run {
                    completion?("Конец плейлиста")
                }
                return
            }

            let nextSong = currentPlaylist[currentTrackIndex]
            let announcement = "\(nextSong.title) — \(nextSong.artistName)"
            print("🎵 Next track: \(announcement)")

            // Use simple approach: stop and recreate queue from current position
            print("🔄 Recreating queue from position \(currentTrackIndex)")

            let remainingSongs = Array(currentPlaylist[currentTrackIndex...])
            print("📝 Remaining songs in queue: \(remainingSongs.count)")

            do {
                // Stop current playback
                player.stop()
                print("⏹️ Stopped current playback")

                // Small delay to ensure clean state
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

                // Create new queue starting from next song
                let newQueue: ApplicationMusicPlayer.Queue = ApplicationMusicPlayer.Queue(for: remainingSongs)
                player.queue = newQueue
                print("📝 New queue set with \(remainingSongs.count) songs")

                // Start playing
                try await player.play()
                print("▶️ Started playing")

                // Update current song info
                await MainActor.run {
                    self.currentSong = announcement
                }

                // Wait 1.5 seconds for the song to start playing properly
                try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds

                // Now announce the song name (this will duck the music volume)
                await MainActor.run {
                    completion?(announcement)
                }
            } catch {
                print("❌ Failed to switch track: \(error)")
                await MainActor.run {
                    completion?("Не удалось переключить")
                }
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
