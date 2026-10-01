import CoreGraphics
import XCTest

@testable import PetCore

/// 乱扔压测：随便拖到哪、随便多快扔出去，最后都得站回某块屏幕里
final class ThrowFuzzTests: XCTestCase {
    struct Rng {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
        mutating func r(_ a: Double, _ b: Double) -> Double { a + next() * (b - a) }
    }

    let roles = Roles(idle: "Relax", move: "Move", interact: "Interact", sit: "Sit", sleep: "Sleep")

    func check(screens: [ScreenInfo], windows: [Platform], seed: UInt64, label: String) {
        var rng = Rng(s: seed)
        var dice = Rng(s: seed ^ 0x9e37)
        let ids = ["A", "B", "C"]
        let brains = ids.map { _ in
            Brain(params: PetParams(height: 210, halfWidth: 66, stride: 1, roles: roles, interactDuration: 1),
                  foot: CGPoint(x: Double(screens[0].visibleFrame.midX), y: Double(screens[0].visibleFrame.maxY)), random: { dice.next() })
        }
        let ground = screens.map { Platform(kind: .ground(screen: $0.id), segment: .ground(visibleFrame: $0.visibleFrame), anchorX: 0) }
        func world(_ i: Int) -> World {
            let heads = zip(ids, brains).map { Stacking.Head(id: $0, foot: $1.foot, height: $1.headHeight, halfWidth: $1.params.halfWidth, below: $1.below, standing: $1.isStanding) }
            return World(platforms: ground + windows + Stacking.heads(for: ids[i], pets: heads, screens: screens), screens: screens)
        }
        func stepAll(_ dt: Double) {
            for (i, b) in brains.enumerated() { b.step(dt: dt, world: world(i)) }
        }
        // 脚在某块屏幕的可见区域里（菜单栏那一条也算看不见）
        func inside(_ p: CGPoint) -> Bool {
            screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(p) }
        }
        for round in 0..<500 {
            let i = Int(rng.next() * 3)
            let b = brains[i]
            b.grab()
            // 拖几下：鼠标只能在屏幕里，抓的位置可能离脚有一段
            let grab = CGVector(dx: rng.r(-60, 60), dy: rng.r(0, 200))
            for _ in 0..<Int(rng.r(1, 6)) {
                let s = screens[Int(rng.next() * Double(screens.count))].frame
                let m = CGPoint(x: rng.r(s.minX, s.maxX), y: rng.r(s.minY, s.maxY))
                b.drag(to: CGPoint(x: m.x - grab.dx, y: m.y - grab.dy), world: world(i))
                stepAll(1.0 / 60)
            }
            b.release(velocity: CGVector(dx: rng.r(-8000, 8000), dy: rng.r(-8000, 8000)))
            // 等都落稳：叠在头上的晚一帧跟上下面那只；下面那只落到高处窗口上，上面那只会再掉一次
            var t = 0.0
            var calm = 0
            while t < 8, calm < 3 {
                // 偶尔主线程卡一下：一帧 0.1 秒
                let dt = rng.next() < 0.05 ? 0.1 : 1.0 / 60
                stepAll(dt)
                t += dt
                calm = brains.contains { $0.behavior == .fall } ? 0 : calm + 1
            }
            for (j, bb) in brains.enumerated() where bb.behavior == .fall {
                XCTFail("8 秒还没落地：\(label) seed=\(seed) round=\(round) pet=\(ids[j]) foot=\(bb.foot)")
                return
            }
            for (j, bb) in brains.enumerated() where !inside(bb.foot) {
                let all = zip(ids, brains).map { "\($0)@(\(Int($1.foot.x)),\(Int($1.foot.y))) \($1.behavior) \($1.support)" }.joined(separator: " | ")
                XCTFail("脚在屏幕外：\(label) seed=\(seed) round=\(round) pet=\(ids[j]) thrown=\(ids[i]) :: \(all)")
                return
            }
            // 让它们自己活动一会儿（走路、走下窗口）
            for _ in 0..<Int(rng.r(0, 120)) { stepAll(1.0 / 60) }
        }
    }

    func testSingleScreenDockHidden() {
        let s = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085))
        for seed in 1...2 { check(screens: [s], windows: [], seed: UInt64(seed), label: "single") }
    }

    func testSingleScreenWithWindows() {
        let s = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1015))
        let w = [
            Platform(kind: .window(id: 5), segment: Segment(y: 700, minX: 100, maxX: 900), anchorX: 100),
            Platform(kind: .window(id: 6), segment: Segment(y: 400, minX: 800, maxX: 1728), anchorX: 800),
            // 快顶到菜单栏的窗口：站上去的那只头顶已经在屏幕外
            Platform(kind: .window(id: 7), segment: Segment(y: 1000, minX: 1100, maxX: 1600), anchorX: 1100),
        ]
        for seed in 1...2 { check(screens: [s], windows: w, seed: UInt64(seed), label: "windows") }
    }

    func testSideDock() {
        let s = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: CGRect(x: 80, y: 0, width: 1648, height: 1085))
        for seed in 1...2 { check(screens: [s], windows: [], seed: UInt64(seed), label: "sidedock") }
    }

    func testTwoScreensOffset() {
        let a = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1015))
        let b = ScreenInfo(id: 2, frame: CGRect(x: 1728, y: 400, width: 1920, height: 1080), visibleFrame: CGRect(x: 1728, y: 400, width: 1920, height: 1055))
        let c = ScreenInfo(id: 3, frame: CGRect(x: -1440, y: -500, width: 1440, height: 900), visibleFrame: CGRect(x: -1440, y: -500, width: 1440, height: 875))
        for seed in 1...2 { check(screens: [a, b, c], windows: [], seed: UInt64(seed), label: "multi") }
    }
}
