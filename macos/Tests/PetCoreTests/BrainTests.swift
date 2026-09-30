import CoreGraphics
import XCTest

@testable import PetCore

/// 可控的随机数：按顺序吐，吐完了一直给最后一个
final class Dice {
    var values: [Double]
    init(_ v: [Double]) { values = v }
    func next() -> Double { values.count > 1 ? values.removeFirst() : (values.first ?? 0.5) }
}

final class BrainTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
    var ground: Platform { Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0) }
    let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")

    func top(_ id: UInt32, y: Double, x: Double, w: Double) -> Platform {
        Platform(kind: .window(id: id), segment: Segment(y: y, minX: x, maxX: x + w), anchorX: x)
    }

    func brain(at p: CGPoint, dice: Dice = Dice([0.99])) -> Brain {
        Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles, interactDuration: 1), foot: p, random: dice.next)
    }

    func run(_ b: Brain, _ world: World, seconds: Double, dt: Double = 1.0 / 60) {
        var t = 0.0
        while t < seconds {
            b.step(dt: dt, world: world)
            t += dt
        }
    }

    func testFallsAndLandsOnGround() {
        let b = brain(at: CGPoint(x: 700, y: 600))
        run(b, World(platforms: [ground], screens: [screen]), seconds: 2)
        XCTAssertEqual(b.behavior, .idle)
        XCTAssertEqual(b.foot.y, 70)
        XCTAssertEqual(b.support, .on(.ground(screen: 1), dx: 700))
        XCTAssertEqual(b.anim?.name, "Relax")
    }

    func testLandsOnHighestWindowBelow() {
        let w = World(platforms: [ground, top(5, y: 400, x: 600, w: 300), top(6, y: 300, x: 600, w: 300)], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 800))
        run(b, w, seconds: 2)
        XCTAssertEqual(b.support.kind, .window(id: 5))
        XCTAssertEqual(b.foot.y, 400)
    }

    func testFollowsMovingWindowAndFallsWhenItCloses() {
        var w = World(platforms: [ground, top(5, y: 400, x: 600, w: 300)], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 400))
        run(b, w, seconds: 0.1)
        XCTAssertEqual(b.support, .on(.window(id: 5), dx: 100))
        // 窗口往右上挪
        w.platforms[1] = top(5, y: 450, x: 650, w: 300)
        run(b, w, seconds: 0.05)
        XCTAssertEqual(b.foot, CGPoint(x: 750, y: 450))
        // 窗口关了
        w.platforms.removeLast()
        run(b, w, seconds: 0.05)
        XCTAssertEqual(b.behavior, .fall)
        run(b, w, seconds: 2)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
    }

    func testFallsWhenFootGetsCovered() {
        var w = World(platforms: [ground, top(5, y: 400, x: 600, w: 300)], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 400))
        run(b, w, seconds: 0.1)
        // 前面来了个窗口，把 650..800 挡住（脚在 700）
        w.platforms[1] = Platform(kind: .window(id: 5), segment: Segment(y: 400, minX: 600, maxX: 650), anchorX: 600)
        w.platforms.append(Platform(kind: .window(id: 5), segment: Segment(y: 400, minX: 800, maxX: 900), anchorX: 600))
        run(b, w, seconds: 0.05)
        XCTAssertEqual(b.behavior, .fall)
    }

    func testWalksToTargetAtFormulaSpeed() {
        // 0.99 → idle 计时用满；然后 decide 0.1 → 走；目标 0.9 → 靠右
        let dice = Dice([0.0, 0.1, 0.9, 0.9])
        let b = brain(at: CGPoint(x: 300, y: 70), dice: dice)
        let w = World(platforms: [ground], screens: [screen])
        b.step(dt: 1.0 / 60, world: w) // 落地 → idle（计时 2.5s，dice 0.0）
        XCTAssertEqual(b.behavior, .idle)
        run(b, w, seconds: 2.6)
        XCTAssertEqual(b.behavior, .walk)
        XCTAssertEqual(b.dir, 1)
        XCTAssertEqual(b.anim?.name, "Move")
        let x0 = b.foot.x
        run(b, w, seconds: 1)
        XCTAssertEqual(b.foot.x - x0, 120 * 0.42, accuracy: 1.5)
    }

    func testFacePendingHoldsWalking() {
        let dice = Dice([0.0, 0.1, 0.9, 0.9])
        let b = brain(at: CGPoint(x: 300, y: 70), dice: dice)
        let w = World(platforms: [ground], screens: [screen])
        run(b, w, seconds: 2.6)
        XCTAssertEqual(b.behavior, .walk)
        b.facePending = true
        let x0 = b.foot.x
        run(b, w, seconds: 0.5)
        XCTAssertEqual(b.foot.x, x0)
        b.facePending = false
        run(b, w, seconds: 0.2)
        XCTAssertGreaterThan(b.foot.x, x0)
    }

    func testWalksOffWindowEdgeAndFalls() {
        // idle 计时 0 → decide 0.1 走 → 跳边 0.05 < 0.2 → 往右 0.9
        let dice = Dice([0.0, 0.1, 0.05, 0.9, 0.99])
        let w = World(platforms: [ground, top(5, y: 400, x: 600, w: 200)], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 400), dice: dice)
        run(b, w, seconds: 2.6)
        XCTAssertEqual(b.behavior, .walk)
        run(b, w, seconds: 3)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        XCTAssertGreaterThan(b.foot.x, 800)
    }

    func testWalksAcrossToNeighbourScreen() {
        let right = ScreenInfo(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 73, width: 1920, height: 982))
        let g2 = Platform(kind: .ground(screen: 2), segment: Segment(y: 73, minX: 1512, maxX: 3432), anchorX: 0)
        // 目标选在最右边（0.999），跨到右边那块屏幕
        let dice = Dice([0.0, 0.1, 0.999, 0.999, 0.999])
        let w = World(platforms: [ground, g2], screens: [screen, right])
        let b = brain(at: CGPoint(x: 1400, y: 70), dice: dice)
        run(b, w, seconds: 2.6)
        XCTAssertEqual(b.behavior, .walk)
        run(b, w, seconds: 60)
        XCTAssertEqual(b.support.kind, .ground(screen: 2))
        XCTAssertEqual(b.foot.y, 73)
    }

    func testDragReleaseThrowAndLand() {
        let w = World(platforms: [ground], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 70))
        run(b, w, seconds: 0.1)
        b.grab()
        XCTAssertEqual(b.behavior, .held)
        b.drag(to: CGPoint(x: 400, y: 20), world: w) // 拖到程序坞里：被夹回地面高度
        XCTAssertEqual(b.foot, CGPoint(x: 400, y: 70))
        b.drag(to: CGPoint(x: 400, y: 600), world: w)
        b.release(velocity: CGVector(dx: 800, dy: 500))
        XCTAssertEqual(b.behavior, .fall)
        run(b, w, seconds: 3)
        XCTAssertEqual(b.behavior, .idle)
        XCTAssertGreaterThan(b.foot.x, 450)
        XCTAssertEqual(b.foot.y, 70)
    }

    func testBouncesOffScreenEdge() {
        let w = World(platforms: [ground], screens: [screen])
        let b = brain(at: CGPoint(x: 1400, y: 600))
        b.grab()
        b.release(velocity: CGVector(dx: 3000, dy: 0))
        run(b, w, seconds: 3)
        XCTAssertLessThanOrEqual(b.foot.x, 1512 - 30)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
    }

    func testRescueWhenOutsideAllScreens() {
        let w = World(platforms: [ground], screens: [screen])
        let b = brain(at: CGPoint(x: 5000, y: 500)) // 外接屏拔掉了
        run(b, w, seconds: 0.1)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        XCTAssertEqual(b.foot.x, 756)
    }

    func testDockAppearsUnderPet() {
        var w = World(platforms: [Platform(kind: .ground(screen: 1), segment: Segment(y: 0, minX: 0, maxX: 1512), anchorX: 0)],
                      screens: [ScreenInfo(id: 1, frame: screen.frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957))])
        let b = brain(at: CGPoint(x: 700, y: 0))
        run(b, w, seconds: 0.1)
        XCTAssertEqual(b.foot.y, 0)
        w = World(platforms: [ground], screens: [screen]) // 程序坞弹出来了
        run(b, w, seconds: 0.05)
        XCTAssertEqual(b.foot.y, 70)
        XCTAssertEqual(b.behavior, .idle)
    }

    func testClickInteractThenBackToIdle() {
        let w = World(platforms: [ground], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 70))
        run(b, w, seconds: 0.1)
        let t0 = b.anim!.token
        b.click()
        XCTAssertEqual(b.behavior, .interact)
        XCTAssertEqual(b.anim, AnimRequest(name: "Interact", loop: false, token: t0 + 1))
        b.animationFinished("Interact")
        XCTAssertEqual(b.behavior, .idle)
        // 再点一次：同名动画也要重播（token 变了）
        b.click()
        XCTAssertEqual(b.anim?.token, t0 + 3)
    }

    func testClickWithoutInteractTurnsAround() {
        let b = Brain(params: PetParams(roles: Roles(idle: "Idle")), foot: CGPoint(x: 700, y: 70))
        run(b, World(platforms: [ground], screens: [screen]), seconds: 0.1)
        let d = b.dir
        b.click()
        XCTAssertEqual(b.dir, -d)
        XCTAssertEqual(b.behavior, .idle)
    }
    func testTurnFlipsAndStopsWalking() {
        let b = brain(at: CGPoint(x: 700, y: 70), dice: Dice([0.0, 0.1, 0.9, 0.9]))
        let w = World(platforms: [ground], screens: [screen])
        XCTAssertFalse(b.turn()) // 还在下落
        run(b, w, seconds: 2.7)
        XCTAssertEqual(b.behavior, .walk)
        let d = b.dir
        XCTAssertTrue(b.turn())
        XCTAssertEqual(b.dir, -d)
        XCTAssertEqual(b.behavior, .idle)
        // 停下来站着，不会倒着滑
        let x = b.foot.x
        run(b, w, seconds: 0.3)
        XCTAssertEqual(b.foot.x, x, accuracy: 0.001)
        XCTAssertEqual(b.dir, -d)
    }

    func testStayNeverWalksAndStopsWalking() {
        let b = brain(at: CGPoint(x: 700, y: 70), dice: Dice([0.0, 0.1, 0.9, 0.9]))
        let w = World(platforms: [ground], screens: [screen])
        run(b, w, seconds: 2.7)
        XCTAssertEqual(b.behavior, .walk)
        b.setActivity(.stay)
        XCTAssertEqual(b.behavior, .idle)
        let x = b.foot.x
        run(b, w, seconds: 60)
        XCTAssertNotEqual(b.behavior, .walk)
        XCTAssertEqual(b.foot.x, x, accuracy: 0.001)
    }

    func testStaySitIsKeptUntilChanged() {
        let b = brain(at: CGPoint(x: 700, y: 70))
        let w = World(platforms: [ground], screens: [screen])
        run(b, w, seconds: 0.2)
        b.setActivity(.stay)
        XCTAssertTrue(b.perform(.sit))
        run(b, w, seconds: 120)
        XCTAssertEqual(b.behavior, .sit)
        b.setActivity(.auto)
        XCTAssertEqual(b.behavior, .idle)
    }

    func testWalkModeKeepsWalking() {
        let b = Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles, interactDuration: 1), foot: CGPoint(x: 700, y: 70))
        let w = World(platforms: [ground], screens: [screen])
        run(b, w, seconds: 0.2)
        b.setActivity(.walk)
        var walked = 0.0
        var t = 0.0
        while t < 30 {
            b.step(dt: 1.0 / 60, world: w)
            if b.behavior == .walk { walked += 1.0 / 60 }
            XCTAssertNotEqual(b.behavior, .sit)
            XCTAssertNotEqual(b.behavior, .sleep)
            t += 1.0 / 60
        }
        XCTAssertGreaterThan(walked, 20)
    }

    func testTuningFillsMissingAndClampsBadValues() throws {
        let t = try JSONDecoder().decode(Tuning.self, from: Data(#"{"idle":[1,2],"sit":[5],"walkChance":7,"hoverAlpha":"x"}"#.utf8))
        XCTAssertEqual(t.idle, [1, 2])
        XCTAssertEqual(t.sit, Tuning().sit)
        XCTAssertEqual(t.walkChance, 1)
        XCTAssertEqual(t.hoverAlpha, Tuning().hoverAlpha)
    }
}
