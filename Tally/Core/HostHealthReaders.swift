import Darwin
import Foundation

/// WHAT THE MACHINE IS ASKED ABOUT ITSELF, for the watch next door (HostHealthLogic.swift).
/// Split from the rules for the reason `ProcessTreeReaders.swift` is: everything here is a
/// syscall with no decision in it and needs `Darwin`, and everything there is arithmetic an
/// assertion harness can state with no machine under it.
///
/// WHAT AN ORDINARY SAMPLE COSTS, which is the whole reason this feature could be put on an
/// existing tick at all: three syscalls that walk nothing. `getloadavg(3)`, `host_statistics64` and
/// `host_page_size`, measured on this machine (2026-09-05, Apple silicon, 1,150 processes in the
/// table, load 70): mean 1.8 microseconds over twenty runs, median 1.6, worst 3.0. At one sample a
/// minute that is three parts in a hundred million of one core.
///
/// AND WHAT THE EXPENSIVE ONE COSTS, which is why it is not on that path: `heaviest` walks the
/// whole process table and asks the kernel for one `rusage_info` record per process, which is
/// 3.9 ms on the same machine and the same table (mean of five runs, worst 4.4). That is the same
/// walk the session footprint makes every two seconds while a panel is open, and it is made here
/// exactly once per alarm, never on a sample that found nothing wrong.
enum HostHealthReaders {

    /// The one-minute load average, or nothing when the machine will not say.
    ///
    /// `getloadavg(3)` RATHER THAN `uptime` OR `sysctl vm.loadavg`: the first is a fork, an exec
    /// and a parse for a number the libc call returns directly, and the second hands back a
    /// fixed-point struct this would then have to scale itself. Nothing here is privileged.
    static func loadAverage() -> Double? {
        var samples = [Double](repeating: 0, count: 3)
        guard getloadavg(&samples, 3) == 3 else { return nil }
        return samples[0]
    }

    /// What the machine could hand out right now without paging, in bytes.
    ///
    /// FREE PLUS INACTIVE PLUS PURGEABLE, AND NOT THE COMPRESSOR. Inactive pages are handed over on
    /// demand and purgeable ones are dropped on demand, so both are available in the sense this
    /// watch means; compressed pages are memory already spent and counting them would report a
    /// machine as comfortable at the exact moment it is compressing to stay alive. This is the
    /// same arithmetic Activity Monitor's own "available" is, and it is deliberately a second
    /// opinion to `MachineMemoryPressure`, which answers a LEVEL rather than a size: a level
    /// cannot be put in a notification that has to say how much is left.
    static func freeBytes() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
            / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Every term below is a page COUNT, so the multiply is the only place a unit could go
        // wrong, and the page size is asked of the kernel rather than assumed: it is 16 KB on
        // Apple silicon and 4 KB on Intel, and a constant here would be off by four on one of
        // them. `host_page_size` rather than the `vm_kernel_page_size` global, which is a mutable
        // global and so not readable from concurrent code under strict concurrency.
        var pageSize = vm_size_t(0)
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.purgeable_count)) * UInt64(pageSize)
    }

    /// One reading of the whole machine: the load, the cores it is spread over, and what is free.
    /// Nothing at all when either syscall refuses, which the caller reads as "this sample did not
    /// happen" rather than as a reading of zero.
    static func reading() -> HostHealthReading? {
        guard let load = loadAverage(), let free = freeBytes() else { return nil }
        return HostHealthReading(load1: load, cores: ProcessInfo.processInfo.activeProcessorCount,
                                 freeBytes: free)
    }

    /// The biggest memory holders on the machine, most first.
    ///
    /// THE ONE EXPENSIVE READING IN THIS FEATURE, and it is made only at the instant an alarm is
    /// raised. A number says the machine is short; a name says what is holding it, and that is the
    /// difference between somebody knowing to look and knowing where.
    ///
    /// ONE `proc_pid_rusage` PER PROCESS AND ONLY THREE `proc_pidpath` CALLS: the footprint of
    /// every process is compared first and only the survivors are named, so the path lookups are
    /// three rather than one per process on the machine.
    ///
    /// NAMES, NEVER ARGUMENTS (`HostHealthProcess` states the rule and where it comes from). A
    /// process whose program cannot be read is left unnamed rather than guessed at, on the terms
    /// `ProcessTree.executablePath` sets: it has ended, or it belongs to another user.
    static func heaviest(_ limit: Int = 3) -> [HostHealthProcess] {
        let pids = ProcessTree.liveProcesses().map(\.pid)
        // The whole-machine reading this file needs is one field of the record the footprint
        // sampler already asks for, so the call is shared rather than spelled a second time.
        let sample = ProcessTree.resourceSample(of: pids)
        // Ties broken on the pid so the answer cannot change between two calls while nothing else
        // has, the rule the board's own heaviest-tree comparison is under.
        let ranked = sample.memory.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        return ranked.prefix(limit).map { entry in
            let name = ProcessTree.executablePath(of: entry.key)
                .flatMap(ProcessTree.displayName) ?? "unknown"
            return HostHealthProcess(name: name, rss: entry.value)
        }
    }
}
