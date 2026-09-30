import Darwin

enum Memory {
    /// 进程的物理内存占用（活动监视器里「内存」那一列），MB；同一用户的进程都读得到
    static func footprintMB(_ pid: pid_t) -> Double? {
        usage(pid).map { ($0.mb * 10).rounded() / 10 }
    }

    /// 内存占用（MB）和累计 CPU 时间（纳秒，用户态 + 内核态）
    static func usage(_ pid: pid_t) -> (mb: Double, cpuNs: UInt64)? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        // ri_user_time / ri_system_time 是 mach 时间单位（Apple 芯片上不是纳秒）
        let ticks = info.ri_user_time + info.ri_system_time
        return (Double(info.ri_phys_footprint) / 1_048_576, ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()
}
