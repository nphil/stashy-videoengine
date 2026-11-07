import Foundation
import os

/// Wakes threads blocked on content that a producer is still writing. A waiter takes a ticket before it
/// checks its condition, so a change that lands between the check and the wait still wakes it.
final class ChangeSignal: Sendable {
    private let waiters = OSAllocatedUnfairLock<[DispatchSemaphore]>(uncheckedState: [])

    func ticket() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        waiters.withLockUnchecked { $0.append(semaphore) }
        return semaphore
    }

    func withdraw(_ ticket: DispatchSemaphore) {
        waiters.withLockUnchecked { list in list.removeAll { $0 === ticket } }
    }

    func broadcast() {
        let woken = waiters.withLockUnchecked { list -> [DispatchSemaphore] in
            defer { list.removeAll() }
            return list
        }
        for semaphore in woken { semaphore.signal() }
    }
}
