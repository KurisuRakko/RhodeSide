import CoreGraphics
import XCTest

@testable import PetCore

/// 窗口撞到小人：判定撞没撞、落脚点、弹跳能不能落到窗口顶上
final class WindowHopTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
    var ground: Platform { Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0) }
    let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")

    func win(_ id: UInt32, _ r: CGRect) -> WindowInfo { WindowInfo(id: id, pid: 1, owner: "App", frame: r) }

    func top(_ id: UInt32, y: Double, x: Double, w: Double) -> Platform {
        Platform(kind: .window(id: id), segment: Segment(y: y, minX: x, maxX: x + w), anchorX: x)
    }

    func brain(at p: CGPoint) -> Brain {
        Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles, interactDuration: 1), foot: p, random: Dice([0.99]).next)
    }

    func run(_ b: Brain, _ world: World, seconds: Double, dt: Double = 1.0 / 60) {
        var t = 0.0
        while t < seconds {
            b.step(dt: dt, world: world)
            t += dt
        }
    }

    /// 站在地面 x=700 上的小人，身高 120
    var body: CGRect { WindowHop.body(foot: CGPoint(x: 700, y: 70), halfWidth: 30, top: 190) }

    func testHitOnlyWhenMovedIntoBody() {
        let away = CGRect(x: 900, y: 0, width: 400, height: 300)
        let onto = CGRect(x: 650, y: 0, width: 400, height: 300)
        // 拖过来压到身上
        XCTAssertEqual(WindowHop.hit(body: body, old: [1: away], new: [win(1, onto)])?.id, 1)
        // 本来就压着、又挪了一点：不算
        XCTAssertNil(WindowHop.hit(body: body, old: [1: onto.offsetBy(dx: 20, dy: 0)], new: [win(1, onto)]))
        // 没动：不算
        XCTAssertNil(WindowHop.hit(body: body, old: [1: onto], new: [win(1, onto)]))
        // 新开的窗口：不算
        XCTAssertNil(WindowHop.hit(body: body, old: [:], new: [win(1, onto)]))
        // 脚下那个窗口：不算
        XCTAssertNil(WindowHop.hit(body: body, old: [1: away], new: [win(1, onto)], exclude: 1))
        // 缩放：右边拉宽压过来也算
        XCTAssertEqual(WindowHop.hit(body: body, old: [1: CGRect(x: 300, y: 0, width: 300, height: 300)],
                                     new: [win(1, CGRect(x: 300, y: 0, width: 500, height: 300))])?.id, 1)
    }

    func testGrazingDoesNotCount() {
        // 横向只擦到 3pt（身体框 x ∈ [682, 718]）
        let r = CGRect(x: 685 - 400, y: 0, width: 400, height: 300)
        XCTAssertNil(WindowHop.hit(body: body, old: [1: r.offsetBy(dx: -200, dy: 0)], new: [win(1, r)]))
        // 窗口顶边刚到脚踝（身体框从脚上方 4pt 起，只重叠 3pt）
        let low = CGRect(x: 650, y: 0, width: 400, height: 77)
        XCTAssertNil(WindowHop.hit(body: body, old: [1: low.offsetBy(dx: 400, dy: 0)], new: [win(1, low)]))
    }

    func testHitTakesFrontmost() {
        let a = CGRect(x: 600, y: 0, width: 300, height: 400)
        let b = CGRect(x: 650, y: 0, width: 300, height: 300)
        let old: [UInt32: CGRect] = [1: a.offsetBy(dx: 500, dy: 0), 2: b.offsetBy(dx: 500, dy: 0)]
        XCTAssertEqual(WindowHop.hit(body: body, old: old, new: [win(2, b), win(1, a)])?.id, 2)
    }

    func testTargetNearestSegmentClamped() {
        let ps = [ground, top(1, y: 300, x: 100, w: 200), top(1, y: 300, x: 900, w: 300), top(2, y: 500, x: 600, w: 300)]
        // x=700 离 [900,1200] 那段近：夹到 900+半宽
        XCTAssertEqual(WindowHop.target(window: 1, platforms: ps, x: 700, half: 30), CGPoint(x: 930, y: 300))
        // 段里面的不挪
        XCTAssertEqual(WindowHop.target(window: 1, platforms: ps, x: 1000, half: 30), CGPoint(x: 1000, y: 300))
        // 这个窗口没有可站的顶边
        XCTAssertNil(WindowHop.target(window: 3, platforms: ps, x: 700, half: 30))
    }

    func testHopLandsOnWindowTop() {
        for (h, dx) in [(20.0, 0.0), (300, 0), (300, 300), (300, -300), (800, 150), (800, -400)] {
            let b = brain(at: CGPoint(x: 700, y: 70))
            let w = World(platforms: [ground, top(9, y: 70 + h, x: 700 + dx - 100, w: 200)], screens: [screen])
            run(b, w, seconds: 0.2)
            XCTAssertTrue(b.isStanding)
            XCTAssertTrue(b.hop(to: CGPoint(x: 700 + dx, y: 70 + h)))
            XCTAssertEqual(b.behavior, .fall)
            run(b, w, seconds: 1.2)
            XCTAssertEqual(b.support.kind, .window(id: 9), "高 \(h) 偏 \(dx)")
            XCTAssertEqual(Double(b.foot.y), 70 + h, accuracy: 0.01)
            XCTAssertEqual(Double(b.foot.x), 700 + dx, accuracy: 15, "高 \(h) 偏 \(dx)")
        }
    }

    func testHopAt30fpsStillReaches() {
        let b = brain(at: CGPoint(x: 700, y: 70))
        let w = World(platforms: [ground, top(9, y: 870, x: 650, w: 100)], screens: [screen])
        run(b, w, seconds: 0.2)
        XCTAssertTrue(b.hop(to: CGPoint(x: 700, y: 870)))
        run(b, w, seconds: 1.5, dt: 1.0 / 30)
        XCTAssertEqual(b.support.kind, .window(id: 9))
    }

    func testHopRefusedWhenNotStanding() {
        let w = World(platforms: [ground], screens: [screen])
        let falling = brain(at: CGPoint(x: 700, y: 600))
        XCTAssertFalse(falling.hop(to: CGPoint(x: 700, y: 800)))
        let held = brain(at: CGPoint(x: 700, y: 70))
        run(held, w, seconds: 0.2)
        held.grab()
        XCTAssertFalse(held.hop(to: CGPoint(x: 700, y: 300)))
    }

    func testStackRidesAlong() {
        let lower = brain(at: CGPoint(x: 700, y: 70))
        let upper = brain(at: CGPoint(x: 700, y: 300))
        let window = top(9, y: 400, x: 800, w: 300)
        func world(for id: String) -> World {
            let hs = [("A", lower), ("B", upper)].map { Stacking.Head(id: $0.0, foot: $0.1.foot, height: $0.1.headHeight, halfWidth: $0.1.params.halfWidth, below: $0.1.below, standing: $0.1.isStanding) }
            return World(platforms: [ground, window] + Stacking.heads(for: id, pets: hs, screens: [screen]), screens: [screen])
        }
        func run(_ s: Double) {
            var t = 0.0
            while t < s {
                lower.step(dt: 1.0 / 60, world: world(for: "A"))
                upper.step(dt: 1.0 / 60, world: world(for: "B"))
                t += 1.0 / 60
            }
        }
        lower.teleport(to: CGPoint(x: 700, y: 70))
        upper.teleport(to: CGPoint(x: 700, y: 300), stack: true)
        run(0.5)
        XCTAssertEqual(upper.below, "A")
        XCTAssertFalse(upper.hop(to: CGPoint(x: 900, y: 400)), "叠在别人头上的自己不跳")
        XCTAssertTrue(lower.hop(to: CGPoint(x: 900, y: 400)))
        run(1.5)
        XCTAssertEqual(lower.support.kind, .window(id: 9))
        XCTAssertEqual(upper.below, "A")
        XCTAssertEqual(Double(upper.foot.y), 400 + lower.headHeight, accuracy: 0.5)
    }
}
