import CoreGraphics
import XCTest

@testable import PetCore

final class GeometryTests: XCTestCase {
    func testCGRectToAppKit() {
        // 主屏高 982：CG 里顶边 y=25（菜单栏下面）、高 400 的窗口，AppKit 里底边在 982-25-400=557
        let r = Coords.appKitRect(fromCG: CGRect(x: 100, y: 25, width: 800, height: 400), primaryHeight: 982)
        XCTAssertEqual(r, CGRect(x: 100, y: 557, width: 800, height: 400))
        XCTAssertEqual(r.maxY, 982 - 25)  // 顶边 = H − cgY
    }

    func testCGRectOnSecondaryScreenAbovePrimary() {
        // 副屏在主屏上方：CG 的 y 是负数，AppKit 的 y 大于主屏高
        let r = Coords.appKitRect(fromCG: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryHeight: 982)
        XCTAssertEqual(r.minY, 982)
        XCTAssertEqual(r.maxY, 982 + 1080)
    }

    func testLayoutWindowFrame() {
        let l = PetLayout(w: 200, h: 150, footX: 100, footY: 10)
        XCTAssertEqual(l.windowFrame(foot: CGPoint(x: 700, y: 80)), CGRect(x: 600, y: 70, width: 200, height: 150))
    }

    func testSegmentClamp() {
        let s = Segment(y: 0, minX: 0, maxX: 1000)
        XCTAssertEqual(s.clamp(x: 10, half: 50), 50)
        XCTAssertEqual(s.clamp(x: 990, half: 50), 950)
        XCTAssertEqual(s.clamp(x: 500, half: 50), 500)
        // 线段比身体窄：站中间
        XCTAssertEqual(Segment(y: 0, minX: 0, maxX: 60).clamp(x: 5, half: 50), 30)
    }

    func testGroundFromVisibleFrame() {
        let g = Segment.ground(visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))
        XCTAssertEqual(g, Segment(y: 70, minX: 0, maxX: 1512))
    }

    /// 和 web/src/pet/motion.test.ts 同一组数：两边外推公式一致
    func testMotionMatchesWebExtrapolation() {
        let ground = Motion(x: 100, vx: 50, y: 54).at(0.2)
        XCTAssertEqual(ground.x, 110, accuracy: 1e-9)
        XCTAssertEqual(ground.y, 54, accuracy: 1e-9)
        let air = Motion(x: 0, vx: 120, y: 0, vy: 1000, g: 2800, k: 1.2).at(0.08)
        XCTAssertEqual(air.x, 120 * (1 - exp(-1.2 * 0.08)) / 1.2, accuracy: 1e-9)
        XCTAssertEqual(air.y, 1000 * 0.08 - 1400 * 0.0064, accuracy: 1e-9)
        XCTAssertEqual(Motion(x: 0, vx: 0, y: 0, g: 2800, k: 1.2).at(5).y, -1400 * Motion.maxAheadInAir * Motion.maxAheadInAir, accuracy: 1e-9)
        XCTAssertEqual(Motion(x: 0, vx: 100, y: 0).at(5).x, 100 * Motion.maxAhead, accuracy: 1e-9)
    }
}
