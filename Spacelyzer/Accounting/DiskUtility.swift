import Foundation

nonisolated enum DiskUtilityError: Error, Equatable {
    case toolUnavailable
    case failed(status: Int32)
    case unreadableOutput
    case timedOut
}

/// Carries the tool's output back from the reading queue. Safe without a lock because the
/// semaphore that publishes it also orders the write before the read.
nonisolated private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

/// The only place in the app that invokes `diskutil`.
///
/// The constitution's platform constraints require a capability reachable only through a
/// command-line tool to be isolated behind a single interface, to treat the tool's output as
/// untrusted and changeable, and to degrade to a stated approximation rather than reporting a
/// wrong number confidently. Callers get bytes and do their own parsing so that a parser can be
/// tested against canned output without running anything.
nonisolated protocol DiskUtilityRunning: Sendable {
    func run(_ arguments: [String]) throws -> Data
}

nonisolated struct DiskUtility: DiskUtilityRunning {
    private static let toolPath = "/usr/sbin/diskutil"
    /// Generous next to the fraction of a second these calls normally take. It exists to bound a
    /// tool wedged on an unresponsive disk, not to police a slow one.
    private static let timeout: DispatchTimeInterval = .seconds(10)

    func run(_ arguments: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: Self.toolPath) else {
            throw DiskUtilityError.toolUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.toolPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DiskUtilityError.toolUnavailable
        }

        // Drained on another queue rather than inline. A plist listing every volume can exceed the
        // pipe buffer, so the read has to happen while the tool still runs, but reading inline
        // gives a wedged tool the power to block this thread forever.
        nonisolated(unsafe) let handle = output.fileHandleForReading
        let box = OutputBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = handle.readDataToEndOfFile()
            finished.signal()
        }

        if finished.wait(timeout: .now() + Self.timeout) == .timedOut {
            process.terminate()
            // Terminating closes the pipe, which ends the read. Bounded again in case it does not.
            _ = finished.wait(timeout: .now() + .seconds(2))
            throw DiskUtilityError.timedOut
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiskUtilityError.failed(status: process.terminationStatus)
        }
        return box.data
    }
}

extension DiskUtilityRunning {
    /// Runs the tool and decodes its plist output, mapping every kind of failure onto the same
    /// error so callers have one path to degrade along.
    nonisolated func plist(_ arguments: [String]) throws -> [String: Any] {
        let data = try run(arguments)
        guard
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ),
            let dictionary = parsed as? [String: Any]
        else {
            throw DiskUtilityError.unreadableOutput
        }
        return dictionary
    }
}
