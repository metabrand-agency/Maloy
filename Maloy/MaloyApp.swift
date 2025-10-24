//
//  MaloyApp.swift
//  Maloy
//
//  Created by dmitry.komissarov on 19/10/2025.
//

import SwiftUI

@main
struct MaloyApp: App {
    @StateObject private var musicKitManager = MusicKitManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(musicKitManager)
        }
    }
}
