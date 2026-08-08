import Foundation

/// Delay-then-show activity reporting, per Principle III and FR-069.
///
/// Work that finishes quickly shows nothing at all. An indicator that appears and vanishes on
/// every keystroke tells the user less than no indicator, which is why the reveal is delayed
/// rather than immediate.
@MainActor
@Observable
final class ActivityIndicator {
    private(set) var isVisible = false
    private(set) var message: String?

    private let delay: Duration
    private var revealTask: Task<Void, Never>?
    private var depth = 0

    init(delay: Duration = .milliseconds(150)) {
        self.delay = delay
    }

    func begin(_ message: String? = nil) {
        depth += 1
        guard revealTask == nil, !isVisible else { return }
        revealTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.depth > 0 else { return }
            self.isVisible = true
            self.message = message
        }
    }

    func end() {
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        revealTask?.cancel()
        revealTask = nil
        isVisible = false
        message = nil
    }

    /// Scopes an operation so the indicator is always balanced, including on throw.
    func during<T>(_ message: String? = nil, _ work: () async throws -> T) async rethrows -> T {
        begin(message)
        defer { end() }
        return try await work()
    }
}
