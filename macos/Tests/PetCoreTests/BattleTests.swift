import CoreGraphics
import XCTest

@testable import PetCore

/// 战斗形态和套组播放（认套组在网页 combos.ts，有自己的测试）
final class BattleTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
    var ground: Platform { Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0) }

    /* ---------------------------------------------------------------- 战斗形态 */

    func brain() -> Brain {
        let roles = Roles(idle: "Idle", move: "Move", interact: nil, sit: nil, sleep: nil)
        return Brain(params: PetParams(height: 120, halfWidth: 30, stride: 1, roles: roles), foot: CGPoint(x: 700, y: 70), random: { 0 })
    }

    func run(_ b: Brain, seconds: Double) {
        let w = World(platforms: [ground], screens: [screen])
        var t = 0.0
        while t < seconds {
            b.step(dt: 1.0 / 60, world: w)
            t += 1.0 / 60
        }
    }

    func testBattleNeverWalksAndLoopsPose() {
        let b = brain()
        b.setBattle(true)
        b.setActivity(.walk)
        run(b, seconds: 30)
        XCTAssertEqual(b.behavior, .idle)
        XCTAssertEqual(b.foot.x, 700)
        XCTAssertEqual(b.anim?.name, "Idle")
        b.pose = "Skill_3_Idle"
        XCTAssertEqual(b.anim, AnimRequest(name: "Skill_3_Idle", loop: true, token: b.anim!.token))
        XCTAssertFalse(b.perform(.sit))
    }

    func testComboPlaysInOrderThenReturnsToPose() {
        let b = brain()
        b.setBattle(true)
        b.pose = "Default"
        run(b, seconds: 0.5)
        let steps = [
            ComboStep(name: "Skill_1_Begin", loop: false, seconds: 0.5),
            ComboStep(name: "Skill_1_Loop", loop: true, seconds: 3),
            ComboStep(name: "Skill_1_End", loop: false, seconds: 0.4),
        ]
        XCTAssertTrue(b.play(steps))
        XCTAssertEqual(b.anim?.name, "Skill_1_Begin")
        // 网页报一次性动画播完 → 下一步；循环段按时间走
        b.animationFinished("Skill_1_Begin")
        XCTAssertEqual(b.anim?.name, "Skill_1_Loop")
        b.animationFinished("Skill_1_Loop")
        XCTAssertEqual(b.anim?.name, "Skill_1_Loop")
        run(b, seconds: 3.1)
        XCTAssertEqual(b.anim?.name, "Skill_1_End")
        // animDone 没来：按时长兜底
        run(b, seconds: 1.0)
        XCTAssertEqual(b.behavior, .idle)
        XCTAssertEqual(b.anim?.name, "Default")
    }

    func testBattleClickPlaysAttackAndGrabCancelsCombo() {
        let b = brain()
        b.setBattle(true)
        run(b, seconds: 0.5)
        b.attack = [ComboStep(name: "Attack", loop: false, seconds: 0.8)]
        b.click()
        XCTAssertEqual(b.behavior, .interact)
        XCTAssertEqual(b.anim?.name, "Attack")
        b.grab()
        XCTAssertEqual(b.behavior, .held)
        b.animationFinished("Attack")
        XCTAssertEqual(b.behavior, .held)
        // 没有攻击动画：点一下转身
        b.release(velocity: .zero)
        run(b, seconds: 0.5)
        b.attack = []
        let dir = b.dir
        b.click()
        XCTAssertEqual(b.dir, -dir)
    }
}
