import XCTest
@testable import RPGPlayer

// MARK: - RPGGameSchemeHandlerTests
// Tests for RPGGameSchemeHandler covering:
//   - MIME type detection
//   - WWW root resolution (flat, nested, fallback)
// No Xcode / Simulator required — pure logic tests.

final class RPGGameSchemeHandlerTests: XCTestCase {

    // MARK: - MIME Type Tests

    func testMimeTypeHTML()   { XCTAssertEqual(mime("index.html"),   "text/html; charset=utf-8") }
    func testMimeTypeJS()     { XCTAssertEqual(mime("rpg_core.js"),  "application/javascript") }
    func testMimeTypeJSON()   { XCTAssertEqual(mime("data.json"),    "application/json") }
    func testMimeTypePNG()    { XCTAssertEqual(mime("icon.png"),     "image/png") }
    func testMimeTypeJPEG()   { XCTAssertEqual(mime("bg.jpg"),       "image/jpeg") }
    func testMimeTypeOGG()    { XCTAssertEqual(mime("bgm.ogg"),      "audio/ogg") }
    func testMimeTypeM4A()    { XCTAssertEqual(mime("se.m4a"),       "audio/mp4") }
    func testMimeTypeWEBP()   { XCTAssertEqual(mime("tile.webp"),    "image/webp") }
    func testMimeTypeWOFF2()  { XCTAssertEqual(mime("font.woff2"),   "font/woff2") }
    func testMimeTypeRPGMVP() { XCTAssertEqual(mime("img.rpgmvp"),   "application/octet-stream") }
    func testMimeTypeRPGMVO() { XCTAssertEqual(mime("aud.rpgmvo"),   "application/octet-stream") }
    func testMimeTypeUnknown(){ XCTAssertEqual(mime("data.xyz"),     "application/octet-stream") }

    private func mime(_ name: String) -> String {
        RPGGameSchemeHandler.mimeType(for: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    // MARK: - WWW Root Resolution Tests

    func testResolvesWWWAtRoot() throws {
        // Layout: <sandbox>/www/index.html
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try createFile(at: tmp.appendingPathComponent("www/index.html"))

        let resolved = RPGGameSchemeHandler.resolveWWWRoot(in: tmp)
        XCTAssertEqual(resolved.lastPathComponent, "www")
    }

    func testResolvesWWWNested() throws {
        // Layout: <sandbox>/GameName/www/index.html  (zip had a sub-folder)
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try createFile(at: tmp.appendingPathComponent("GameName/www/index.html"))

        let resolved = RPGGameSchemeHandler.resolveWWWRoot(in: tmp)
        XCTAssertEqual(resolved.lastPathComponent, "www")
    }

    func testResolvesIndexAtNestedRoot() throws {
        // Layout: <sandbox>/GameName/index.html  (MV without www/)
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try createFile(at: tmp.appendingPathComponent("GameName/index.html"))

        let resolved = RPGGameSchemeHandler.resolveWWWRoot(in: tmp)
        XCTAssertEqual(resolved.lastPathComponent, "GameName")
    }

    func testFallsBackToSandboxRoot() throws {
        // Layout: <sandbox>/index.html  (unusual, no www)
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        // No www or subfolder — falls back to sandbox root
        let resolved = RPGGameSchemeHandler.resolveWWWRoot(in: tmp)
        XCTAssertEqual(resolved.path, tmp.path)
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
