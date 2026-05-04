import Combine
import Foundation

/// Holds the lifetime of `NotificationCenter` observer tokens and Combine
/// `AnyCancellable`s so a single owner can register many observations and
/// drop them all at once via `removeAll()` or `deinit`.
///
/// The host app and the extension both wire up several cross-cutting
/// observers (settings changes, profile activations, runtime tweaks).
/// Tracking each token in its own optional and remembering to remove it
/// in `deinit` is repetitive and easy to get wrong; this bag centralizes
/// the cleanup so a missed entry is impossible by construction.
public final class ObservationBag {
    private var tokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    public init() {}

    /// Registers a `NotificationCenter` observer token. The token is
    /// retained until `removeAll()` is called or the bag is deallocated.
    public func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    /// Stores a Combine subscription. Equivalent to `.store(in: &bag.set)`.
    public func add(_ cancellable: AnyCancellable) {
        cancellables.insert(cancellable)
    }

    /// Convenience for `cancellable.store(in: &bag)` ergonomics on a
    /// publisher chain. Keeps the call site flowing left-to-right.
    public func store(_ cancellable: AnyCancellable) {
        cancellables.insert(cancellable)
    }

    /// Drops every retained observation. Notification observers are
    /// removed from the default center; cancellables are released.
    public func removeAll() {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
        cancellables.removeAll()
    }

    deinit {
        // Token cleanup must run on dealloc so a forgotten `removeAll`
        // call doesn't leak observers across the process lifetime.
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
