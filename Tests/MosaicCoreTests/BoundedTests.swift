import XCTest
@testable import MosaicCore

final class BoundedTests: XCTestCase {
    func testLeastRecentlyUsedEntryLeavesFirst() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1) // "a" is now the most recent
        cache.insert(3, for: "c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.peek("b"))
        XCTAssertEqual(cache.peek("a"), 1)
        XCTAssertEqual(cache.peek("c"), 3)
        cache.insert(4, for: "a") // replacing keeps the count
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.removeValue(for: "a"), 4)
        XCTAssertFalse(cache.contains("a"))
    }

    /// However requests interleave, no more than the limit run at once, and every one finishes.
    func testLimiterNeverExceedsItsLimit() async throws {
        let limiter = AsyncLimiter(limit: 3)
        let gauge = Gauge()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await limiter.run {
                        await gauge.enter()
                        try await Task.sleep(for: .milliseconds(index % 3 == 0 ? 2 : 6))
                        await gauge.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await limiter.peak
        let observed = await gauge.peak
        let finished = await gauge.finished
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertLessThanOrEqual(observed, 3)
        XCTAssertEqual(finished, 40)
        let running = await limiter.runningCount
        let waiting = await limiter.waitingCount
        XCTAssertEqual(running, 0)
        XCTAssertEqual(waiting, 0)
    }

    /// A waiter cancelled while queued resumes once, by throwing, and gives back no slot it never
    /// had; the slot holder's release then lets the next request in.
    func testCancelledWaiterResumesExactlyOnce() async throws {
        let limiter = AsyncLimiter(limit: 1)
        let gate = Gate()
        let holder = Task { try await limiter.run { await gate.wait() } }
        while await limiter.runningCount == 0 { await Task.yield() }
        let waiter = Task { () -> String in
            do { _ = try await limiter.run { "ran" }; return "ran" } catch is CancellationError { return "cancelled" }
        }
        while await limiter.waitingCount == 0 { await Task.yield() }
        waiter.cancel()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, "cancelled")
        let waitingAfterCancel = await limiter.waitingCount
        XCTAssertEqual(waitingAfterCancel, 0)
        await gate.open()
        try await holder.value
        let running = await limiter.runningCount
        XCTAssertEqual(running, 0)
        let after = try await limiter.run { 42 }
        XCTAssertEqual(after, 42)
    }

    /// The finishing request hands its slot to the oldest waiter (or the newest, when asked),
    /// so waiters run in the chosen order and a newcomer never jumps ahead.
    func testSlotPassesToTheWaiterInOrder() async throws {
        for order in [AsyncLimiter.Order.oldestFirst, .newestFirst] {
            let limiter = AsyncLimiter(limit: 1, order: order)
            let gate = Gate()
            let log = Log()
            let holder = Task { try await limiter.run { await gate.wait() } }
            while await limiter.runningCount == 0 { await Task.yield() }
            var waiters: [Task<Void, Error>] = []
            for index in 0..<3 {
                waiters.append(Task { try await limiter.run { await log.append(index) } })
                while await limiter.waitingCount < index + 1 { await Task.yield() }
            }
            await gate.open()
            try await holder.value
            for waiter in waiters { try await waiter.value }
            let entries = await log.entries
            XCTAssertEqual(entries, order == .oldestFirst ? [0, 1, 2] : [2, 1, 0])
        }
    }
}

private actor Gauge {
    private var current = 0
    private(set) var peak = 0
    private(set) var finished = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1; finished += 1 }
}

private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

private actor Log {
    private(set) var entries: [Int] = []
    func append(_ value: Int) { entries.append(value) }
}
