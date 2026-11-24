import Darwin
import Foundation
import Library
import NetworkExtension

/// Locates the file descriptor backing the iOS packet flow.
///
/// `NEPacketTunnelFlow` doesn't expose this publicly. We try the KVC
/// key paths used by different iOS releases, then fall back to
/// enumerating the process's descriptors and picking the utun control
/// socket — the same trick libbox uses for sing-box.
enum TunnelFileDescriptor {
    static func locate(in packetFlow: NEPacketTunnelFlow, logger: ProxyCatLogger) -> Int32 {
        let candidates = [
            "socket.fileDescriptor",
            "_socket.fileDescriptor",
            "socket._fileDescriptor",
            "_socket._fileDescriptor",
        ]
        for keyPath in candidates {
            // KVC may surface the fd as either a boxed NSNumber or as a
            // raw Int32 depending on the iOS runtime; accept both.
            let raw = packetFlow.value(forKeyPath: keyPath)
            let fd = (raw as? NSNumber)?.int32Value ?? (raw as? Int32) ?? 0
            if fd > 0 {
                logger.info("found tun fd via KVC \(keyPath) = \(fd)")
                return fd
            }
        }

        if let fd = findUtunFD() {
            logger.info("found tun fd by enumeration = \(fd)")
            return fd
        }

        let className = String(describing: type(of: packetFlow))
        logger.error("KVC and FD enumeration both failed; packetFlow class=\(className)")
        return -1
    }

    /// Returns the fd of the utun control socket created by
    /// `setTunnelNetworkSettings`, or nil if none is found. We manually
    /// decode `sockaddr_ctl` because `<sys/kern_control.h>` isn't part
    /// of Swift's Darwin module on iOS.
    private static func findUtunFD() -> Int32? {
        let kAF_SYSTEM: UInt8 = 32
        let kAF_SYS_CONTROL: UInt16 = 2
        let limit = Int32(getdtablesize())
        var storage = sockaddr_storage()
        for fd in 0 ..< limit {
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let result = withUnsafeMutablePointer(to: &storage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    getpeername(fd, saPtr, &len)
                }
            }
            guard result == 0 else { continue }
            let scFamily: UInt8 = withUnsafeBytes(of: storage) { raw in raw[1] }
            guard scFamily == kAF_SYSTEM else { continue }
            let ssSysaddr: UInt16 = withUnsafeBytes(of: storage) { raw in
                raw.load(fromByteOffset: 2, as: UInt16.self)
            }
            if ssSysaddr == kAF_SYS_CONTROL {
                return fd
            }
        }
        return nil
    }
}
