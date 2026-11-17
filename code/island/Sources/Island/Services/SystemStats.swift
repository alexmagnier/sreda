import Darwin
import Foundation
import IOKit

final class SystemStats: SystemStatsProviding {
    private var prevTicks: (busy: UInt64, idle: UInt64)?

    func sampleMemory() -> (used: UInt64, total: UInt64, compressed: UInt64, pressure: MemoryPressure) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used: UInt64 = 0, compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            let app = internalPages > purgeable ? internalPages - purgeable : 0
            used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            compressed = UInt64(stats.compressor_page_count) * page
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return (used, total, compressed, MemoryPressure(rawValue: Int(level)) ?? .normal)
    }

    func sampleCPU() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        var busy: UInt64 = 0, idle: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = i * stride
            busy += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
                + UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
                + UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
        }
        defer { prevTicks = (busy, idle) }
        guard let p = prevTicks, busy >= p.busy, idle >= p.idle else { return nil }
        let db = Double(busy - p.busy), di = Double(idle - p.idle)
        guard db + di > 0 else { return nil }
        return db / (db + di) * 100
    }

    func sampleGPU() -> Double? {
        guard let match = IOServiceMatching("IOAccelerator") else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let dict = raw as? [String: Any],
                  let util = dict["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, util.doubleValue)
        }
        return best
    }

    func thermal() -> ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }

    func diskFree() -> UInt64? {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let n = v?.volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(0, n))
    }
}
