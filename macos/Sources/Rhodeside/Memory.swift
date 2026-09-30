import Darwin

enum Memory {
    /// 进程的物理内存占用（活动监视器里「内存」那一列），MB；同一用户的进程都读得到
    static func footprintMB(_ pid: pid_t) -> Double? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        return (Double(info.ri_phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}
