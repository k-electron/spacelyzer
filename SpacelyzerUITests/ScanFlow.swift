import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Driving the app as far as a finished analysis, which several tests need before they have
/// anything to look at.
enum ScanFlow {

    @MainActor
    static func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // macOS restores window state between launches, and a restored "no windows" state leaves
        // a UI test with nothing to inspect.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    /// Launches and analyses one folder, returning once `marker` is on screen.
    ///
    /// The marker defaults to the folder itself, which the location header shows. A caller whose
    /// path the open panel may resolve differently — anything under a symlinked temporary
    /// directory — should name a row it expects to see instead.
    @MainActor
    static func launchAndScan(
        _ folder: String,
        expecting marker: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = launch()

        XCTAssertTrue(
            app.buttons["Choose Folder…"].waitForExistence(timeout: 20), file: file, line: line
        )
        app.buttons["Choose Folder…"].click()

        // Driven by keyboard because the open panel does not expose its buttons to the test
        // runner. These waits are on the clock; the one that matters is the wait for the outline
        // below, which is on the result actually arriving.
        Thread.sleep(forTimeInterval: 2)
        app.typeKey("g", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        app.typeText(folder)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        app.typeKey(.return, modifierFlags: [])

        let expected = marker ?? folder
        let rootRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", expected)
        ).firstMatch
        XCTAssertTrue(
            rootRow.waitForExistence(timeout: 60), "the scan should produce an outline",
            file: file, line: line
        )

        return app
    }

    /// A folder holding one very large image, for the cases that need a preview big enough to
    /// throw its weight around.
    ///
    /// Solid colour, so four thousand by three thousand pixels compresses to almost nothing on
    /// disk while still reporting a large size to whatever tries to display it.
    static func makeLargeImageFixture(named name: String) throws -> String {
        // The caches directory rather than the temporary one: the test runner can write here, and
        // the path holds no symlinks for the open panel to resolve into something the assertions
        // would no longer recognise.
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = caches.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try Data("small".utf8).write(to: folder.appending(path: "notes.txt"))

        // One unbroken line. Text previews want to be as wide as their longest line, which is a
        // different way for content to reach out and resize the thing displaying it.
        let line = String(repeating: "wide-", count: 2_000)
        try Data(line.utf8).write(to: folder.appending(path: "verywideline.txt"))

        let url = folder.appending(path: "enormous.png")
        let width = 4000
        let height = 3000
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard
            let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

        return folder.path
    }

    static func removeFixture(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
