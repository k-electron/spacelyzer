import CoreGraphics
import Foundation
import Testing
@testable import Spacelyzer

private func node(
    _ name: String,
    _ size: Int64,
    children: [ScannedItem] = []
) -> ScannedItem {
    ScannedItem(
        name: name,
        kind: children.isEmpty ? .file : .directory,
        category: .other,
        ownSize: children.isEmpty ? size : 0,
        cumulativeSize: size,
        itemCount: max(1, children.count),
        created: .distantPast,
        modified: .distantPast,
        accessed: .distantPast,
        countedElsewhere: false,
        unreadable: false,
        hasUnexpandedContents: false,
        children: children
    )
}

private let tree = node("root", 1_000, children: [
    node("folder", 600, children: [node("inner.bin", 600)]),
    node("loose.bin", 400),
])

@MainActor
@Suite("Treemap coordinator")
struct LayoutCoordinatorTests {

    /// Budgeted in polls rather than elapsed time, for the same reason the activity indicator test
    /// is: other suites in this target hold the main actor for seconds at a stretch.
    private func waitForLayout(
        _ coordinator: LayoutCoordinator,
        width: CGFloat,
        polls: Int = 300
    ) async throws {
        for _ in 0..<polls {
            if coordinator.layout.bounds.width == width { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A layout arrives once the canvas reports its size")
    func layoutFollowsFirstSize() async throws {
        let coordinator = LayoutCoordinator()
        coordinator.present(root: tree, path: "/root")

        // Presenting before the canvas exists cannot lay anything out, because there is no
        // rectangle to lay out into yet.
        #expect(coordinator.layout.isEmpty)

        coordinator.resize(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        try await waitForLayout(coordinator, width: 400)

        #expect(coordinator.layout.bounds.width == 400)
        #expect(!coordinator.layout.isEmpty)
    }

    @Test("Resizing lays the treemap out again at the new size")
    func resizeRelayouts() async throws {
        let coordinator = LayoutCoordinator()
        coordinator.present(root: tree, path: "/root")
        coordinator.resize(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        try await waitForLayout(coordinator, width: 400)

        coordinator.resize(to: CGRect(x: 0, y: 0, width: 900, height: 300))
        try await waitForLayout(coordinator, width: 900)

        #expect(coordinator.layout.bounds.width == 900)
        // Rectangles have to be laid out for the new canvas, not stretched from the old one.
        for laid in coordinator.layout.nodes {
            #expect(laid.rect.maxX <= 900.5)
        }
    }

    @Test("A burst of resizes settles on the last one")
    func rapidResizesSettleOnTheFinalSize() async throws {
        let coordinator = LayoutCoordinator()
        coordinator.present(root: tree, path: "/root")

        // What dragging a window edge actually produces.
        for width in stride(from: 300, through: 800, by: 25) {
            coordinator.resize(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: 400))
        }
        try await waitForLayout(coordinator, width: 800)

        #expect(coordinator.layout.bounds.width == 800)
    }

    @Test("The working indicator clears once a burst of layouts settles")
    func indicatorDoesNotLeak() async throws {
        let coordinator = LayoutCoordinator()
        coordinator.present(root: tree, path: "/root")

        for width in stride(from: 300, through: 600, by: 25) {
            coordinator.resize(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: 400))
        }
        try await waitForLayout(coordinator, width: 600)

        // Every superseded layout has to release its claim on the indicator. If cancelled ones
        // leak, the canvas stays dimmed forever and the user is told work is happening when the
        // app is idle.
        for _ in 0..<200 where coordinator.activity.isVisible {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.activity.isVisible == false)
    }

    @Test("Drilling moves the displayed root and navigating out restores it")
    func drillingAndReturning() async throws {
        let coordinator = LayoutCoordinator()
        coordinator.present(root: tree, path: "/root")
        coordinator.resize(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        try await waitForLayout(coordinator, width: 400)

        let folder = try #require(coordinator.layout.nodes.first { $0.name == "folder" })
        #expect(coordinator.canDrill(into: folder))

        coordinator.drill(into: folder)
        #expect(coordinator.trail == ["root", "folder"])
        #expect(coordinator.canNavigateOut)

        coordinator.navigateOut()
        #expect(coordinator.trail == ["root"])
        #expect(coordinator.canNavigateOut == false)
    }

    @Test("A file and a remainder are not places to go")
    func drillingIsRefusedWhereThereIsNothingBelow() async throws {
        let coordinator = LayoutCoordinator()
        coordinator.present(root: tree, path: "/root")
        coordinator.resize(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        try await waitForLayout(coordinator, width: 400)

        let file = try #require(coordinator.layout.nodes.first { $0.name == "loose.bin" })
        #expect(coordinator.canDrill(into: file) == false)

        coordinator.drill(into: file)
        #expect(coordinator.trail == ["root"])
    }
}
