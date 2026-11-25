import Foundation
import ObjectiveC.runtime

/// Key-value coding lookups that cannot trap.
///
/// `NSObject.value(forKeyPath:)` raises an uncatchable
/// `NSUnknownKeyException` when a segment does not resolve. Code that
/// probes private, version-dependent properties — such as the packet
/// flow's TUN socket — must check resolvability first, so a renamed or
/// missing key falls through to a fallback instead of killing the process.
public enum SafeKVC {
    /// Resolves `keyPath` one segment at a time, returning nil as soon as
    /// a segment has no accessor/ivar or evaluates to nil.
    public static func value(forKeyPath keyPath: String, on object: NSObject) -> Any? {
        var current: Any = object
        for segment in keyPath.split(separator: ".") {
            let key = String(segment)
            guard let node = current as? NSObject,
                  isResolvable(key, on: node)
            else { return nil }
            guard let next = node.value(forKey: key) else { return nil }
            current = next
        }
        return current
    }

    /// Mirrors KVC's resolution order: accessor methods
    /// (`get<Key>`/`<key>`/`is<Key>`/`_get<Key>`/`_<key>`), then — when
    /// the class allows direct ivar access — `_<key>`, `_is<Key>`,
    /// `<key>`, `is<Key>`.
    static func isResolvable(_ key: String, on object: NSObject) -> Bool {
        let capitalized = key.prefix(1).uppercased() + String(key.dropFirst())
        let accessorNames = [
            key,
            "get\(capitalized)",
            "is\(capitalized)",
            "_get\(capitalized)",
            "_\(key)",
        ]
        if accessorNames.contains(where: { object.responds(to: NSSelectorFromString($0)) }) {
            return true
        }
        guard object.classForCoder.accessInstanceVariablesDirectly else { return false }
        let ivarNames = ["_\(key)", "_is\(capitalized)", key, "is\(capitalized)"]
        return ivarNames.contains {
            class_getInstanceVariable(object.classForCoder, $0) != nil
        }
    }
}
