import Foundation

/// Tiny one-shot async signal used to await the bridge's disconnect.
actor AsyncOneShot {
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if fired { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    nonisolated func signal() {
        Task { await self._signal() }
    }

    private func _signal() {
        guard !fired else { return }
        fired = true
        for c in continuations { c.resume() }
        continuations.removeAll()
    }
}
