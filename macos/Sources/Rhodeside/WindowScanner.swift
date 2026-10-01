import AppKit
import CoreGraphics
import PetCore

/// 读别的程序的窗口（位置、层级、透明度、程序名）。这些都不需要屏幕录制或辅助功能权限（只有标题需要，不读）。
enum WindowScanner {
    struct Scan {
        /// 能站的候选窗口，从前到后
        var windows: [WindowInfo] = []
        /// 第 0 层所有窗口（含自己的小人窗口）从前到后的窗口号：检查小人是不是还排在它脚下那个窗口正上方
        var order: [UInt32] = []
        var focus: Focus = .unknown
    }

    /// 当前桌面空间里所有能站的候选窗口，从前到后；顺带给出层级顺序和焦点窗口。
    /// `primaryHeight` 是主屏（`NSScreen.screens[0]`）的高度、`frontPID` 是最前面的应用，都由主线程传进来：这两个函数都在后台线程调。
    static func scan(ownPID: pid_t, ignored: Set<String>, primaryHeight h: CGFloat, frontPID: pid_t?) -> Scan {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return Scan()
        }
        var out: [WindowInfo] = []
        var order: [UInt32] = []
        for d in list {
            guard (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let num = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            order.append(num)
            guard pid != ownPID,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            guard alpha >= 0.1, cg.width >= 100, cg.height >= 40, !ignored.contains(owner.lowercased()) else { continue }
            out.append(WindowInfo(id: num, pid: pid, owner: owner, frame: Coords.appKitRect(fromCG: cg, primaryHeight: h)))
        }
        // 焦点：最前面那个应用最靠前的窗口。最前面的是自己（开着设置窗口）、只有被过滤掉的小窗口 / 空气窗口、
        // 或者压根没有普通窗口（Raycast、菜单栏小工具、点了桌面）时，取最前面的别人的窗口
        let focus: Focus
        if let front = frontPID {
            focus = (out.first(where: { $0.pid == front }) ?? out.first).map { .window($0.id) } ?? .none
        } else {
            focus = .unknown
        }
        return Scan(windows: out, order: order, focus: focus)
    }

    /// 某个窗口现在的位置（每帧查脚下那个）；关了、最小化了、不在当前桌面空间都返回 nil
    static func currentFrame(of id: UInt32, primaryHeight: CGFloat) -> CGRect? {
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let arr = CFArrayCreate(kCFAllocatorDefault, &ids, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]],
              let d = list.first,
              (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bounds = d[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        return Coords.appKitRect(fromCG: cg, primaryHeight: primaryHeight)
    }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var info: ScreenInfo { ScreenInfo(id: displayID, frame: frame, visibleFrame: visibleFrame) }
}
