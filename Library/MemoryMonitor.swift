import Foundation
import os

/// Tracks the Network Extension's memory budget and broadcasts pressure
/// events. The NE process has a hard cap (~15MB historically, ~50MB on
/// recent iOS, but not officially documented and varies per device). We do
/// NOT hardcode a number — we react to:
///   • `os_proc_available_memory()` shrinking
///   • `DispatchSource` memory-pressure warnings/critical events
///
/// Subscribers can drop caches, flush logs, or close idle connections.
public final class MemoryMonitor: @unchecked Sendable {
    public enum Pressure: Sendable {
        case normal
        case warning
        case critical
    }

    public static let shared = MemoryMonitor()

    private let queue = DispatchQueue(label: "io.proxycat.memory", qos: .utility)
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    private var listeners: [UUID: (Pressure) -> Void] = [:]
    private let lock = NSLock()

    private init() {}

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if pressureSource == nil {
                let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
                src.setEventHandler { [weak self] in
                    guard let self else { return }
                    let event = src.data
                    let pressure: Pressure
                    if event.contains(.critical) {
                        pressure = .critical
                    } else if event.contains(.warning) {
                        pressure = .warning
                    } else {
                        pressure = .normal
                    }
                    notify(pressure)
                }
                src.resume()
                pressureSource = src
            }

            // Poll available memory every 2s as a backstop. If it drops
            // below 3MB we synthesize a .critical even if iOS hasn't fired.
            if pollTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 2, repeating: 2)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let avail = Self.availableBytes()
                    if avail > 0, avail < 3 * 1024 * 1024 {
                        notify(.critical)
                    } else if avail > 0, avail < 6 * 1024 * 1024 {
                        notify(.warning)
                    }
                }
                timer.resume()
                pollTimer = timer
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.pressureSource?.cancel()
            self?.pressureSource = nil
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
        }
    }

    @discardableResult
    public func observe(_ block: @escaping @Sendable (Pressure) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners[id] = block
        lock.unlock()
        return id
    }

    public func remove(_ id: UUID) {
        lock.lock()
        listeners[id] = nil
        lock.unlock()
    }

    private func notify(_ pressure: Pressure) {
        lock.lock()
        let snapshot = Array(listeners.values)
        lock.unlock()
        for cb in snapshot { cb(pressure) }
    }

    /// Bytes still available to this process before the kernel kills it.
    /// Wraps `os_proc_available_memory()` (iOS 13+). Returns 0 on platforms
    /// where the call is unavailable.
    public static func availableBytes() -> Int {
        #if os(iOS) || os(tvOS) || os(watchOS)
        if #available(iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            return os_proc_available_memory()
        }
        #endif
        return 0
    }

    /// Bytes the kernel currently bills against this process. This is
    /// `task_vm_info.phys_footprint` — the same number jetsam compares
    /// against the per-process limit. sing-box-for-apple uses the same
    /// field for its status memory display.
    ///
    /// Returns 0 on failure (e.g. kernel call denied in a sandboxed
    /// configuration we don't expect to hit on iOS).
    public static func residentBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Int(info.phys_footprint)
        }
        return 0
    }

    /// Snapshot of both numbers, captured atomically.
    public static func snapshot() -> MemoryStats {
        MemoryStats(resident: residentBytes(), available: availableBytes())
    }
}
