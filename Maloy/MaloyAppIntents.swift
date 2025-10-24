//
//  MaloyAppIntents.swift
//  Maloy
//
//  App Intents for Siri, Shortcuts, and Back Tap support
//  Allows users to trigger Малой via voice, shortcuts, or accessibility gestures
//

import Foundation
import AppIntents

// MARK: - Open Малой Intent

/// Opens Малой app and starts listening
@available(iOS 16.0, *)
struct OpenMaloyIntent: AppIntent {
    static var title: LocalizedStringResource = "Открыть Малого"
    static var description: IntentDescription = "Запускает Малого и начинает слушать"

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Post notification to trigger interrupt()
        NotificationCenter.default.post(name: .maloyInterrupt, object: nil)

        return .result()
    }
}

// MARK: - Stop Music and Listen Intent

/// Stops music and starts listening for voice commands
@available(iOS 16.0, *)
struct StopMusicAndListenIntent: AppIntent {
    static var title: LocalizedStringResource = "Стоп / Слушать"
    static var description: IntentDescription = "Останавливает музыку и начинает слушать команды"

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Post notification to trigger interrupt()
        NotificationCenter.default.post(name: .maloyInterrupt, object: nil)

        return .result()
    }
}

// MARK: - App Shortcuts

/// Defines the shortcuts that appear in Settings and can be assigned to Back Tap
@available(iOS 16.0, *)
struct MaloyAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMaloyIntent(),
            phrases: [
                "Открой \(.applicationName)",
                "Запусти \(.applicationName)",
                "Включи \(.applicationName)"
            ],
            shortTitle: "Открыть Малого",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: StopMusicAndListenIntent(),
            phrases: [
                "Стоп в \(.applicationName)",
                "Слушай в \(.applicationName)"
            ],
            shortTitle: "Стоп / Слушать",
            systemImageName: "stop.circle.fill"
        )
    }
}

// MARK: - Notification Name Extension

extension Notification.Name {
    static let maloyInterrupt = Notification.Name("maloyInterrupt")
}
