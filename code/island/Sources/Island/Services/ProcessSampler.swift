import Darwin
import Foundation

final class ProcessSampler: ProcessSampling {
    private var prevCPU: [pid_t: UInt64] = [:]   // cumulative cpu time in nanoseconds
    private var prevWall: UInt64?                // mach absolute time in nanoseconds
    private let selfPid = getpid()
    private let toNanos: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    private func ns(_ ticks: UInt64) -> UInt64 {
        // overflow-safe for realistic values (cpu time << 2^64 / numer)
        ticks.multipliedReportingOverflow(by: toNanos.numer).overflow
            ? ticks / toNanos.denom * toNanos.numer
            : ticks * toNanos.numer / toNanos.denom
    }

    func sample(limit: Int) -> (byCPU: [ProcessRow], byMemory: [ProcessRow]) {
        let bufCount = Int(proc_listallpids(nil, 0))
        guard bufCount > 0 else { return ([], []) }
        var pids = [pid_t](repeating: 0, count: bufCount + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard n > 0 else { return ([], []) }

        let wall = ns(mach_absolute_time())
        let dWall = prevWall.map { wall > $0 ? Double(wall - $0) : 0 } ?? 0

        struct Raw { let pid: pid_t; let cpu: Double; let mem: UInt64 }
        var raws: [Raw] = []
        raws.reserveCapacity(n)
        var newCPU: [pid_t: UInt64] = [:]
        newCPU.reserveCapacity(n)

        for i in 0..<n {
            let pid = pids[i]
            if pid <= 0 || pid == selfPid { continue }
            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if ok != 0 { continue }
            let cpuNs = ns(ru.ri_user_time &+ ru.ri_system_time)
            newCPU[pid] = cpuNs
            var pct = 0.0
            if dWall > 0, let p = prevCPU[pid], cpuNs >= p { pct = Double(cpuNs - p) / dWall * 100 }
            raws.append(Raw(pid: pid, cpu: pct, mem: ru.ri_phys_footprint))
        }
        prevCPU = newCPU
        prevWall = wall

        func row(_ r: Raw) -> ProcessRow { ProcessRow(id: r.pid, name: name(r.pid), cpuPercent: r.cpu, memoryBytes: r.mem) }
        let topCPU = raws.sorted { $0.cpu > $1.cpu }.prefix(limit).map(row)
        let topMem = raws.sorted { $0.mem > $1.mem }.prefix(limit).map(row)
        return (topCPU, topMem)
    }

    private func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            return (String(cString: path) as NSString).lastPathComponent
        }
        return "pid \(pid)"
    }
}
