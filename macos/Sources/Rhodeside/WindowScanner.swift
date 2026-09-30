import AppKit
import CoreGraphics
import PetCore

/// 读别的程序的窗口（位置、层级、透明度、程序名）。这些都不需要屏幕录制或辅助功能权限（只有标题需要，不读）。
enum WindowScanner {
    /// 当前桌面空间里所有能站的候选窗口，从前到后。
    /// `primaryHeight` 是主屏（`NSScreen.screens[0]`）的高度，由主线程传进来：这两个函数都在后台线程调。
    static func scan(ownPID: pid_t, ignored: Set<String>, primaryHeight h: CGFloat) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [WindowInfo] = []
        for d in list {
            guard (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let num = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            guard alpha >= 0.1, cg.width >= 100, cg.height >= 40, !ignored.contains(owner.lowercased()) else { continue }
            out.append(WindowInfo(id: num, pid: pid, owner: owner, frame: Coords.appKitRect(fromCG: cg, primaryHeight: h)))
        }
        return out
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
