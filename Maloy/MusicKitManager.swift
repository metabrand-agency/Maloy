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
                // Search for songs
                var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
                request.limit = 1

                let response = try await request.response()

                guard let song = response.songs.first else {
                    await MainActor.run {
                        completion(false, "Не нашёл песню '\(query)' в Apple Music")
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

            } catch {
                print("❌ MusicKit search error: \(error)")
                await MainActor.run {
                    completion(false, "Ошибка поиска: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Play/Resume playback
    func play(completion: @escaping (Bool, String) -> Void) {
        Task {
            do {
                try await player.play()
                await MainActor.run {
                    completion(true, "Продолжаю")
                }
            } catch {
                print("❌ Play error: \(error)")
                await MainActor.run {
                    completion(false, "Не удалось продолжить")
                }
            }
        }
    }

    /// Pause playback
    func pause(completion: @escaping (Bool, String) -> Void) {
        player.pause()
        completion(true, "Пауза")
    }

    /// Skip to next track
    func next(completion: @escaping (Bool, String) -> Void) {
        Task {
            do {
                try await player.skipToNextEntry()
                await MainActor.run {
                    completion(true, "Следующий трек")
                }
            } catch {
                print("❌ Skip next error: \(error)")
                await MainActor.run {
                    completion(false, "Не удалось переключить")
                }
            }
        }
    }

    /// Skip to previous track
    func previous(completion: @escaping (Bool, String) -> Void) {
        Task {
            do {
                try await player.skipToPreviousEntry()
                await MainActor.run {
                    completion(true, "Предыдущий трек")
                }
            } catch {
                print("❌ Skip previous error: \(error)")
                await MainActor.run {
                    completion(false, "Не удалось вернуться")
                }
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
