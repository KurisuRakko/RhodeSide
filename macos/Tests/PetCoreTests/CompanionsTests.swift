import CoreGraphics
import XCTest

@testable import PetCore

final class CompanionsTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
    var ground: Platform { Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0) }
    let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")

    func brain(at p: CGPoint, dice: Dice = Dice([0.99])) -> Brain {
        Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles, interactDuration: 1), foot: p, random: dice.next)
    }

    /// 桌宠每帧走，协调器每 0.1 秒一次
    func run(_ brains: [(String, Brain)], _ c: Companions, _ world: World, seconds: Double, link: String? = "t") {
        let dt = 1.0 / 60
        var t = 0.0, acc = 0.0
        while t < seconds {
            for (_, b) in brains { b.step(dt: dt, world: world) }
            acc += dt
            if acc >= 0.1 {
                c.step(dt: acc, members: brains.map { Companions.Member(id: $0.0, link: link, brain: $0.1, world: world) })
                acc = 0
            }
            t += dt
        }
    }

    func testFollowerWalksBehindLeader() {
        let w = World(platforms: [ground], screens: [screen])
        // 领队：待机 2.5 秒 → 决定走（0.1）→ 目标 0.9 处（x ≈ 1336）→ 之后一直待机
        let leader = brain(at: CGPoint(x: 300, y: 70), dice: Dice([0, 0.1, 0.9]))
        let follower = brain(at: CGPoint(x: 200, y: 70))
        let c = Companions(random: { 0 })
        let pets = [("a", leader), ("b", follower)]
        run(pets, c, w, seconds: 3)
        XCTAssertEqual(leader.behavior, .walk)
        XCTAssertEqual(follower.behavior, .walk, "领队起步后跟随者也跟着走")
        run(pets, c, w, seconds: 30)
        XCTAssertEqual(leader.foot.x, 1336.8, accuracy: 0.5)
        // 排在领队后面：两个半身宽 + 空隙
        XCTAssertEqual(follower.foot.x, leader.foot.x - (30 + 30 + Companions.gap), accuracy: 0.5)
        XCTAssertEqual(follower.dir, 1, "到了面朝领队")
        XCTAssertEqual(follower.leash?.x ?? 0, leader.foot.x, accuracy: 0.001)
        XCTAssertNil(leader.leash)
    }

    func testDroppedMemberBecomesRallyPoint() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        let b = brain(at: CGPoint(x: 1000, y: 70))
        let c = Companions(random: { 0 })
        let pets = [("a", a), ("b", b)]
        run(pets, c, w, seconds: 0.5)
        // 把 b 拎到 1200 上空松手
        b.grab()
        b.drag(to: CGPoint(x: 1200, y: 300), world: w)
        b.release(velocity: .zero)
        run(pets, c, w, seconds: 1)
        XCTAssertEqual(c.anchors["t"], "b")
        XCTAssertEqual(a.behavior, .walk, "a 走过去找 b")
        XCTAssertEqual(a.leash?.x ?? 0, 1200, accuracy: 0.001)
        XCTAssertNil(b.leash)
        run(pets, c, w, seconds: 25)
        XCTAssertEqual(a.foot.x, 1200 - (30 + 30 + Companions.gap), accuracy: 0.5)
        XCTAssertEqual(a.dir, 1)
    }

    func testSittingPartnerGetsUpToSeek() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        let b = brain(at: CGPoint(x: 1000, y: 70))
        let c = Companions(random: { 0 })
        let pets = [("a", a), ("b", b)]
        run(pets, c, w, seconds: 0.5)
        XCTAssertTrue(b.perform(.sit))
        a.grab()
        a.drag(to: CGPoint(x: 600, y: 300), world: w)
        a.release(velocity: .zero)
        run(pets, c, w, seconds: 1.5)
        XCTAssertEqual(b.behavior, .walk)
        XCTAssertEqual(b.dir, -1)
    }

    func testClickMakesPartnerTurnAndReact() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        let b = brain(at: CGPoint(x: 500, y: 70))
        let c = Companions(random: { 0 })
        let pets = [("a", a), ("b", b)]
        run(pets, c, w, seconds: 0.5)
        XCTAssertEqual(b.dir, 1)
        a.click()
        run(pets, c, w, seconds: 0.2)
        XCTAssertEqual(b.behavior, .idle, "稍等一下才反应")
        run(pets, c, w, seconds: 0.4)
        XCTAssertEqual(b.behavior, .interact)
        XCTAssertEqual(b.dir, -1, "转向被点的那只")
    }

    func testSleepingPartnerIgnoresClick() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        let b = brain(at: CGPoint(x: 500, y: 70))
        let c = Companions(random: { 0 })
        let pets = [("a", a), ("b", b)]
        run(pets, c, w, seconds: 0.5)
        XCTAssertTrue(b.perform(.sleep))
        a.click()
        run(pets, c, w, seconds: 1)
        XCTAssertEqual(b.behavior, .sleep)
    }

    func testFollowerOnWindowJumpsDownToLeader() {
        let win = Platform(kind: .window(id: 5), segment: Segment(y: 400, minX: 600, maxX: 900), anchorX: 600)
        let w = World(platforms: [ground, win], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        // 跟随者待机 2.5 秒后做决定：集合点在下面 → 从左边（离得近）走出窗口跳下去
        let b = brain(at: CGPoint(x: 700, y: 400), dice: Dice([0, 0.99]))
        let c = Companions(random: { 0 })
        run([("a", a), ("b", b)], c, w, seconds: 10)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        XCTAssertLessThan(b.foot.x, 600)
    }

    func testStayingPartnerDoesNotMove() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        let b = brain(at: CGPoint(x: 1000, y: 70))
        b.setActivity(.stay)
        let c = Companions(random: { 0 })
        let pets = [("a", a), ("b", b)]
        run(pets, c, w, seconds: 0.5)
        a.grab()
        a.drag(to: CGPoint(x: 600, y: 300), world: w)
        a.release(velocity: .zero)
        run(pets, c, w, seconds: 3)
        XCTAssertEqual(b.foot.x, 1000)
    }

    func testUnlinkedPetsAreLeftAlone() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        let b = brain(at: CGPoint(x: 500, y: 70))
        let c = Companions(random: { 0 })
        let pets = [("a", a), ("b", b)]
        run(pets, c, w, seconds: 0.5, link: nil)
        a.click()
        run(pets, c, w, seconds: 1, link: nil)
        XCTAssertEqual(b.behavior, .idle)
        XCTAssertNil(b.leash)
        XCTAssertTrue(a.events.isEmpty, "事件也被取走了")
    }
    func testLeashedFollowerComesBackToItsSlotNotOntoLeader() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        // 离集合点 900pt（半径 300 以外）：待机 2.5 秒后走回来，停在集合点旁边一个身位
        let b = brain(at: CGPoint(x: 1200, y: 70), dice: Dice([0, 0.99]))
        let c = Companions(random: { 0 })
        run([("a", a), ("b", b)], c, w, seconds: 25)
        XCTAssertEqual(b.foot.x, 300 + (30 + 30 + Companions.gap), accuracy: 0.5)
        XCTAssertEqual(b.dir, -1, "面朝集合点")
    }

    func testUnreachableLeaderDoesNotFreezeFollower() {
        // 集合点在另一扇够不着的窗口上：跟随者在自己这片地方照常走
        let win = Platform(kind: .window(id: 5), segment: Segment(y: 500, minX: 1200, maxX: 1500), anchorX: 1200)
        let w = World(platforms: [ground, win], screens: [screen])
        let a = brain(at: CGPoint(x: 1300, y: 500))
        let b = brain(at: CGPoint(x: 100, y: 70))
        b.leash = Leash(x: 1300, y: 500, radius: 50)
        b.setActivity(.walk)
        run([("b", b)], Companions(), w, seconds: 3, link: nil)
        b.leash = Leash(x: 5000, y: 500, radius: 50)  // 半径和脚下这片完全不相交
        let before = b.foot.x
        run([("b", b)], Companions(), w, seconds: 5, link: nil)
        _ = a
        XCTAssertNotEqual(b.foot.x, before, "没有卡在原地")
    }

    func testClickDoesNotBreakHeldSitInStayMode() {
        let w = World(platforms: [ground], screens: [screen])
        let a = brain(at: CGPoint(x: 300, y: 70))
        let b = brain(at: CGPoint(x: 500, y: 70))
        b.setActivity(.stay)
        let c = Companions(random: { 0 })
        let pets = [("a", a), ("b", b)]
        run(pets, c, w, seconds: 0.5)
        XCTAssertTrue(b.perform(.sit))
        a.click()
        run(pets, c, w, seconds: 1)
        XCTAssertEqual(b.behavior, .sit, "原地停留时手动坐下的只转身")
        XCTAssertEqual(b.dir, -1)
    }

    func testJumpsDownOnTheSideThatHasAScreen() {
        // 窗口贴着屏幕右边：集合点虽然在右下方，也只能从左边跳
        let win = Platform(kind: .window(id: 5), segment: Segment(y: 400, minX: 1212, maxX: 1512), anchorX: 1212)
        let w = World(platforms: [ground, win], screens: [screen])
        let a = brain(at: CGPoint(x: 1500, y: 70))
        let b = brain(at: CGPoint(x: 1450, y: 400), dice: Dice([0, 0.99]))
        run([("a", a), ("b", b)], Companions(random: { 0 }), w, seconds: 12)
        XCTAssertEqual(b.support.kind, .ground(screen: 1))
        XCTAssertLessThan(b.foot.x, 1212)
    }
}
