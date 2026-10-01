import CoreGraphics
import XCTest

@testable import PetCore

final class AttentionTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
    var ground: Platform { Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0) }
    var world: World { World(platforms: [ground], screens: [screen]) }
    let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")

    /// 站在地面上、待机很久不会自己做决定的小人（dice 0.99 → 继续待机）
    func standing(at x: Double, roles: Roles? = nil) -> Brain {
        let b = Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles ?? self.roles, interactDuration: 1), foot: CGPoint(x: x, y: 70), random: { 0.99 })
        b.step(dt: 1.0 / 60, world: world)
        XCTAssertEqual(b.behavior, .idle)
        return b
    }

    func input(idle: Double?, mouse: CGPoint? = nil, hour: Double = 12, watch: Bool = true, rest: Bool = true) -> Attention.Input {
        Attention.Input(idle: idle, mouse: mouse, hour: hour, watchMouse: watch, restWhenIdle: rest)
    }

    func testRestLevelsFollowIdleTime() {
        let a = Attention(), b = standing(at: 500)
        let m = [Attention.Member(id: "a", brain: b)]
        let t = Tuning()
        a.step(dt: 0.1, input: input(idle: t.restSit - 1), members: m, tuning: t)
        XCTAssertEqual(b.behavior, .idle)
        a.step(dt: 0.1, input: input(idle: t.restSit), members: m, tuning: t)
        XCTAssertEqual(a.level, .resting)
        XCTAssertEqual(b.behavior, .sit)
        a.step(dt: 0.1, input: input(idle: t.restSleep), members: m, tuning: t)
        XCTAssertEqual(b.behavior, .sleep)
        // 坐 / 睡不会因为计时到了就自己起来
        for _ in 0..<600 { b.step(dt: 0.1, world: world) }
        XCTAssertEqual(b.behavior, .sleep)
    }

    func testNilIdleOrSwitchOffKeepsAwake() {
        let a = Attention(), b = standing(at: 500)
        let m = [Attention.Member(id: "a", brain: b)]
        a.step(dt: 0.1, input: input(idle: nil), members: m, tuning: Tuning())
        XCTAssertEqual(a.level, .awake)
        a.step(dt: 0.1, input: input(idle: 10_000, rest: false), members: m, tuning: Tuning())
        XCTAssertEqual(a.level, .awake)
        XCTAssertEqual(b.behavior, .idle)
    }

    func testWakingUpGreetsOnlyTheNearest() {
        let a = Attention(), near = standing(at: 300), far = standing(at: 1000)
        let m = [Attention.Member(id: "far", brain: far), Attention.Member(id: "near", brain: near)]
        a.step(dt: 0.1, input: input(idle: 10_000), members: m, tuning: Tuning())
        XCTAssertEqual(near.behavior, .sleep)
        let g = a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 350, y: 130)), members: m, tuning: Tuning())
        XCTAssertEqual(g, "near")
        XCTAssertEqual(near.behavior, .interact)
        XCTAssertEqual(far.behavior, .idle)
        // 只是坐着醒来不打招呼
        a.step(dt: 0.1, input: input(idle: Tuning().restSit), members: m, tuning: Tuning())
        XCTAssertNil(a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 350, y: 130)), members: m, tuning: Tuning()))
    }

    func testLooksAtMouseWithDeadZoneAndCooldown() {
        let a = Attention(), b = standing(at: 500)
        let m = [Attention.Member(id: "a", brain: b)]
        XCTAssertEqual(b.dir, 1)
        // 在身体中线附近晃：不转
        a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 495, y: 130)), members: m, tuning: Tuning())
        XCTAssertEqual(b.dir, 1)
        a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 400, y: 130)), members: m, tuning: Tuning())
        XCTAssertEqual(b.dir, -1)
        // 冷却期间不转回去
        a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 600, y: 130)), members: m, tuning: Tuning())
        XCTAssertEqual(b.dir, -1)
        for _ in 0..<12 { a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 600, y: 130)), members: m, tuning: Tuning()) }
        XCTAssertEqual(b.dir, 1)
    }

    func testIgnoresFarMouseNilMouseOrSwitchOff() {
        let a = Attention(), b = standing(at: 500)
        let m = [Attention.Member(id: "a", brain: b)]
        a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 100, y: 130)), members: m, tuning: Tuning())
        XCTAssertEqual(b.dir, 1, "比 2.5 倍身高还远")
        a.step(dt: 0.1, input: input(idle: 0, mouse: nil), members: m, tuning: Tuning())
        a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 400, y: 130), watch: false), members: m, tuning: Tuning())
        XCTAssertEqual(b.dir, 1)
    }

    func testGreetSkipsManuallySleepingPet() {
        let a = Attention(), manual = standing(at: 300), other = standing(at: 1000)
        manual.setActivity(.stay)
        XCTAssertTrue(manual.perform(.sleep))
        let m = [Attention.Member(id: "manual", brain: manual), Attention.Member(id: "other", brain: other)]
        a.step(dt: 0.1, input: input(idle: 10_000), members: m, tuning: Tuning())
        XCTAssertEqual(a.step(dt: 0.1, input: input(idle: 0, mouse: CGPoint(x: 300, y: 130)), members: m, tuning: Tuning()), "other")
        XCTAssertEqual(manual.behavior, .sleep)
    }

    func testSwitchingOffWhileAsleepDoesNotGreetOrMakeNight() {
        let a = Attention(), b = standing(at: 500)
        let m = [Attention.Member(id: "a", brain: b)]
        a.step(dt: 0.1, input: input(idle: 10_000, hour: 3), members: m, tuning: Tuning())
        XCTAssertTrue(b.night)
        XCTAssertNil(a.step(dt: 0.1, input: input(idle: 10_000, hour: 3, rest: false), members: m, tuning: Tuning()))
        XCTAssertEqual(b.behavior, .idle)
        XCTAssertFalse(b.night, "关掉作息也不深夜犯困")
    }

    func testVideoKeepsThemAwakeEnoughToOnlySit() {
        let a = Attention(), b = standing(at: 500)
        let m = [Attention.Member(id: "a", brain: b)]
        a.step(dt: 0.1, input: Attention.Input(idle: 10_000, mouse: nil, screenKeptAwake: true, hour: 12), members: m, tuning: Tuning())
        XCTAssertEqual(a.level, .resting)
        XCTAssertEqual(b.behavior, .sit)
        a.step(dt: 0.1, input: Attention.Input(idle: 10_000, mouse: nil, screenKeptAwake: false, hour: 12), members: m, tuning: Tuning())
        XCTAssertEqual(a.level, .asleep)
        XCTAssertEqual(b.behavior, .sleep)
        // 睡着以后开始放视频：降回坐着那档但接着睡，回来照样打招呼
        a.step(dt: 0.1, input: Attention.Input(idle: 10_000, mouse: nil, screenKeptAwake: true, hour: 12), members: m, tuning: Tuning())
        XCTAssertEqual(b.behavior, .sleep)
        XCTAssertEqual(a.step(dt: 0.1, input: Attention.Input(idle: 0, mouse: CGPoint(x: 520, y: 130), hour: 12), members: m, tuning: Tuning()), "a")
        // 读不到当作没在放
        let c = Attention()
        c.step(dt: 0.1, input: Attention.Input(idle: 10_000, mouse: nil, screenKeptAwake: nil, hour: 12), members: m, tuning: Tuning())
        XCTAssertEqual(c.level, .asleep)
    }

    func testDoesNotTurnWhileWalking() {
        let b = standing(at: 500)
        XCTAssertTrue(b.go(to: CGPoint(x: 1000, y: 70), world: world))
        XCTAssertFalse(b.glance(towardX: 100))
        XCTAssertEqual(b.behavior, .walk)
        XCTAssertEqual(b.dir, 1)
    }

    func testBattleFormDoesNotRest() {
        let b = standing(at: 500)
        b.setBattle(true)
        b.setRest(.asleep)
        XCTAssertEqual(b.behavior, .idle)
    }

    func testNightHoursWrapMidnight() {
        var t = Tuning()
        XCTAssertTrue(t.isNight(hour: 3))
        XCTAssertFalse(t.isNight(hour: 6))
        t.nightHours = [23, 6]
        XCTAssertTrue(t.isNight(hour: 23.5))
        XCTAssertTrue(t.isNight(hour: 1))
        XCTAssertFalse(t.isNight(hour: 12))
    }
}
