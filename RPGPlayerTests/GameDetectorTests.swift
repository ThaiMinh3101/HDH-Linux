import XCTest
@testable import RPGPlayer
import Foundation

/// Unit test cho GameDetector — không cần thiết bị thật, chạy được trên Simulator.
final class GameDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTemp(structure: [String]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        for path in structure {
            let url = tmp.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        return tmp
    }

    // MARK: - RGSS Archive detection

    func testDetectRGSSXP_byArchive() throws {
        let root = try makeTemp(structure: ["Game.rgssad", "Game.exe", "Game.ini"])
        XCTAssertEqual(GameDetector.detect(in: root), .rgssXP)
    }

    func testDetectRGSSVX_byArchive() throws {
        let root = try makeTemp(structure: ["Game.rgss2a", "Game.exe"])
        XCTAssertEqual(GameDetector.detect(in: root), .rgssVX)
    }

    func testDetectRGSSVXAce_byArchive() throws {
        let root = try makeTemp(structure: ["Game.rgss3a", "Game.exe"])
        XCTAssertEqual(GameDetector.detect(in: root), .rgssVXAce)
    }

    // MARK: - RGSS Data folder detection

    func testDetectRGSSXP_byData() throws {
        let root = try makeTemp(structure: ["Data/Actors.rxdata", "Game.exe"])
        XCTAssertEqual(GameDetector.detect(in: root), .rgssXP)
    }

    func testDetectRGSSVX_byData() throws {
        let root = try makeTemp(structure: ["Data/Actors.rvdata"])
        XCTAssertEqual(GameDetector.detect(in: root), .rgssVX)
    }

    func testDetectRGSSVXAce_byData() throws {
        let root = try makeTemp(structure: ["Data/Actors.rvdata2"])
        XCTAssertEqual(GameDetector.detect(in: root), .rgssVXAce)
    }

    // MARK: - MV/MZ detection

    func testDetectMZ() throws {
        let root = try makeTemp(structure: [
            "www/index.html",
            "www/js/rmmz_core.js",
            "www/js/rmmz_managers.js"
        ])
        XCTAssertEqual(GameDetector.detect(in: root), .mz)
    }

    func testDetectMV() throws {
        let root = try makeTemp(structure: [
            "www/index.html",
            "www/js/rpg_core.js"
        ])
        XCTAssertEqual(GameDetector.detect(in: root), .mv)
    }

    // MARK: - Unknown

    func testDetectUnknown_emptyFolder() throws {
        let root = try makeTemp(structure: [])
        XCTAssertEqual(GameDetector.detect(in: root), .unknown)
    }

    func testDetectUnknown_randomFiles() throws {
        let root = try makeTemp(structure: ["README.txt", "image.png"])
        XCTAssertEqual(GameDetector.detect(in: root), .unknown)
    }

    // MARK: - Nested zip (1 subfolder layer)

    func testDetectMZ_nestedInSubfolder() throws {
        let root = try makeTemp(structure: [
            "MyGame/www/index.html",
            "MyGame/www/js/rmmz_core.js"
        ])
        XCTAssertEqual(GameDetector.detect(in: root), .mz)
    }

    func testDetectXP_nestedInSubfolder() throws {
        let root = try makeTemp(structure: [
            "MyGame/Game.rgssad",
            "MyGame/Game.ini"
        ])
        XCTAssertEqual(GameDetector.detect(in: root), .rgssXP)
    }

    // MARK: - Name detection

    func testDetectName_fromGameIni() throws {
        let root = try makeTemp(structure: ["Game.rgssad"])
        let iniContent = "[Game]\nTitle=Sword of Dawn\nRTP=\n"
        try iniContent.write(
            to: root.appendingPathComponent("Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectGameName(in: root), "Sword of Dawn")
    }

    func testDetectName_fromPackageJson() throws {
        let root = try makeTemp(structure: ["www/js/rmmz_core.js"])
        let json = """
        {"name":"forest-chronicles","version":"1.0.0","title":"Forest Chronicles MZ"}
        """
        try json.write(
            to: root.appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectGameName(in: root), "Forest Chronicles MZ")
    }
}
