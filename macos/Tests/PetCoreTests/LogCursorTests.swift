import XCTest

@testable import PetCore

final class LogCursorTests: XCTestCase {
    private let cur = LogFileInfo(inode: 20, size: 500)
    private let prev = LogFileInfo(inode: 10, size: 2_100_000)

    func testFirstRunReadsWholeCurrentFile() {
        let r = LogPlan.slices(cursor: nil, current: cur, previous: prev, limit: 4_000_000)
        XCTAssertEqual(r.slices, [LogSlice(.current, 0, 500)])
        XCTAssertEqual(r.next, LogCursor(file: 20, offset: 500))
        XCTAssertFalse(r.truncated)
    }

    func testSameFileReadsFromOffset() {
        let r = LogPlan.slices(cursor: LogCursor(file: 20, offset: 120), current: cur, previous: prev, limit: 4_000_000)
        XCTAssertEqual(r.slices, [LogSlice(.current, 120, 500)])
        XCTAssertEqual(r.next, LogCursor(file: 20, offset: 500))
    }

    func testNothingNew() {
        let r = LogPlan.slices(cursor: LogCursor(file: 20, offset: 500), current: cur, previous: prev, limit: 4_000_000)
        XCTAssertEqual(r.slices, [])
        XCTAssertEqual(r.next, LogCursor(file: 20, offset: 500))
    }

    func testRotatedFileFinishesPreviousThenCurrent() {
        let r = LogPlan.slices(cursor: LogCursor(file: 10, offset: 2_000_000), current: cur, previous: prev, limit: 4_000_000)
        XCTAssertEqual(r.slices, [LogSlice(.previous, 2_000_000, 2_100_000), LogSlice(.current, 0, 500)])
        XCTAssertEqual(r.next, LogCursor(file: 20, offset: 500))
    }

    func testUnknownFileReadsWholeCurrent() {
        let r = LogPlan.slices(cursor: LogCursor(file: 99, offset: 7), current: cur, previous: prev, limit: 4_000_000)
        XCTAssertEqual(r.slices, [LogSlice(.current, 0, 500)])
    }

    func testShrunkFileStartsOver() {
        let r = LogPlan.slices(cursor: LogCursor(file: 20, offset: 9_000), current: cur, previous: nil, limit: 4_000_000)
        XCTAssertEqual(r.slices, [LogSlice(.current, 0, 500)])
    }

    func testLimitKeepsTail() {
        let r = LogPlan.slices(cursor: LogCursor(file: 10, offset: 0), current: cur, previous: prev, limit: 1_000)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.slices, [LogSlice(.previous, 2_099_500, 2_100_000), LogSlice(.current, 0, 500)])
        XCTAssertEqual(r.slices.reduce(0) { $0 + $1.length }, 1_000)
        XCTAssertEqual(r.next, LogCursor(file: 20, offset: 500))
    }

    func testLimitDropsWholePreviousSlice() {
        let r = LogPlan.slices(cursor: LogCursor(file: 10, offset: 0), current: cur, previous: prev, limit: 300)
        XCTAssertEqual(r.slices, [LogSlice(.current, 200, 500)])
    }

    func testNoLogFileKeepsCursor() {
        let c = LogCursor(file: 20, offset: 5)
        let r = LogPlan.slices(cursor: c, current: nil, previous: prev, limit: 4_000_000)
        XCTAssertEqual(r.slices, [])
        XCTAssertEqual(r.next, c)
    }
}
