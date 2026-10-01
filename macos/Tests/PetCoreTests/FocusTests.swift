import CoreGraphics
import XCTest

@testable import PetCore

/// 不在焦点的窗口上只在露出来的那段里溜达；脚下被盖住就走到露出来的地方，整个被盖住就待着
final class FocusTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
    var ground: Platform { Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0) }
    let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")

    func top(_ id: UInt32, x: Double, w: Double, y: Double = 400, covered: Bool = false, anchor: Double = 600) -> Platform {
        Platform(kind: .window(id: id), segment: Segment(y: y, minX: x, maxX: x + w), anchorX: anchor, covered: covered)
    }

    /// 一直循环这串数：总是想走、总是想跳窗边（0.05 < edgeJumpChance）
    func brain(at p: CGPoint, cycle: [Double] = [0.0, 0.1, 0.05, 0.9, 0.3, 0.7]) -> Brain {
        var i = 0
        return Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles, interactDuration: 1), foot: p) {
            defer { i += 1 }
            return cycle[i % cycle.count]
        }
    }

    func run(_ b: Brain, _ world: World, seconds: Double, dt: Double = 1.0 / 60, each: (() -> Void)? = nil) {
        var t = 0.0
        while t < seconds {
            b.step(dt: dt, world: world)
            each?()
            t += dt
        }
    }

    func testFocusedWindowStillJumpsOffEdge() {
        let w = World(platforms: [ground, top(5, x: 600, w: 200)], screens: [screen], focus: .window(5))
        let b = brain(at: CGPoint(x: 700, y: 400))
        run(b, w, seconds: 30)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
    }

    func testUnfocusedWindowWandersInsideOnly() {
        let w = World(platforms: [ground, top(5, x: 600, w: 200)], screens: [screen], focus: .window(9))
        let b = brain(at: CGPoint(x: 700, y: 400))
        var walked = false
        run(b, w, seconds: 60) {
            XCTAssertEqual(b.support.kind, .window(id: 5))
            XCTAssertGreaterThanOrEqual(Double(b.foot.x), 630 - 1)
            XCTAssertLessThanOrEqual(Double(b.foot.x), 770 + 1)
            if b.behavior == .walk { walked = true }
        }
        XCTAssertTrue(walked, "露出来的那段里可以溜达")
        // 点了桌面（没有焦点窗口）也一样
        let none = World(platforms: w.platforms, screens: [screen], focus: .none)
        run(b, none, seconds: 30)
        XCTAssertEqual(b.support.kind, .window(id: 5))
    }

    func testWalkStopsAtEdgeWhenFocusLost() {
        // 在焦点时开始往窗口边走（要跳下去），走到一半窗口失焦：停在边上，不掉
        let focused = World(platforms: [ground, top(5, x: 600, w: 200)], screens: [screen], focus: .window(5))
        let b = brain(at: CGPoint(x: 610, y: 400), cycle: [0.0, 0.1, 0.05, 0.9])
        run(b, focused, seconds: 2.6)
        XCTAssertEqual(b.behavior, .walk)
        XCTAssertEqual(b.dir, 1)
        let lost = World(platforms: focused.platforms, screens: [screen], focus: .window(9))
        run(b, lost, seconds: 10)
        XCTAssertEqual(b.support.kind, .window(id: 5))
        XCTAssertLessThanOrEqual(Double(b.foot.x), 770 + 1)
    }

    func testGoRefusedOnUnfocusedWindow() {
        let w = World(platforms: [ground, top(5, x: 600, w: 200)], screens: [screen], focus: .window(9))
        let b = brain(at: CGPoint(x: 700, y: 400), cycle: [0.99])
        run(b, w, seconds: 0.1)
        XCTAssertFalse(b.go(to: CGPoint(x: 300, y: 70), world: w))
        XCTAssertTrue(b.go(to: CGPoint(x: 300, y: 70), world: World(platforms: w.platforms, screens: [screen], focus: .window(5))))
    }

    func testCoveredWalksToNearestVisibleThenStays() {
        // 窗口 5 的顶边：露 [600,700]、盖 [700,1000]、露 [1000,1100]；脚在 800（被盖住）
        let ps = [ground, top(5, x: 600, w: 100), top(5, x: 1000, w: 100), top(5, x: 700, w: 300, covered: true)]
        let w = World(platforms: ps, screens: [screen], focus: .window(9))
        let b = brain(at: CGPoint(x: 800, y: 400), cycle: [0.99])
        // 先站上去（被盖住的顶边落不上去），再被前面的窗口盖住
        run(b, World(platforms: [ground, top(5, x: 600, w: 500)], screens: [screen]), seconds: 0.1)
        XCTAssertEqual(b.support.kind, .window(id: 5))
        run(b, w, seconds: 0.05)
        XCTAssertEqual(b.support.kind, .window(id: 5))
        XCTAssertEqual(b.behavior, .walk, "被盖住马上往外走")
        XCTAssertEqual(b.dir, -1, "左边那段近")
        run(b, w, seconds: 5)
        XCTAssertEqual(Double(b.foot.x), 670, accuracy: 0.5, "身子整个露出来")
        XCTAssertEqual(b.support.kind, .window(id: 5))
        run(b, w, seconds: 30) {
            XCTAssertLessThanOrEqual(Double(b.foot.x), 670 + 0.5)
        }
    }

    func testFullyCoveredWaitsThenWalksOutWhenUncovered() {
        let covered = World(platforms: [ground, top(5, x: 600, w: 300, covered: true)], screens: [screen], focus: .window(9))
        let b = brain(at: CGPoint(x: 700, y: 400))
        run(b, World(platforms: [ground, top(5, x: 600, w: 300)], screens: [screen], focus: .window(9)), seconds: 0.1)
        run(b, covered, seconds: 30) {
            XCTAssertEqual(b.support.kind, .window(id: 5))
            XCTAssertEqual(Double(b.foot.x), 700, accuracy: 0.01)
        }
        // 前面的窗口挪开了右边一截
        let part = World(platforms: [ground, top(5, x: 600, w: 200, covered: true), top(5, x: 800, w: 100)], screens: [screen], focus: .window(9))
        run(b, part, seconds: 5)
        XCTAssertEqual(Double(b.foot.x), 830, accuracy: 0.5)
    }

    func testOthersIgnoreCoveredTops() {
        // 从上面掉下来不落在被盖住的顶边上
        let w = World(platforms: [ground, top(5, x: 600, w: 300, covered: true)], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 800), cycle: [0.99])
        run(b, w, seconds: 2)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        // 被盖住的顶边不能当弹跳目标
        XCTAssertNil(WindowHop.target(window: 5, platforms: w.platforms, x: 700, half: 30))
    }

    func testApexCoversHop() {
        let w = World(platforms: [ground, top(9, x: 650, w: 100, y: 600)], screens: [screen])
        let b = brain(at: CGPoint(x: 700, y: 70), cycle: [0.99])
        run(b, w, seconds: 0.1)
        XCTAssertTrue(b.hop(to: CGPoint(x: 700, y: 600)))
        let apex = b.apexY
        XCTAssertGreaterThan(apex, 600)
        var highest = 0.0
        run(b, w, seconds: 1.5) { highest = max(highest, Double(b.foot.y)) }
        XCTAssertLessThanOrEqual(highest, apex + 0.5, "飞行中脚不会高过一开始算的最高点（带子不用重设）")
        XCTAssertEqual(b.support.kind, .window(id: 9))
        XCTAssertEqual(b.visualVY, 0)
    }
}
