//
//  SpacelyzerApp.swift
//  Spacelyzer
//

import SwiftUI
import SwiftData

@main
struct SpacelyzerApp: App {
    private let container: ModelContainer
    /// Non-nil when the durable store would not open and this session is running on memory.
    private let storageWarning: String?

    init() {
        (container, storageWarning) = Storage.open()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(storageWarning: storageWarning)
        }
        .modelContainer(container)
        // Fixed rather than derived from the content's ideal size, because the split inside starts
        // at a third of it and a third of an unknown number is not a layout anyone chose.
        .defaultSize(MainSplitView.defaultWindowSize)
    }
}
