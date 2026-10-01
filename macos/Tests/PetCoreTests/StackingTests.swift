import CoreGraphics
import XCTest

@testable import PetCore

/// 叠叠乐：小人的头顶当平台
final class StackingTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
    var ground: Platform { Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0) }
    let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")

    func brain(at p: CGPoint, dice: Dice = Dice([0.99])) -> Brain {
        Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles, interactDuration: 1), foot: p, random: dice.next)
    }

    func head(_ id: String, _ b: Brain, usable: Bool = true) -> Stacking.Head {
        Stacking.Head(id: id, foot: b.foot, height: b.params.height, halfWidth: b.params.halfWidth, below: b.below, usable: usable)
    }

    /// 和原生层的 `PetManager.world(for:)` 一样：固定平台 + 别的小人的头顶
    func world(for id: String, _ pets: [(String, Brain)], extra: [Platform] = [], gone: Set<String> = []) -> World {
        let hs = pets.map { head($0.0, $0.1, usable: !gone.contains($0.0)) }
        return World(platforms: [ground] + extra + Stacking.heads(for: id, pets: hs), screens: [screen])
    }

    /// 每帧按顺序各走一步（各自的 display link），每只走之前按别的小人现在的位置重算世界
    func run(_ pets: [(String, Brain)], seconds: Double, extra: [Platform] = [], gone: Set<String> = [], each: (() -> Void)? = nil) {
        let dt = 1.0 / 60
        var t = 0.0
        while t < seconds {
            for (id, b) in pets where !gone.contains(id) { b.step(dt: dt, world: world(for: id, pets, extra: extra, gone: gone)) }
            each?()
            t += dt
        }
    }

    /// 拎起来放到 p 上方松手
    func drop(_ b: Brain, over p: CGPoint, _ w: World) {
        b.grab()
        b.drag(to: p, world: w)
        b.release(velocity: .zero)
    }

    func testHeadsExcludeSelfPetsAboveAndUnusable() {
        let hs = [
            Stacking.Head(id: "A", foot: CGPoint(x: 700, y: 70), height: 120, halfWidth: 30, below: nil),
            Stacking.Head(id: "B", foot: CGPoint(x: 700, y: 190), height: 100, halfWidth: 20, below: "A"),
            Stacking.Head(id: "C", foot: CGPoint(x: 700, y: 290), height: 100, halfWidth: 20, below: "B"),
            Stacking.Head(id: "D", foot: CGPoint(x: 300, y: 70), height: 100, halfWidth: 20, below: nil, usable: false),
        ]
        XCTAssertEqual(Stacking.heads(for: "A", pets: hs).map(\.kind), []) // B、C 都叠在 A 上面
        XCTAssertEqual(Stacking.heads(for: "B", pets: hs).map(\.kind), [.pet(id: "A")])
        XCTAssertEqual(Stacking.heads(for: "C", pets: hs).map(\.kind), [.pet(id: "A"), .pet(id: "B")])
        let a = Stacking.heads(for: "C", pets: hs)[0]
        XCTAssertEqual(a.segment, Segment(y: 190, minX: 700 - 21, maxX: 700 + 21))
        XCTAssertEqual(a.anchorX, 700)
        // 数据里真有环（不该出现）也不会死循环
        let loop = [Stacking.Head(id: "A", foot: .zero, height: 1, halfWidth: 1, below: "B"),
                    Stacking.Head(id: "B", foot: .zero, height: 1, halfWidth: 1, below: "A")]
        XCTAssertEqual(Stacking.heads(for: "C", pets: loop).count, 2)
    }

    func testDroppedOnHeadStandsAndIsCarriedByWalkingPet() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 300, y: 70))
        let pets = [("A", a), ("B", b)]
        run(pets, seconds: 0.1)
        drop(b, over: CGPoint(x: 710, y: 500), world(for: "B", pets))
        run(pets, seconds: 1)
        XCTAssertEqual(b.support.kind, .pet(id: "A"))
        XCTAssertTrue(b.isOnPet)
        XCTAssertEqual(b.below, "A")
        XCTAssertEqual(b.foot, CGPoint(x: 710, y: 190))
        XCTAssertEqual(b.behavior, .idle)

        XCTAssertTrue(a.go(to: CGPoint(x: 1100, y: 70), world: world(for: "A", pets)))
        run(pets, seconds: 9) { // 400pt ÷ 50.4pt/s
            XCTAssertEqual(b.foot.x, a.foot.x + 10, accuracy: 0.001)
            XCTAssertEqual(b.foot.y, 190)
        }
        XCTAssertEqual(a.foot.x, 1100)
        XCTAssertEqual(b.support.kind, .pet(id: "A"))
    }

    func testStackedPetNeverWalksOnItsOwn() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 300, y: 70), dice: Dice([0.05])) // 每次都选走路、目标都在左边
        let pets = [("A", a), ("B", b)]
        run(pets, seconds: 0.1)
        drop(b, over: CGPoint(x: 700, y: 500), world(for: "B", pets))
        run(pets, seconds: 1)
        XCTAssertEqual(b.support.kind, .pet(id: "A"))
        b.setActivity(.walk)
        b.leash = Leash(x: 100, y: 70, radius: 50) // 套组集合点在远处也不下来
        XCTAssertFalse(b.go(to: CGPoint(x: 100, y: 70), world: world(for: "B", pets)))
        run(pets, seconds: 30) {
            XCTAssertNotEqual(b.behavior, .walk)
            XCTAssertEqual(b.support.kind, .pet(id: "A"))
        }
    }

    func testCarriedWhenLowerIsDraggedAndFallsWhenLowerIsGone() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 300, y: 70))
        let pets = [("A", a), ("B", b)]
        run(pets, seconds: 0.1)
        drop(b, over: CGPoint(x: 700, y: 500), world(for: "B", pets))
        run(pets, seconds: 1)
        // 拎起下面那只：上面那只跟着被提走，放下后还在头上
        a.grab()
        a.drag(to: CGPoint(x: 400, y: 500), world: world(for: "A", pets))
        run(pets, seconds: 0.05)
        XCTAssertEqual(b.foot, CGPoint(x: 400, y: 620))
        a.release(velocity: .zero)
        run(pets, seconds: 2)
        XCTAssertEqual(a.foot, CGPoint(x: 400, y: 70))
        XCTAssertEqual(b.foot, CGPoint(x: 400, y: 190))
        XCTAssertEqual(b.support.kind, .pet(id: "A"))
        // 下面那只不见了（隐藏、删掉）：掉到地上
        run(pets, seconds: 2, gone: ["A"])
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        XCTAssertEqual(b.foot.y, 70)
    }

    func testOnlyThrownOrRestoredPetsLandOnHeads() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 700, y: 800)) // 刚创建、自己往下掉
        let pets = [("A", a), ("B", b)]
        run(pets, seconds: 2)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        b.teleport(to: CGPoint(x: 700, y: 800)) // 叫回来
        run(pets, seconds: 2)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        b.teleport(to: CGPoint(x: 700, y: 800), stack: true) // 重启后放回头上
        run(pets, seconds: 2)
        XCTAssertEqual(b.support.kind, .pet(id: "A"))
    }

    func testWalkOffWindowEdgeDoesNotLandOnHead() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 500, y: 300))
        let pets = [("A", a), ("B", b)]
        let win = [Platform(kind: .window(id: 5), segment: Segment(y: 300, minX: 400, maxX: 690), anchorX: 400)]
        run(pets, seconds: 0.5, extra: win)
        XCTAssertEqual(b.support.kind, .window(id: 5))
        // 往 A 的方向走、从窗口右边跳下去：正好掉过 A 的头顶，但不停在那
        XCTAssertTrue(b.go(to: CGPoint(x: 710, y: 70), world: world(for: "B", pets, extra: win)))
        run(pets, seconds: 6, extra: win)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
    }

    func testWalkingNeverStepsOntoAHead() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 500, y: 190))
        let pets = [("A", a), ("B", b)]
        // 和 A 的头一样高、紧挨着 A 头顶左边的窗口
        let win = [Platform(kind: .window(id: 5), segment: Segment(y: 190, minX: 400, maxX: 680), anchorX: 400)]
        run(pets, seconds: 0.5, extra: win)
        XCTAssertEqual(b.support.kind, .window(id: 5))
        XCTAssertTrue(b.go(to: CGPoint(x: 900, y: 190), world: world(for: "B", pets, extra: win)))
        run(pets, seconds: 5, extra: win)
        XCTAssertEqual(b.support.kind, .window(id: 5))
        XCTAssertEqual(b.foot.x, 650) // 走到窗口右端（减半身宽）就停
    }

    func testLandingOnHeadIsNotADropAndNarrowerHeadKeepsIt() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 300, y: 70))
        let pets = [("A", a), ("B", b)]
        run(pets, seconds: 0.1)
        _ = b.takeEvents()
        drop(b, over: CGPoint(x: 718, y: 500), world(for: "B", pets))
        run(pets, seconds: 1)
        XCTAssertEqual(b.support.kind, .pet(id: "A"))
        XCTAssertFalse(b.takeEvents().contains(.dropped)) // 套组成员不会来找它、把下面那只拽走
        // 下面那只换了瘦模型：头顶变成 700±7，上面那只夹回来，不掉
        a.params.halfWidth = 10
        run(pets, seconds: 0.5)
        XCTAssertEqual(b.support.kind, .pet(id: "A"))
        XCTAssertEqual(b.foot.x, 707, accuracy: 0.001)
        // 跟着走的时候报给渲染端的速度就是下面那只的速度
        XCTAssertTrue(a.go(to: CGPoint(x: 1100, y: 70), world: world(for: "A", pets)))
        run(pets, seconds: 1)
        XCTAssertEqual(b.visualVX, a.params.walkSpeed, accuracy: 0.001)
    }

    func testThreeHighTower() {
        let a = brain(at: CGPoint(x: 700, y: 70))
        let b = brain(at: CGPoint(x: 300, y: 70))
        let c = brain(at: CGPoint(x: 1100, y: 70))
        let pets = [("A", a), ("B", b), ("C", c)]
        run(pets, seconds: 0.1)
        drop(b, over: CGPoint(x: 700, y: 500), world(for: "B", pets))
        run(pets, seconds: 1)
        drop(c, over: CGPoint(x: 705, y: 700), world(for: "C", pets))
        run(pets, seconds: 1)
        XCTAssertEqual(c.support.kind, .pet(id: "B"))
        XCTAssertEqual(c.foot.y, 310)
        XCTAssertTrue(a.go(to: CGPoint(x: 300, y: 70), world: world(for: "A", pets)))
        run(pets, seconds: 9)
        XCTAssertEqual(a.foot.x, 300)
        XCTAssertEqual(b.foot.x, 300)
        XCTAssertEqual(c.foot.x, 305, accuracy: 0.001)
        XCTAssertEqual(c.foot.y, 310)
    }

    func testHeadLowersWhenBelowSitsAndTopFollows() {
        let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
        let ground = Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0)
        let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")
        let lower = Brain(params: PetParams(height: 120, halfWidth: 30, roles: roles, sitHeight: 0.6, sleepHeight: 0.4), foot: CGPoint(x: 500, y: 70), random: { 0.99 })
        let top = Brain(params: PetParams(height: 100, halfWidth: 25, roles: roles), foot: CGPoint(x: 500, y: 200), random: { 0.99 })
        func world() -> World {
            let heads = Stacking.heads(for: "top", pets: [Stacking.Head(id: "lower", foot: lower.foot, height: lower.headHeight, halfWidth: lower.params.halfWidth, below: nil)])
            return World(platforms: [ground] + heads, screens: [screen])
        }
        top.teleport(to: CGPoint(x: 500, y: 200), stack: true)
        for _ in 0..<60 {
            lower.step(dt: 1.0 / 60, world: World(platforms: [ground], screens: [screen]))
            top.step(dt: 1.0 / 60, world: world())
        }
        XCTAssertEqual(top.below, "lower")
        XCTAssertEqual(top.foot.y, 190, accuracy: 0.01)
        XCTAssertTrue(lower.perform(.sit))
        XCTAssertEqual(lower.headHeight, 72, accuracy: 0.01)
        top.step(dt: 1.0 / 60, world: world())
        XCTAssertEqual(top.foot.y, 142, accuracy: 0.01, "下面那只坐下，上面那只跟着矮下去，不悬空")
        XCTAssertEqual(top.below, "lower")
        XCTAssertTrue(lower.perform(.idle))
        top.step(dt: 1.0 / 60, world: world())
        XCTAssertEqual(top.foot.y, 190, accuracy: 0.01)
    }

    func testFallingPetLandsOnHeadThatRisesPastItsFeet() {
        let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
        let ground = Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0)
        let roles = Roles(idle: "Relax", move: "Move", sit: "Sit", sleep: "Sleep")
        let lower = Brain(params: PetParams(height: 120, halfWidth: 30, roles: roles, sitHeight: 0.5), foot: CGPoint(x: 500, y: 70), random: { 0.99 })
        lower.step(dt: 1.0 / 60, world: World(platforms: [ground], screens: [screen]))
        XCTAssertTrue(lower.perform(.sit))
        let top = Brain(params: PetParams(height: 100, halfWidth: 25, roles: roles), foot: .zero, random: { 0.99 })
        top.teleport(to: CGPoint(x: 500, y: 150), stack: true) // 脚在坐着的头顶（130）上方、站着的头顶（190）下方
        top.step(dt: 1.0 / 60, world: World(platforms: [ground], screens: [screen])) // 先往下掉一点
        XCTAssertTrue(lower.perform(.idle)) // 下面那只站起来，头顶升到 190
        let heads = Stacking.heads(for: "top", pets: [Stacking.Head(id: "lower", foot: lower.foot, height: lower.headHeight, halfWidth: lower.params.halfWidth, below: nil)])
        top.step(dt: 1.0 / 60, world: World(platforms: [ground] + heads, screens: [screen]))
        XCTAssertEqual(top.below, "lower", "没有穿过下面那只的身子")
        XCTAssertEqual(top.foot.y, 190, accuracy: 0.01)
    }
}
