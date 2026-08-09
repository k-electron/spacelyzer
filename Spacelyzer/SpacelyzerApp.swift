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
        // Fixed rather than derived from the content's ideal size, because the split inside starts
        // at a third of it and a third of an unknown number is not a layout anyone chose.
        .defaultSize(MainSplitView.defaultWindowSize)
    }
}
