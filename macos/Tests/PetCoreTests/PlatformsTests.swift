import CoreGraphics
import XCTest

@testable import PetCore

final class PlatformsTests: XCTestCase {
    // 主屏 1512×982，菜单栏 25，程序坞 70
    let main = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 887))

    func win(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowInfo {
        WindowInfo(id: id, pid: 100, owner: "App", frame: CGRect(x: x, y: y, width: w, height: h))
    }

    /// 露出来的顶边
    func segments(_ ps: [Platform], _ id: UInt32) -> [Segment] {
        ps.filter { $0.kind == .window(id: id) && !$0.covered }.map(\.segment)
    }

    /// 被前面的窗口挡住的顶边
    func covered(_ ps: [Platform], _ id: UInt32) -> [Segment] {
        ps.filter { $0.kind == .window(id: id) && $0.covered }.map(\.segment)
    }

    func testGroundOnly() {
        let ps = Platforms.compute(screens: [main], windows: [win(1, 100, 200, 400, 300)], walkOnWindows: false)
        XCTAssertEqual(ps, [Platform(kind: .ground(screen: 1), segment: Segment(y: 70, minX: 0, maxX: 1512), anchorX: 0)])
    }

    func testSingleWindowTop() {
        let ps = Platforms.compute(screens: [main], windows: [win(7, 100, 200, 400, 300)], walkOnWindows: true)
        XCTAssertEqual(segments(ps, 7), [Segment(y: 500, minX: 100, maxX: 500)])
        XCTAssertEqual(ps.first { $0.kind == .window(id: 7) }?.anchorX, 100)
    }

    func testFrontWindowCoversMiddleOfTop() {
        // 前面的窗口 2 竖直方向盖住了窗口 1 的顶边（y=500）中间一段
        let ps = Platforms.compute(screens: [main], windows: [win(2, 250, 400, 100, 300), win(1, 100, 200, 400, 300)], walkOnWindows: true)
        XCTAssertEqual(segments(ps, 1), [Segment(y: 500, minX: 100, maxX: 250), Segment(y: 500, minX: 350, maxX: 500)])
        XCTAssertEqual(covered(ps, 1), [Segment(y: 500, minX: 250, maxX: 350)])
        XCTAssertEqual(segments(ps, 2), [Segment(y: 700, minX: 250, maxX: 350)])
        XCTAssertEqual(covered(ps, 2), [])
        XCTAssertTrue(ps.filter { $0.kind == .window(id: 1) }.allSatisfy { $0.anchorX == 100 })
    }

    func testTooNarrowGapCountsAsCovered() {
        // 两个前面的窗口之间只露出 20pt：站不下，并进挡住的那段
        let ps = Platforms.compute(screens: [main], windows: [win(2, 150, 400, 100, 300), win(3, 270, 400, 100, 300), win(1, 100, 200, 400, 300)], walkOnWindows: true)
        XCTAssertEqual(segments(ps, 1), [Segment(y: 500, minX: 100, maxX: 150), Segment(y: 500, minX: 370, maxX: 500)])
        XCTAssertEqual(covered(ps, 1), [Segment(y: 500, minX: 150, maxX: 370)])
    }

    func testFrontWindowBelowTopDoesNotCover() {
        // 前面的窗口整个在顶边下面：不挡
        let ps = Platforms.compute(screens: [main], windows: [win(2, 250, 100, 100, 200), win(1, 100, 200, 400, 300)], walkOnWindows: true)
        XCTAssertEqual(segments(ps, 1), [Segment(y: 500, minX: 100, maxX: 500)])
    }

    func testBackWindowDoesNotCoverFront() {
        // 后面的窗口不影响前面的
        let ps = Platforms.compute(screens: [main], windows: [win(1, 100, 200, 400, 300), win(2, 250, 400, 100, 300)], walkOnWindows: true)
        XCTAssertEqual(segments(ps, 1), [Segment(y: 500, minX: 100, maxX: 500)])
        XCTAssertEqual(segments(ps, 2), [Segment(y: 700, minX: 250, maxX: 350)])
    }

    func testFullyCoveredTopDisappears() {
        let ps = Platforms.compute(screens: [main], windows: [win(2, 0, 300, 800, 400), win(1, 100, 200, 400, 300)], walkOnWindows: true)
        XCTAssertEqual(segments(ps, 1), [])
        XCTAssertEqual(covered(ps, 1), [Segment(y: 500, minX: 100, maxX: 500)])
    }

    func testTopTooCloseToMenuBarOrTooShort() {
        // 最大化的窗口顶边贴着菜单栏：不要；只露出 30pt 的也不要
        let ps = Platforms.compute(
            screens: [main],
            windows: [win(1, 0, 70, 1512, 887), win(2, 600, 200, 30, 300)],
            walkOnWindows: true)
        XCTAssertEqual(segments(ps, 1), [])
        XCTAssertEqual(segments(ps, 2), [])
        XCTAssertEqual(covered(ps, 1) + covered(ps, 2), [])
    }

    func testWindowSpanningTwoScreens() {
        let right = ScreenInfo(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
        let ps = Platforms.compute(screens: [main, right], windows: [win(1, 1300, 300, 500, 200)], walkOnWindows: true)
        XCTAssertEqual(segments(ps, 1), [Segment(y: 500, minX: 1300, maxX: 1512), Segment(y: 500, minX: 1512, maxX: 1800)])
    }

    func testSubtract() {
        let r = Platforms.subtract([(0, 100), (200, 300)], 50, 250)
        XCTAssertEqual(r.map { [$0.0, $0.1] }, [[0, 50], [250, 300]])
    }

    func testFullscreenDetection() {
        let right = ScreenInfo(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
        let full = Platforms.fullscreenScreens(screens: [main, right], windows: [win(1, 1512, 0, 1920, 1080), win(2, 0, 70, 1512, 887)])
        XCTAssertEqual(full, [2])
    }
}
