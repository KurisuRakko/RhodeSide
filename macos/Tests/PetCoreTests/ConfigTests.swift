import Foundation
import XCTest

@testable import PetCore

final class ConfigTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rhodeside-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileGivesDefault() {
        let (cfg, result) = AppConfig.load(from: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(result, .missing)
        XCTAssertEqual(cfg.pets.count, 1)
        XCTAssertEqual(cfg.pets[0].model, AppConfig.builtinModel)
        XCTAssertEqual(cfg.pets[0].group, "基建")
    }

    func testRoundTrip() throws {
        let url = dir.appendingPathComponent("config.json")
        var cfg = AppConfig()
        cfg.pets.append(PetConfig(id: "b", model: "别的", outfit: nil, group: "正面", height: 90, stride: 1.2))
        cfg.ignoredApps = ["Snipaste"]
        try cfg.save(to: url)
        let (back, result) = AppConfig.load(from: url)
        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(back, cfg)
    }

    func testMissingKeysUseDefaults() throws {
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"pets":[{"id":"x","model":"m"}]}"#.utf8).write(to: url)
        let (cfg, result) = AppConfig.load(from: url)
        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(cfg.hideInFullscreen, true)
        XCTAssertEqual(cfg.pets, [PetConfig(id: "x", model: "m", outfit: nil, group: nil, height: 120, stride: 1, pma: false)])
        XCTAssertEqual(cfg.ignoredApps, AppConfig.defaultIgnoredApps)
        XCTAssertEqual(cfg.auth, AuthConfig())
        XCTAssertTrue(cfg.onboarded)
        XCTAssertFalse(AppConfig().onboarded)
        XCTAssertFalse(cfg.auth.enabled)
        XCTAssertEqual(cfg.voice, VoiceConfig(enabled: true, volume: 0.7))
    }

    func testVoiceDecodesLeniently() throws {
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"voice":{"volume":3}}"#.utf8).write(to: url)
        let (cfg, _) = AppConfig.load(from: url)
        XCTAssertEqual(cfg.voice, VoiceConfig(enabled: true, volume: 1))
    }

    func testPetModesDecodeLeniently() throws {
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"pets":[{"id":"a","activity":"stay","hoverFade":true,"opacity":0.05},{"id":"b","activity":"dance"}]}"#.utf8).write(to: url)
        let (cfg, result) = AppConfig.load(from: url)
        XCTAssertEqual(result, .loaded)
        XCTAssertEqual(cfg.pets[0].activity, .stay)
        XCTAssertTrue(cfg.pets[0].hoverFade)
        XCTAssertEqual(cfg.pets[0].sanitized().opacity, PetConfig.opacityRange.lowerBound)
        XCTAssertEqual(cfg.pets[1].activity, .auto)
    }

    func testPartialAuthKeepsDefaults() throws {
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"auth":{"enabled":true}}"#.utf8).write(to: url)
        let (cfg, _) = AppConfig.load(from: url)
        XCTAssertEqual(cfg.auth, AuthConfig(enabled: true, api: AuthConfig.defaultAPI, appID: "rhodeside"))
    }

    func testBrokenFileIsBackedUp() throws {
        let url = dir.appendingPathComponent("config.json")
        try Data("{ 这不是 JSON".utf8).write(to: url)
        let (cfg, result) = AppConfig.load(from: url)
        XCTAssertEqual(cfg, AppConfig(pets: cfg.pets))  // 默认值（id 是随机的，单独放过）
        guard case .broken(let backup) = result else { return XCTFail("应该报 broken，实际 \(result)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), "{ 这不是 JSON")
    }
}
