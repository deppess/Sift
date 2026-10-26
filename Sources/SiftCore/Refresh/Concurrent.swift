import Foundation

/// Starts `work` on a global queue immediately; `value` blocks until it has finished.
final class Concurrent<Value: Sendable>: @unchecked Sendable {
    private let group = DispatchGroup()
    private var result: Value?

    init(_ work: @escaping @Sendable () -> Value) {
        group.enter()
        DispatchQueue.global().async {
            self.result = work()
            self.group.leave()
        }
    }

    var value: Value {
        group.wait()
        return result!
    }

    /// Waits for `work` without using its result.
    func wait() { group.wait() }
}

/// Fixed slots filled from `DispatchQueue.concurrentPerform`, each index written by exactly one
/// iteration and read only after it returns.
final class UnsafeResults<Value>: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Value?>

    init(count: Int) {
        storage = .allocate(capacity: count)
        storage.initialize(repeating: nil)
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    subscript(index: Int) -> Value? {
        get { storage[index] }
        set { storage[index] = newValue }
    }

    var values: [Value] { storage.map { $0! } }
}
