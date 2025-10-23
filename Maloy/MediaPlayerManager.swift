//
//  MediaPlayerManager.swift
//  Maloy
//
//  Apple Music integration using MediaPlayer (local library)
//  Works WITHOUT paid Developer account
//

import Foundation
import MediaPlayer
import Combine

class MediaPlayerManager: ObservableObject {
    @Published var isAuthorized = false
    @Published var currentSong: String?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var isInitialized = false

    init() {
        // Check authorization status on init
        checkAuthorization()
        setupNotifications()
    }

    deinit {
        // Clean up notifications
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNotifications() {
        guard !isInitialized else { return }
        isInitialized = true

        // Listen for playback state changes
        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player,
            queue: .main
        ) { [weak self] _ in
            print("🎵 Playback state changed: \(self?.player.playbackState.rawValue ?? -1)")
        }

        player.beginGeneratingPlaybackNotifications()
    }

    // MARK: - Authorization

    /// Check and request Media Library authorization
    func checkAuthorization() {
        let status = MPMediaLibrary.authorizationStatus()

        switch status {
        case .authorized:
            self.isAuthorized = true
            print("✅ Media Library authorized")
        case .denied, .restricted:
            self.isAuthorized = false
            print("❌ Media Library access denied/restricted")
        case .notDetermined:
            MPMediaLibrary.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    self.isAuthorized = (newStatus == .authorized)
                    if self.isAuthorized {
                        print("✅ Media Library authorized after request")
                    } else {
                        print("❌ Media Library denied after request")
                    }
                }
            }
        @unknown default:
            self.isAuthorized = false
            print("⚠️ Unknown Media Library authorization status")
        }
    }

    // MARK: - Search and Playback

    /// Search for a song and play it
    func searchAndPlay(query: String, completion: @escaping (Bool, String) -> Void) {
        print("🎵 searchAndPlay called with query: \"\(query)\"")
        print("🎵 isAuthorized: \(isAuthorized)")

        guard isAuthorized else {
            print("❌ Media Library not authorized!")
            DispatchQueue.main.async {
                completion(false, "Нужен доступ к музыкальной библиотеке. Проверь настройки.")
            }
            return
        }

        // Run search in background to prevent blocking
        DispatchQueue.global(qos: .userInitiated).async {
            print("🔍 Searching local library: \"\(query)\"")

            do {
                // Search for songs by artist
                let artistPredicate = MPMediaPropertyPredicate(value: query,
                                                               forProperty: MPMediaItemPropertyArtist,
                                                               comparisonType: .contains)

                let artistQuery = MPMediaQuery.songs()
                artistQuery.addFilterPredicate(artistPredicate)

                if let items = artistQuery.items, !items.isEmpty {
                    print("✅ Found \(items.count) songs by artist")
                    DispatchQueue.main.async {
                        self.playItems(items, completion: completion)
                    }
                    return
                }

                // Try searching by song title if artist search failed
                print("🔍 Artist not found, trying song title...")
                let titlePredicate = MPMediaPropertyPredicate(value: query,
                                                              forProperty: MPMediaItemPropertyTitle,
                                                              comparisonType: .contains)
                let titleQuery = MPMediaQuery.songs()
                titleQuery.addFilterPredicate(titlePredicate)

                if let titleItems = titleQuery.items, !titleItems.isEmpty {
                    print("✅ Found \(titleItems.count) songs by title")
                    DispatchQueue.main.async {
                        self.playItems(titleItems, completion: completion)
                    }
                    return
                }

                // Nothing found
                print("❌ No songs found in library for: \(query)")
                DispatchQueue.main.async {
                    completion(false, "Не нашёл '\(query)' в твоей музыкальной библиотеке. Добавь эту музыку в Apple Music сначала.")
                }

            } catch {
                print("❌ Search error: \(error)")
                DispatchQueue.main.async {
                    completion(false, "Ошибка поиска музыки")
                }
            }
        }
    }

    private func playItems(_ items: [MPMediaItem], completion: @escaping (Bool, String) -> Void) {
        guard let firstItem = items.first else {
            completion(false, "Нет треков")
            return
        }

        let songTitle = firstItem.title ?? "Unknown"
        let artistName = firstItem.artist ?? "Unknown Artist"
        print("✅ Found: \(songTitle) - \(artistName)")

        do {
            // Stop current playback first
            player.stop()

            // Create collection and play
            let collection = MPMediaItemCollection(items: items)
            player.setQueue(with: collection)
            player.prepareToPlay()
            player.play()

            currentSong = "\(songTitle) - \(artistName)"
            print("🎵 Now playing: \(currentSong ?? "")")
            completion(true, "\(artistName), \(songTitle)")

        } catch {
            print("❌ Playback error: \(error)")
            completion(false, "Ошибка воспроизведения")
        }
    }

    /// Play/Resume playback
    func play(completion: @escaping (Bool, String) -> Void) {
        player.play()
        completion(true, "Продолжаю")
    }

    /// Pause playback
    func pause(completion: @escaping (Bool, String) -> Void) {
        player.pause()
        completion(true, "Пауза")
    }

    /// Skip to next track
    func next(completion: @escaping (Bool, String) -> Void) {
        player.skipToNextItem()
        if let nowPlaying = player.nowPlayingItem {
            let title = nowPlaying.title ?? "Unknown"
            let artist = nowPlaying.artist ?? "Unknown"
            completion(true, "\(artist), \(title)")
        } else {
            completion(true, "Следующий трек")
        }
    }

    /// Skip to previous track
    func previous(completion: @escaping (Bool, String) -> Void) {
        player.skipToPreviousItem()
        if let nowPlaying = player.nowPlayingItem {
            let title = nowPlaying.title ?? "Unknown"
            let artist = nowPlaying.artist ?? "Unknown"
            completion(true, "\(artist), \(title)")
        } else {
            completion(true, "Предыдущий трек")
        }
    }

    /// Stop playback completely
    func stop() {
        player.stop()
        currentSong = nil
        print("⏹️ Playback stopped")
    }
}
