import Foundation
import os

/// Wakes requests that wait for content a producer is still writing. A waiter registers before it checks
/// its condition, so a change that lands between the check and the registration still wakes it. Each
/// registration runs at most once: at the next broadcast, or not at all once withdrawn.
final class ChangeSignal: Sendable {
    private struct State {
        var nextID = 0
        var waiters: [Int: @Sendable () -> Void] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Registers `wake` for the next broadcast and returns the id that withdraws it.
    func register(_ wake: @escaping @Sendable () -> Void) -> Int {
        state.withLock { state in
            state.nextID += 1
            state.waiters[state.nextID] = wake
            return state.nextID
        }
    }

    /// Removes a registration. False when a broadcast already took it, so its wake runs instead.
    func withdraw(_ id: Int) -> Bool {
        state.withLock { $0.waiters.removeValue(forKey: id) != nil }
    }

    func broadcast() {
        let woken = state.withLock { state -> [@Sendable () -> Void] in
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for wake in woken { wake() }
    }
}
