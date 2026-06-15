import Foundation
import Darwin
import IOKit

// MARK: - SystemStats
//
// CPU load, CPU frequency, and GPU utilization on Apple Silicon.


enum SystemStats {

    // MARK: - CPU load
    //
    // host_processor_info(PROCESSOR_CPU_LOAD_INFO) returns CUMULATIVE ticks
    // since boot. The instantaneous load is therefore the DELTA between two
    // reads, not a single read — a single read divided by its own total
    // yields the average load over the whole uptime, which on a long-running
    // machine is a near-constant value and would collapse the load-bucketing
    // the degradation detector depends on.
    //
    // We keep the previous cumulative counters and return busyΔ / totalΔ.
    // The first call has no previous sample, so it returns the boot average
    // once (a single throwaway value); every call after that is the true
    // load over the interval since the last call (≈ the sample interval).

    private static var prevBusy: UInt64 = 0
    private static var prevTotal: UInt64 = 0
    private static var hasPrev = false
    private static let loadLock = NSLock()

    static func cpuLoad() -> Double {
        var processorCount: natural_t = 0
        var processorInfo:    processor_info_array_t? = nil
        var processorMsgCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorMsgCount
        )
        guard kr == KERN_SUCCESS, let info = processorInfo else { return 0 }

        defer {
            let size = vm_size_t(processorMsgCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var totalBusy: UInt64 = 0
        var totalAll:  UInt64 = 0

        for i in 0..<Int(processorCount) {
            let base = Int(i) * Int(CPU_STATE_MAX)
            let user   = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice   = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle   = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            totalBusy += user + system + nice
            totalAll  += user + system + nice + idle
        }

        loadLock.lock()
        defer { loadLock.unlock() }

        guard hasPrev else {
            // First call: no interval yet. Seed the counters and return the
            // boot-average as a one-time best effort.
            prevBusy = totalBusy
            prevTotal = totalAll
            hasPrev = true
            return totalAll > 0 ? Double(totalBusy) / Double(totalAll) : 0
        }

        let busyDelta  = totalBusy &- prevBusy
        let totalDelta = totalAll  &- prevTotal
        prevBusy = totalBusy
        prevTotal = totalAll

        guard totalDelta > 0 else { return 0 }
        return min(1.0, max(0.0, Double(busyDelta) / Double(totalDelta)))
    }

    // MARK: - CPU frequency
    //
    // Apple Silicon does not expose a clean "current frequency" in Hz
    // the way Intel Macs do via MSRs. The closest stable signal is the
    // P-State, which is qualitative. As a coarse quantitative proxy, we
    // use `sysctl hw.optional.arm.Frequency` (advertised max) and scale
    // by the P-State index. This is intentionally approximate; the
    // anomaly detector buckets by P-State index, not by absolute GHz.

    static func cpuMaxFrequencyGHz() -> Double? {
        var freq: Int64 = 0
        var size = MemoryLayout<Int64>.size
        let result = sysctlbyname("hw.optional.arm.Frequency", &freq, &size, nil, 0)
        guard result == 0 else { return nil }
        return Double(freq) / 1_000_000_000.0  // Hz → GHz
    }

    // MARK: - GPU utilization
    //
    // Apple Silicon exposes the real, instantaneous GPU utilization in the
    // IORegistry under the IOAccelerator service: PerformanceStatistics →
    // "Device Utilization %". This requires no privileges and no sudo, and
    // reads in microseconds. We take the max across GPU services (covers
    // multi-die SoCs like the M2 Ultra) and return a 0..1 fraction, or nil
    // if the key is unavailable.
    //
    // This replaces an earlier CPU busy-loop "estimate" that both wasted
    // power (a 50 ms spin every sample, preventing deep idle) and did not
    // actually measure the GPU.

    static func gpuLoad() -> Double? {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double? = nil
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any],
                  let util = perf["Device Utilization %"] as? Int
            else { continue }
            best = max(best ?? 0, Double(util) / 100.0)
        }
        return best
    }
}
