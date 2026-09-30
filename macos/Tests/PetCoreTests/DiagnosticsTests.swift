import XCTest

@testable import PetCore

final class DiagnosticsTests: XCTestCase {
    /* ---------------------------------------------------------------- ResourceAlarm */

    func testMemoryOverLimitWarnsOnceThenCoolsDown() {
        let a = ResourceAlarm()
        XCTAssertEqual(a.check([ResourceSample(name: "App", kind: .app, mb: 30)], now: 0), [])
        let w = a.check([ResourceSample(name: "App", kind: .app, mb: 500)], now: 60)
        XCTAssertTrue(w.contains { $0.hasPrefix("内存占用过大：App 500 MB") }, "\(w)")
        // 冷却期内同样的值不再报（涨了但没到 1.5 倍）
        XCTAssertFalse(a.check([ResourceSample(name: "App", kind: .app, mb: 600)], now: 120).contains { $0.hasPrefix("内存占用过大") })
        // 又涨了一半：马上再报
        XCTAssertTrue(a.check([ResourceSample(name: "App", kind: .app, mb: 800)], now: 180).contains { $0.hasPrefix("内存占用过大：App 800 MB") })
        // 冷却过了：再报
        XCTAssertTrue(a.check([ResourceSample(name: "App", kind: .app, mb: 800)], now: 180 + 1801).contains { $0.hasPrefix("内存占用过大") })
    }

    func testGrowthFromBaseline() {
        let a = ResourceAlarm()
        _ = a.check([ResourceSample(name: "网页 a", kind: .web, mb: 60)], now: 0)
        XCTAssertEqual(a.check([ResourceSample(name: "网页 a", kind: .web, mb: 300)], now: 60), [])
        // 一次高峰不算，连续两次才报
        XCTAssertEqual(a.check([ResourceSample(name: "网页 a", kind: .web, mb: 380)], now: 120), [])
        XCTAssertEqual(a.check([ResourceSample(name: "网页 a", kind: .web, mb: 70)], now: 180), [])
        XCTAssertEqual(a.check([ResourceSample(name: "网页 a", kind: .web, mb: 380)], now: 240), [])
        let w = a.check([ResourceSample(name: "网页 a", kind: .web, mb: 390)], now: 300)
        XCTAssertEqual(w, ["内存持续上涨：网页 a 从 60 MB 涨到 390 MB（可能有泄漏）"])
    }

    func testGPUHasNoGrowthWarning() {
        let a = ResourceAlarm()
        _ = a.check([ResourceSample(name: "GPU", kind: .gpu, mb: 300)], now: 0)
        XCTAssertEqual(a.check([ResourceSample(name: "GPU", kind: .gpu, mb: 1000)], now: 60), [])
    }

    func testCPUNeedsTwoHotSamplesInARow() {
        let a = ResourceAlarm()
        let hot = ResourceSample(name: "App", kind: .app, mb: 30, cpu: 150)
        let cool = ResourceSample(name: "App", kind: .app, mb: 30, cpu: 5)
        XCTAssertEqual(a.check([hot], now: 0), [])
        XCTAssertEqual(a.check([cool], now: 60), [])
        XCTAssertEqual(a.check([hot], now: 120), [])
        XCTAssertEqual(a.check([hot], now: 180), ["CPU 占用过高：App 持续 150%（100% = 占满一个核）"])
    }

    func testTotalOverLimit() {
        let a = ResourceAlarm()
        let s = (0..<10).map { ResourceSample(name: "网页 \($0)", kind: .web, mb: 350) }
        XCTAssertEqual(a.check(s, now: 0), ["内存占用过大：合计 3500 MB（上限 3000 MB）"])
    }

    func testGoneProcessForgetsBaseline() {
        let a = ResourceAlarm()
        _ = a.check([ResourceSample(name: "网页 a", kind: .web, mb: 60)], now: 0)
        _ = a.check([], now: 60)
        // 网页进程重载过：新的基线从 380 开始，不算上涨
        XCTAssertEqual(a.check([ResourceSample(name: "网页 a", kind: .web, mb: 380)], now: 120), [])
    }

    /* ---------------------------------------------------------------- RunRecord */

    func testUncleanExitSummary() {
        var r = RunRecord(pid: 42, version: "1.0 (7)", started: Date(timeIntervalSince1970: 0))
        r.beat = Date(timeIntervalSince1970: 3 * 3600 + 5 * 60)
        r.appMB = 30.4
        r.webMB = 120
        r.gpuMB = 350
        r.pressure = "critical"
        let s = r.uncleanExitSummary(now: Date(timeIntervalSince1970: 3 * 3600 + 5 * 60 + 40))
        XCTAssertTrue(s.contains("1.0 (7)，pid 42"), s)
        XCTAssertTrue(s.contains("启动后 3 小时 5 分，距今 40 秒"), s)
        XCTAssertTrue(s.contains("App 30 MB，网页合计 120 MB，GPU 350 MB"), s)
        XCTAssertTrue(s.contains("严重"), s)

        let fresh = RunRecord(pid: 1, version: "x", started: Date())
        XCTAssertTrue(fresh.uncleanExitSummary(now: Date()).contains("一分钟内就没了"))
    }

    func testRecordRoundTrips() throws {
        var r = RunRecord(pid: 7, version: "v", started: Date(timeIntervalSince1970: 1000))
        r.appMB = 1.5
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(RunRecord.self, from: enc.encode(r)), r)
    }

    func testDuration() {
        XCTAssertEqual(RunRecord.duration(5), "5 秒")
        XCTAssertEqual(RunRecord.duration(125), "2 分")
        XCTAssertEqual(RunRecord.duration(7200), "2 小时")
        XCTAssertEqual(RunRecord.duration(7260), "2 小时 1 分")
        XCTAssertEqual(RunRecord.duration(86400 * 2 + 3600 * 4), "2 天 4 小时")
    }

    /* ---------------------------------------------------------------- CivilDate */

    func testCivilDate() {
        XCTAssertTrue(CivilDate.from(days: 0) == (1970, 1, 1))
        XCTAssertTrue(CivilDate.from(days: -1) == (1969, 12, 31))
        XCTAssertTrue(CivilDate.from(days: 11016) == (2000, 2, 29))
        // 2026-09-30
        XCTAssertTrue(CivilDate.from(days: 20726) == (2026, 9, 30))
    }

    /* ---------------------------------------------------------------- CrashReport */

    func testCrashReportSummary() throws {
        let head = #"{"app_name":"Rhodeside","app_version":"1.0","bug_type":"309","name":"Rhodeside"}"#
        let body = #"""
        {
          "uptime" : 3700,
          "exception" : {"codes":"0x0000000000000001, 0x0000000000000000","type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
          "termination" : {"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler"},
          "asi" : {"libswiftCore.dylib":["Rhodeside/Pet.swift:120: Fatal error: Unexpectedly found nil while unwrapping an Optional value"]},
          "faultingThread" : 0,
          "threads" : [{"triggered":true,"queue":"com.apple.main-thread","frames":[
            {"imageOffset":100,"symbol":"Pet.loadPage()","symbolLocation":12,"imageIndex":0,"sourceFile":"Pet.swift","sourceLine":120},
            {"imageOffset":4096,"imageIndex":1}
          ]}],
          "usedImages" : [{"name":"Rhodeside"},{"name":"AppKit"}]
        }
        """#
        let s = try XCTUnwrap(CrashReport.summary(head + "\n" + body))
        let lines = s.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "异常 EXC_BREAKPOINT（SIGTRAP），codes 0x0000000000000001, 0x0000000000000000；终止 Trace/BPT trap: 5（SIGNAL 5），由 exc handler 结束；版本 1.0；系统开机 1 小时 1 分")
        XCTAssertTrue(lines[1].contains("Fatal error: Unexpectedly found nil"), lines[1])
        XCTAssertEqual(lines[2], "  崩溃线程 0（com.apple.main-thread）：")
        XCTAssertEqual(lines[3], "    0 Rhodeside  Pet.loadPage() + 12（Pet.swift:120）")
        XCTAssertEqual(lines[4], "    1 AppKit  +0x1000")
    }

    func testCrashReportPrefersExceptionBacktrace() throws {
        let body = #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"lastExceptionBacktrace":[{"symbol":"objc_exception_throw","imageIndex":0}],"faultingThread":0,"threads":[{"frames":[{"symbol":"abort","imageIndex":0}]}],"usedImages":[{"name":"libobjc.A.dylib"}]}"#
        let s = try XCTUnwrap(CrashReport.summary("{}\n" + body))
        XCTAssertTrue(s.contains("异常抛出时的调用栈"), s)
        XCTAssertTrue(s.contains("objc_exception_throw"), s)
        XCTAssertFalse(s.contains("abort"), s)
    }

    func testCrashReportGarbage() {
        XCTAssertNil(CrashReport.summary("not json"))
        XCTAssertNil(CrashReport.summary("{}\nnope"))
    }
}
