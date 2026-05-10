import Foundation
import os

/// Process memory pressure monitor shared by the host app and Network
/// Extension. It combines iOS memory-pressure dispatch events with a small
/// `os_proc_available_memory()` poll so callers can react before jetsam.
public final class MemoryMonitor: @unchecked Sendable {
    public enum Pressure: Int, Sendable, Comparable, CustomStringConvertible {
        case normal = 0
        case warning = 1
        case critical = 2

        public static func < (lhs: Pressure, rhs: Pressure) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var description: String {
            switch self {
            case .normal: return "normal"
            case .warning: return "warning"
            case .critical: return "critical"
            }
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let resident: Int
        public let available: Int
        public let pressure: Pressure

        public init(resident: Int, available: Int, pressure: Pressure) {
            self.resident = resident
            self.available = available
            self.pressure = pressure
        }

        /// Best-effort per-process budget. iOS exposes "available before
        /// jetsam" rather than the limit itself, so resident + available is
        /// the closest public estimate.
        public var estimatedLimit: Int {
            guard available > 0 else { return 0 }
            return resident + available
        }
    }

    public static let shared = MemoryMonitor()

    static let warningAvailableBytes = 6 * 1024 * 1024
    static let criticalAvailableBytes = 3 * 1024 * 1024

    private let queue = DispatchQueue(label: "io.proxycat.memory", qos: .utility)
    private let listenersLock = NSLock()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    private var listeners: [UUID: @Sendable (Snapshot) -> Void] = [:]
    private var lastEmittedPressure: Pressure?

    private init() {}

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            startPressureSourceIfNeeded()
            startPollTimerIfNeeded()
            emitIfNeeded()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            pressureSource?.cancel()
            pressureSource = nil
            pollTimer?.cancel()
            pollTimer = nil
            lastEmittedPressure = nil
        }
    }

    @discardableResult
    public func observe(_ block: @escaping @Sendable (Snapshot) -> Void) -> UUID {
        let id = UUID()
        listenersLock.lock()
        listeners[id] = block
        listenersLock.unlock()
        return id
    }

    public func remove(_ id: UUID) {
        listenersLock.lock()
        listeners[id] = nil
        listenersLock.unlock()
    }

    /// Current process memory snapshot. On platforms where
    /// `os_proc_available_memory()` is unavailable, `available` is 0 and
    /// pressure is `.normal`.
    public static func snapshot(systemPressure: Pressure? = nil) -> Snapshot {
        let resident = residentBytes()
        let available = availableBytes()
        let pressure = max(classify(availableBytes: available), systemPressure ?? .normal)
        return Snapshot(resident: resident, available: available, pressure: pressure)
    }

    static func classify(availableBytes: Int) -> Pressure {
        guard availableBytes > 0 else { return .normal }
        if availableBytes < criticalAvailableBytes {
            return .critical
        }
        if availableBytes < warningAvailableBytes {
            return .warning
        }
        return .normal
    }

    private func startPressureSourceIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            emitIfNeeded(systemPressure: Self.pressure(from: source.data), force: true)
        }
        source.resume()
        pressureSource = source
    }

    private func startPollTimerIfNeeded() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.emitIfNeeded()
        }
        timer.resume()
        pollTimer = timer
    }

    private static func pressure(from event: DispatchSource.MemoryPressureEvent) -> Pressure {
        if event.contains(.critical) {
            return .critical
        }
        if event.contains(.warning) {
            return .warning
        }
        return .normal
    }

    private func emitIfNeeded(systemPressure: Pressure? = nil, force: Bool = false) {
        let snapshot = Self.snapshot(systemPressure: systemPressure)
        let pressureChanged = snapshot.pressure != lastEmittedPressure
        let shouldEmit = force
            || (pressureChanged && (snapshot.pressure != .normal || lastEmittedPressure != nil))
        guard shouldEmit else { return }
        lastEmittedPressure = snapshot.pressure
        notify(snapshot)
    }

    private func notify(_ snapshot: Snapshot) {
        listenersLock.lock()
        let callbacks = Array(listeners.values)
        listenersLock.unlock()
        for callback in callbacks {
            callback(snapshot)
        }
    }

    /// Bytes still available to this process before the kernel kills it.
    /// Wraps `os_proc_available_memory()` on Apple mobile platforms and
    /// returns 0 elsewhere so callers can stay platform-agnostic.
    public static func availableBytes() -> Int {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return os_proc_available_memory()
        #else
        return 0
        #endif
    }

    /// Bytes the kernel currently bills against this process. This is
    /// `task_vm_info.phys_footprint`, the same value jetsam compares
    /// against the per-process limit.
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
}
