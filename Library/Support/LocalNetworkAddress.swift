import Darwin
import Foundation

/// Best-effort IPv4 address of the active LAN interface, used to build
/// the web editor URL shown to the user.
public enum LocalNetworkAddress {
    public static func ipv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard !ip.isEmpty, !ip.hasPrefix("169.254.") else { continue }
            let name: String
            if let rawName = pointer.pointee.ifa_name {
                name = Self.string(fromCString: rawName)
            } else {
                name = ""
            }
            if name == "en0" {
                return ip
            }
            if fallback == nil {
                fallback = ip
            }
        }
        return fallback
    }

    private static func string(fromCString pointer: UnsafePointer<CChar>) -> String {
        String(
            decoding: UnsafeBufferPointer(start: pointer, count: strlen(pointer))
                .map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
