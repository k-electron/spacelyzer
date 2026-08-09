import Foundation

/// Something the user has asked to remove, with the size the analysis already measured for it.
///
/// The size travels with the candidate rather than being read again here. A folder's size is the
/// sum of everything beneath it, which the scan has and the guard would have to walk the disk to
/// rediscover — and a guard that touches the filesystem to answer a question is a guard that can
/// be slow at exactly the wrong moment.
nonisolated struct RemovalCandidate: Sendable, Equatable {
    let url: URL
    let size: Int64
}

/// Decides what may be removed, and says why for everything that may not (FR-055).
///
/// This is the whole of Principle II's enforcement. It lives below the interface on purpose: there
/// is no path from a view to a removal that does not come through here, so no future entry point
/// can be added that forgets to ask.
nonisolated struct RemovalGuard: Sendable {
    /// Paths that are the operating system's, at or inside which nothing may be removed.
    private let systemRoots: Set<String>
    /// Directories that must keep existing even though their contents are fair game.
    private let irremovableDirectories: Set<String>
    /// The app's own bundle and stored data.
    private let ownData: Set<String>
    private let home: String

    init(
        systemRoots: Set<String>? = nil,
        irremovableDirectories: Set<String>? = nil,
        ownData: Set<String>? = nil,
        home: String? = nil
    ) {
        self.systemRoots = systemRoots ?? Self.defaultSystemRoots
        self.home = home ?? NSHomeDirectory()
        self.irremovableDirectories =
            irremovableDirectories ?? Self.defaultIrremovableDirectories(home: self.home)
        self.ownData = ownData ?? Self.defaultOwnData(home: self.home)
    }

    func evaluate(_ candidates: [RemovalCandidate]) -> RemovalPlan {
        var permitted: [PlannedRemoval] = []
        var refused: [RefusedRemoval] = []

        for candidate in candidates {
            let url = candidate.url.standardizedFileURL
            if let refusal = refusal(for: url) {
                refused.append(RefusedRemoval(url: url, refusal: refusal))
            } else {
                permitted.append(PlannedRemoval(url: url, size: candidate.size))
            }
        }

        // Refusing some never blocks the rest (FR-055). The permitted list stands on its own.
        return RemovalPlan(
            permitted: permitted,
            refused: refused,
            trashAvailable: Self.trashIsAvailable(for: permitted.map(\.url))
        )
    }

    /// Nil means it may be removed. Everything else names the reason it may not.
    func refusal(for url: URL) -> RemovalRefusal? {
        let path = url.standardizedFileURL.path

        // Protection is decided before existence. A protected path is protected whether or not
        // anything is there at this instant, and answering "it is already gone" about the system
        // folder someone just asked to delete would be both wrong and reassuring.
        if path == "/" { return .volumeRoot }
        if isVolumeRoot(path) { return .volumeRoot }
        if path == home { return .homeDirectory }
        if path == "/Users" || path == "/Users/Shared" { return .homeDirectory }

        // Before the system check, so `~/Library` reads as a folder the system expects rather than
        // as something the operating system owns; the distinction changes what the user does next.
        if irremovableDirectories.contains(path) { return .standardHomeFolder }

        if ownData.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .ownApplicationData
        }
        if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .systemLocation
        }
        if isInsideTrash(path) { return .insideTrash }

        // Attributes rather than `fileExists`, which follows a symbolic link and would report a
        // dangling one as already gone when removing the link itself is perfectly reasonable.
        guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else {
            return .noLongerThere
        }

        return nil
    }

    private func isVolumeRoot(_ path: String) -> Bool {
        // `/Volumes/Thing` is a mount point; `/Volumes/Thing/folder` is not.
        guard path.hasPrefix("/Volumes/") else { return false }
        return path.dropFirst("/Volumes/".count).contains("/") == false
    }

    private func isInsideTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.hasSuffix("/.Trash") || path.contains("/.Trashes/")
    }

    /// Whether every one of these can go to a Trash.
    ///
    /// All of them rather than any: the user is about to be told that removal is recoverable, and
    /// that has to be true of the whole selection, not most of it. Some volumes have no Trash at
    /// all, and a network share is the common case.
    static func trashIsAvailable(for urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { url in
            (try? FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false
            )) != nil
        }
    }

    // MARK: - What is protected

    /// Where the operating system lives. Removing anything at or inside these damages the install,
    /// and most of it is refused by the system anyway — but being told why beforehand is better
    /// than watching a batch fail item by item.
    static let defaultSystemRoots: Set<String> = [
        "/System",
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/usr/share",
        "/private/etc",
        "/private/var/db",
        "/private/var/vm",
        "/cores",
        "/dev",
        "/Network",
        "/opt",
    ]

    /// Folders the system expects to find. Their contents are ordinary — caches and downloads are
    /// exactly what someone reclaiming space is after — but the folders themselves stay.
    static func defaultIrremovableDirectories(home: String) -> Set<String> {
        var directories: Set<String> = ["/Applications", "/Library", "/Users", "/Volumes", "/tmp"]
        for name in [
            "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
            "Public", "Applications",
        ] {
            directories.insert(home + "/" + name)
        }
        return directories
    }

    /// The app's own bundle and everything it has written.
    ///
    /// Not vanity: the removal history lives in here, and a batch that took it out would delete
    /// the record of what it had just done along with the means of undoing it.
    static func defaultOwnData(home: String) -> Set<String> {
        var paths: Set<String> = [Bundle.main.bundleURL.standardizedFileURL.path]

        let identifier = Bundle.main.bundleIdentifier
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String

        for token in [identifier, name].compactMap({ $0 }) {
            paths.insert("\(home)/Library/Application Support/\(token)")
            paths.insert("\(home)/Library/Containers/\(token)")
            paths.insert("\(home)/Library/Caches/\(token)")
            paths.insert("\(home)/Library/Preferences/\(token).plist")
            paths.insert("\(home)/Library/Saved Application State/\(token).savedState")
        }
        return paths
    }
}
