import Darwin
import Foundation

struct ProcessUsage: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let cpu: Double
    let isFrozen: Bool
    let canFreeze: Bool
}

/// Finds the processes burning the most CPU and pauses them with SIGSTOP.
/// A frozen process keeps its windows and memory but uses no CPU until thawed.
/// Scans run only when asked (tab opened or "Quét lại"), never in the background.
@MainActor
final class ProcessFreezer: ObservableObject {
    static let shared = ProcessFreezer()

    private static let frozenKey = "frozenPIDs"
    nonisolated private static let sampleInterval: TimeInterval = 1
    nonisolated private static let listLimit = 6

    /// Pausing these would freeze the desktop itself.
    nonisolated private static let protectedNames: Set<String> = [
        "loginwindow", "Dock", "SystemUIServer", "ControlCenter", "WindowManager",
        "NotificationCenter", "TextInputMenuAgent", "universalaccessd", "TileDeck",
    ]

    @Published private(set) var processes: [ProcessUsage] = []
    @Published private(set) var isScanning = false

    private var frozen: Set<pid_t>

    private init() {
        frozen = Set((UserDefaults.standard.array(forKey: Self.frozenKey) as? [Int32]) ?? [])
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let frozen = frozen
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.sample(frozen: frozen)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.processes = result
                    self.isScanning = false
                }
            }
        }
    }

    func freeze(_ pid: pid_t) {
        guard kill(pid, SIGSTOP) == 0 else { return }
        frozen.insert(pid)
        save()
        replace(pid, frozen: true)
    }

    func thaw(_ pid: pid_t) {
        kill(pid, SIGCONT)
        frozen.remove(pid)
        save()
        replace(pid, frozen: false)
    }

    /// Never leave anything paused behind: called at quit, and at launch in case TileDeck crashed.
    func thawAll() {
        for pid in frozen where Self.isStopped(pid) { kill(pid, SIGCONT) }
        frozen.removeAll()
        save()
    }

    private func replace(_ pid: pid_t, frozen: Bool) {
        guard let index = processes.firstIndex(where: { $0.id == pid }) else { return }
        let old = processes[index]
        processes[index] = ProcessUsage(id: pid, name: old.name, cpu: frozen ? 0 : old.cpu, isFrozen: frozen, canFreeze: old.canFreeze)
    }

    private func save() {
        UserDefaults.standard.set(Array(frozen), forKey: Self.frozenKey)
    }

    // MARK: Sampling

    nonisolated private static func sample(frozen: Set<pid_t>) -> [ProcessUsage] {
        let first = cpuTimes()
        let start = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: sampleInterval)
        let second = cpuTimes()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)

        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let ticksToNanos = Double(timebase.numer) / Double(timebase.denom)
        let me = getpid()

        var result: [ProcessUsage] = []
        for (pid, ticks) in second where pid != me {
            let isFrozen = isStopped(pid)
            let cpu = Double(ticks &- (first[pid] ?? ticks)) * ticksToNanos / elapsed * 100
            guard cpu >= 0.5 || (isFrozen && frozen.contains(pid)) else { continue }
            let name = processName(pid)
            result.append(ProcessUsage(id: pid, name: name, cpu: isFrozen ? 0 : cpu, isFrozen: isFrozen,
                                       canFreeze: !protectedNames.contains(name)))
        }
        // Frozen ones stay visible so they can be thawed.
        let frozenRows = result.filter(\.isFrozen)
        let busiest = result.filter { !$0.isFrozen }.sorted { $0.cpu > $1.cpu }.prefix(listLimit)
        return frozenRows + busiest
    }

    /// CPU time per process owned by this user; other users' processes can't be read or signalled anyway.
    nonisolated private static func cpuTimes() -> [pid_t: UInt64] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let uid = getuid()
        var times: [pid_t: UInt64] = [:]
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == uid else { continue }
            var task = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            times[pid] = task.pti_total_user + task.pti_total_system
        }
        return times
    }

    nonisolated private static func isStopped(_ pid: pid_t) -> Bool {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
        return bsd.pbi_status == UInt32(SSTOP)
    }

    nonisolated private static func processName(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            return (String(cString: path) as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 64)
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }
}
