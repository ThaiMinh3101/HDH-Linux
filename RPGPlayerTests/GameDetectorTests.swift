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

    // MARK: - M8: RTP detection

    /// Game RGSS có rtp= non-empty nhưng chưa merge RTP → .required
    func testDetectRTP_required_whenRTPDeclaredButMissing() throws {
        let root = try makeTemp(structure: ["Game.rgss3a", "Game.exe"])
        let iniContent = "[Game]\nTitle=Black Souls II\nRTP=RPGVXAce\n"
        try iniContent.write(
            to: root.appendingPathComponent("Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectRTP(in: root), .required)
    }

    /// Game MV/MZ không có Game.ini → .none
    func testDetectRTP_none_forMV() throws {
        let root = try makeTemp(structure: [
            "www/index.html",
            "www/js/rpg_core.js"
        ])
        XCTAssertEqual(GameDetector.detectRTP(in: root), .none)
    }

    /// Game MZ không có Game.ini → .none
    func testDetectRTP_none_forMZ() throws {
        let root = try makeTemp(structure: [
            "www/index.html",
            "www/js/rmmz_core.js"
        ])
        XCTAssertEqual(GameDetector.detectRTP(in: root), .none)
    }

    /// Game RGSS có rtp= nhưng giá trị rỗng → .none
    func testDetectRTP_none_whenRTPEmpty() throws {
        let root = try makeTemp(structure: ["Game.rgss3a"])
        let iniContent = "[Game]\nTitle=Test\nRTP=\n"
        try iniContent.write(
            to: root.appendingPathComponent("Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectRTP(in: root), .none)
    }

    /// Game RGSS không có dòng rtp= trong Game.ini → .none
    func testDetectRTP_none_whenNoRTPLine() throws {
        let root = try makeTemp(structure: ["Game.rgss3a"])
        let iniContent = "[Game]\nTitle=Test\n"
        try iniContent.write(
            to: root.appendingPathComponent("Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectRTP(in: root), .none)
    }

    /// Game RGSS đã merge đủ 3 thư mục RTP → .satisfied
    func testDetectRTP_satisfied_whenAllDirsPresent() throws {
        let root = try makeTemp(structure: [
            "Game.rgss3a",
            "Audio/",
            "Fonts/",
            "Graphics/"
        ])
        let iniContent = "[Game]\nTitle=Test\nRTP=RPGVXAce\n"
        try iniContent.write(
            to: root.appendingPathComponent("Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectRTP(in: root), .satisfied)
    }

    /// Game RGSS thiếu 1 trong 3 thư mục → .required
    func testDetectRTP_required_whenOneDirMissing() throws {
        let root = try makeTemp(structure: [
            "Game.rgss3a",
            "Audio/",
            "Graphics/"
        ])
        let iniContent = "[Game]\nTitle=Test\nRTP=RPGVXAce\n"
        try iniContent.write(
            to: root.appendingPathComponent("Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectRTP(in: root), .required)
    }

    /// rtp= case-insensitive (RTP= vs rtp=)
    func testDetectRTP_caseInsensitiveKey() throws {
        let root = try makeTemp(structure: ["Game.rgss3a"])
        let iniContent = "[Game]\nTitle=Test\nRTP=RPGVXAce\n"
        try iniContent.write(
            to: root.appendingPathComponent("Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectRTP(in: root), .required)
    }

    /// Game RGSS lồng trong subfolder → resolveGameRoot descend rồi detect
    func testDetectRTP_nestedInSubfolder() throws {
        let root = try makeTemp(structure: [
            "MyGame/Game.rgss3a",
            "MyGame/Audio/",
            "MyGame/Fonts/",
            "MyGame/Graphics/"
        ])
        let iniContent = "[Game]\nTitle=Test\nRTP=RPGVXAce\n"
        try iniContent.write(
            to: root.appendingPathComponent("MyGame/Game.ini"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GameDetector.detectRTP(in: root), .satisfied)
    }

    // MARK: - M8: GameEntry backward-compat decode

    /// library.json cũ (không có field rtpRequirement) phải decode không lỗi, default .none
    func testGameEntryDecode_backwardCompat_noRTPField() throws {
        let json = """
        {
            "id": "3F2A1C00-0000-0000-0000-000000000001",
            "name": "Old Game",
            "engine": "rgssVXAce",
            "importDate": "2026-01-01T00:00:00Z",
            "relativeSandboxPath": "Games/ABC/",
            "sizeBytes": 1234
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(GameEntry.self, from: data)
        XCTAssertEqual(entry.rtpRequirement, .none)
    }

    /// library.json mới có field rtpRequirement → decode đúng giá trị
    func testGameEntryDecode_withRTPField() throws {
        let json = """
        {
            "id": "3F2A1C00-0000-0000-0000-000000000002",
            "name": "New Game",
            "engine": "rgssVXAce",
            "importDate": "2026-01-01T00:00:00Z",
            "relativeSandboxPath": "Games/DEF/",
            "sizeBytes": 5678,
            "rtpRequirement": "required"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(GameEntry.self, from: data)
        XCTAssertEqual(entry.rtpRequirement, .required)
    }
}
