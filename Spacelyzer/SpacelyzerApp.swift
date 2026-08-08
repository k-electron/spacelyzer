//
//  SpacelyzerApp.swift
//  Spacelyzer
//

import SwiftUI
import SwiftData

@main
struct SpacelyzerApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try Storage.makeContainer()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
