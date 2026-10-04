import Foundation

/// A dictionary that keeps at most `capacity` entries, dropping the least recently used one when
/// a new entry would exceed it. Reads count as use. Small capacities only: recency is tracked
/// with a counter and eviction scans for the oldest entry.
public struct LRUCache<Key: Hashable, Value> {
    public let capacity: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// The value for `key`, marking it as just used.
    public mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.value, clock)
        return entry.value
    }
    /// The value for `key` without changing its recency.
    public func peek(_ key: Key) -> Value? { entries[key]?.value }
    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    public mutating func insert(_ value: Value, for key: Key) {
        clock += 1
        entries[key] = (value, clock)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries[oldest] = nil
        }
    }
    @discardableResult public mutating func removeValue(for key: Key) -> Value? { entries.removeValue(forKey: key)?.value }
    public mutating func removeAll() { entries.removeAll() }
}

/// Runs at most `limit` operations at once; the rest wait their turn.
///
/// A finishing operation hands its slot straight to a waiter — the count of running operations
/// never drops in between — so a new arrival cannot take the slot while the waiter is resuming.
/// A waiter whose task is cancelled leaves the queue and resumes exactly once, by throwing
/// `CancellationError`; one that already received a slot keeps it and runs.
///
/// `order` decides which waiter goes next. Rows of a thread ask for their media from the top
/// down, while the rows on screen are usually the newest ones at the bottom, so media decoding
/// serves the newest request first.
public actor AsyncLimiter {
    public enum Order: Sendable { case oldestFirst, newestFirst }

    public let limit: Int
    public let order: Order
    private var running = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0
    /// The most operations that ran at the same time (tests check it against `limit`).
    public private(set) var peak = 0
    public var runningCount: Int { running }
    public var waitingCount: Int { waiters.count }

    public init(limit: Int, order: Order = .oldestFirst) {
        self.limit = max(1, limit)
        self.order = order
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        if running < limit && waiters.isEmpty {
            running += 1
            peak = max(peak, running)
            return
        }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UInt64) {
        // Not found: the waiter already got its slot (or was never queued) and resumes normally.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        guard !waiters.isEmpty else { running -= 1; return }
        let next = order == .oldestFirst ? waiters.removeFirst() : waiters.removeLast()
        next.continuation.resume() // the slot passes over; `running` is unchanged
    }
}
