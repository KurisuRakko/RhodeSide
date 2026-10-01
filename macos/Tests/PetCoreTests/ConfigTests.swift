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

    func testSavedPositionsKeepStackAndReadOldFiles() throws {
        let url = dir.appendingPathComponent("positions.json")
        try Data(#"{"pets":{"a":{"x":1,"y":2}}}"#.utf8).write(to: url) // 旧版本没有 on
        XCTAssertEqual(SavedPositions.load(from: url), SavedPositions(pets: ["a": .init(x: 1, y: 2)]))
        let p = SavedPositions(pets: ["a": .init(x: 1, y: 2), "b": .init(x: 1, y: 122, on: "a")])
        try p.save(to: url)
        XCTAssertEqual(SavedPositions.load(from: url), p)
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
    func testTeamsRoundTripAndDefaults() throws {
        let url = dir.appendingPathComponent("config.json")
        var cfg = AppConfig()
        cfg.teams = [Team(id: "cp", name: "德拉", members: [PetConfig(id: "m1", model: "德克萨斯"), PetConfig(id: "m2", model: "拉普兰德", link: "cp")])]
        cfg.pets[0].link = "cp"
        try cfg.save(to: url)
        let (back, _) = AppConfig.load(from: url)
        XCTAssertEqual(back, cfg)

        try Data(#"{"pets":[{"id":"x"}],"teams":[{"members":[{"id":"y","model":"m"}]}]}"#.utf8).write(to: url)
        let (old, result) = AppConfig.load(from: url)
        XCTAssertEqual(result, .loaded)
        XCTAssertNil(old.pets[0].link)
        XCTAssertEqual(old.teams.count, 1)
        XCTAssertEqual(old.teams[0].name, "套组")
        XCTAssertEqual(old.teams[0].members[0].model, "m")
        XCTAssertEqual(AppConfig().teams, [])
    }

    func testSummonedMembersGetFreshIDsAndLink() {
        let members = (0..<10).map { PetConfig(id: "m\($0)", model: "M\($0)", height: 999) }
        let team = Team(id: "cp", name: "多", members: members)
        let pets = team.summoned()
        XCTAssertEqual(pets.count, AppConfig.maxPets)
        XCTAssertEqual(pets.map(\.model), members.prefix(AppConfig.maxPets).map(\.model))
        XCTAssertTrue(pets.allSatisfy { $0.link == "cp" && !$0.id.hasPrefix("m") })
        XCTAssertEqual(Set(pets.map(\.id)).count, pets.count)
        XCTAssertEqual(pets[0].height, PetConfig.heightRange.upperBound)
    }

    func testLanguageDefaultsToSystem() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"pets":[]}"#.utf8))
        XCTAssertEqual(old.language, UILanguage.system)
        let bad = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"language":3}"#.utf8))
        XCTAssertEqual(bad.language, UILanguage.system)
        let en = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"language":"en"}"#.utf8))
        XCTAssertEqual(en.language, "en")
    }

    func testLanguageResolve() {
        XCTAssertEqual(UILanguage.resolve("en", preferred: ["zh-Hans-CN"]), .en)
        XCTAssertEqual(UILanguage.resolve("system", preferred: ["zh-Hans-CN", "en-US"]), .zhHans)
        XCTAssertEqual(UILanguage.resolve("system", preferred: ["zh-Hant-HK"]), .zhHant)
        XCTAssertEqual(UILanguage.resolve("system", preferred: ["zh-TW"]), .zhHant)
        XCTAssertEqual(UILanguage.resolve("system", preferred: ["en-AU", "zh-Hans"]), .en)
        XCTAssertEqual(UILanguage.resolve("klingon", preferred: ["ja-JP"]), .en)
        XCTAssertEqual(UILanguage.resolve("system", preferred: []), .zhHans)
        XCTAssertEqual(UILanguage.resolve("system", preferred: ["zh-Hans-HK"]), .zhHans)
        XCTAssertEqual(UILanguage.resolve("system", preferred: ["zh-HK"]), .zhHant)
        XCTAssertEqual(UILanguage.resolve("system", preferred: ["yue-Hant-HK"]), .zhHant)
    }
}
