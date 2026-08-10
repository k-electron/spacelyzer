//
//  ContentView.swift
//  Spacelyzer
//

import SwiftUI

struct ContentView: View {
    /// Passed down rather than read here, because the window is where the user can see it.
    var storageWarning: String?

    var body: some View {
        MainSplitView(storageWarning: storageWarning)
    }
}

#Preview {
    ContentView()
}
