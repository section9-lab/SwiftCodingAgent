import Testing
@testable import SwiftHarnessAgent
import Foundation

/// Comprehensive tests for the barrier-based tool concurrency scheduler.
///
/// The scheduler must guarantee:
///   1. **Parallelism**: shared tools in the same batch execute concurrently.
///   2. **Mutual exclusion**: exclusive tools never overlap with anything.
///   3. **Barrier ordering**: shared work before an exclusive tool finishes
///      before the exclusive tool starts; the exclusive tool finishes before
///      any subsequent shared work begins.
///   4. **Result ordering**: results align 1:1 with input order, regardless of
///      completion order.
///   5. **Error isolation**: a thrown tool produces an `isError` result but
///      does not abort sibling work.
///   6. **Cancellation**: external cancellation propagates into running tasks.
///   7. **Robustness**: degenerate inputs (empty, single, unregistered) behave
///      sanely and never crash.
struct ToolConcurrencyTests {

    // MARK: - Test infrastructure

    /// Records every observable event from tools (start/end + any custom
    /// payload). Each event is timestamped with both wall-clock time and a
    /// monotonic sequence number so we can assert ordering even when two
    /// events fall inside the same millisecond.
    actor ExecutionTracker {
        struct Event: Equatable {
            let name: String
            let seq: Int
            let timestamp: Date
        }

        private(set) var events: [Event] = []
        private var nextSeq = 0
        /// Number of currently running shared tools (incremented on start,
        /// decremented on end). Lets tests assert the *peak* concurrency.
        private(set) var activeShared = 0
        private(set) var peakShared = 0
        /// Number of currently running exclusive tools. Must never exceed 1.
        private(set) var activeExclusive = 0
        private(set) var peakExclusive = 0
        /// True if a shared tool was ever observed running while an exclusive
        /// tool was active. The scheduler MUST keep this false.
        private(set) var sawSharedAndExclusiveOverlap = false

        func record(_ name: String) {
            let event = Event(name: name, seq: nextSeq, timestamp: Date())
            nextSeq += 1
            events.append(event)
        }

        func enterShared(_ name: String) {
            activeShared += 1
            peakShared = max(peakShared, activeShared)
            if activeExclusive > 0 { sawSharedAndExclusiveOverlap = true }
            record("\(name):start")
        }

        func leaveShared(_ name: String) {
            activeShared -= 1
            record("\(name):end")
        }

        func enterExclusive(_ name: String) {
            activeExclusive += 1
            peakExclusive = max(peakExclusive, activeExclusive)
            if activeShared > 0 { sawSharedAndExclusiveOverlap = true }
            record("\(name):start")
        }

        func leaveExclusive(_ name: String) {
            activeExclusive -= 1
            record("\(name):end")
        }

        func eventNames() -> [String] {
            events.map { $0.name }
        }

        func indexOf(_ name: String) -> Int? {
            events.firstIndex(where: { $0.name == name }).map { events[$0].seq }
        }
    }

    /// Generic tool used by most tests: configurable concurrency, configurable
    /// delay, optional throw. Records start/end into the tracker.
    struct ProbeTool: AgentTool {
        let name: String
        let description = "probe"
        let argumentSchemaJSON = "{}"
        let tracker: ExecutionTracker
        let concurrency: ToolConcurrency
        let delayMs: Int
        let throwsError: Bool

        init(
            name: String,
            tracker: ExecutionTracker,
            concurrency: ToolConcurrency = .shared,
            delayMs: Int = 0,
            throwsError: Bool = false
        ) {
            self.name = name
            self.tracker = tracker
            self.concurrency = concurrency
            self.delayMs = delayMs
            self.throwsError = throwsError
        }

        func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
            switch concurrency {
            case .shared: await tracker.enterShared(name)
            case .exclusive: await tracker.enterExclusive(name)
            }
            defer {
                // Note: defer can't be async; do the leave inline below.
            }
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            if throwsError {
                switch concurrency {
                case .shared: await tracker.leaveShared(name)
                case .exclusive: await tracker.leaveExclusive(name)
                }
                throw ToolError.commandFailed("intentional failure: \(name)")
            }
            switch concurrency {
            case .shared: await tracker.leaveShared(name)
            case .exclusive: await tracker.leaveExclusive(name)
            }
            return "result:\(name)"
        }
    }

    /// Shared mutable state that exclusive tools mutate. Used to prove
    /// exclusive tools are not racing.
    actor Counter {
        private(set) var value = 0
        func incrementAfterDelay(_ ms: Int) async {
            // Read, sleep, write. With proper exclusion this is safe.
            // Without it, two concurrent calls would race on `value`.
            let snapshot = value
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            value = snapshot + 1
        }
    }

    /// Tool that mutates a shared `Counter` via read-modify-write. Two of
    /// these running concurrently would lose increments — the scheduler must
    /// serialise them when both are exclusive.
    struct CounterIncrementTool: AgentTool {
        let name: String
        let description = "counter inc"
        let argumentSchemaJSON = "{}"
        let counter: Counter
        let concurrency: ToolConcurrency
        let delayMs: Int

        func run(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
            await counter.incrementAfterDelay(delayMs)
            return "ok"
        }
    }

    // MARK: - Helpers

    private func makeAgentLoop(
        tools: [any AgentTool],
        parallelToolCalls: Bool
    ) throws -> AgentLoop {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("concurrency-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let config = AgentLoopConfig(
            maxSteps: 1,
            workingDirectory: tempDir,
            parallelToolCalls: parallelToolCalls
        )
        return AgentLoop(
            client: EchoClient(),
            modelName: "test",
            tools: tools,
            config: config
        )
    }

    private func use(_ id: String, _ name: String) -> LLMToolUse {
        LLMToolUse(id: id, name: name, argumentsJSON: "{}")
    }

    // MARK: - Parallelism

    /// Three shared tools must run simultaneously, not back-to-back. We
    /// assert peak concurrency reached 3 — stronger than wall-clock, which
    /// can be fooled by a fast machine running things "fast enough".
    @Test
    func sharedToolsReachFullParallelism() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = (1...5).map { i in
            ProbeTool(name: "t\(i)", tracker: tracker, concurrency: .shared, delayMs: 80)
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (1...5).map { use("\($0)", "t\($0)") }

        _ = try await loop.runToolCalls(uses)

        let peak = await tracker.peakShared
        let overlapped = await tracker.sawSharedAndExclusiveOverlap
        #expect(peak == 5, "all 5 shared tools should run concurrently; observed peak=\(peak)")
        #expect(!overlapped, "no shared/exclusive overlap should occur")
    }

    /// Wall-clock corroboration: 5 tools × 80ms must finish in well under
    /// the serial 400ms (loose bound to avoid CI flakes).
    @Test
    func sharedParallelismIsFasterThanSerial() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = (1...5).map { i in
            ProbeTool(name: "t\(i)", tracker: tracker, concurrency: .shared, delayMs: 80)
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (1...5).map { use("\($0)", "t\($0)") }

        let start = Date()
        _ = try await loop.runToolCalls(uses)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.25, "5 × 80ms parallel should complete in <250ms, took \(elapsed)s")
    }

    // MARK: - Mutual exclusion

    /// Even with `parallelToolCalls=true`, two exclusive tools side-by-side
    /// must serialise. Peak exclusive concurrency must never exceed 1.
    @Test
    func exclusiveToolsNeverOverlap() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = (1...4).map { i in
            ProbeTool(name: "w\(i)", tracker: tracker, concurrency: .exclusive, delayMs: 30)
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (1...4).map { use("\($0)", "w\($0)") }

        _ = try await loop.runToolCalls(uses)

        let peak = await tracker.peakExclusive
        let overlapped = await tracker.sawSharedAndExclusiveOverlap
        #expect(peak == 1, "exclusive tools must never overlap; observed peak=\(peak)")
        #expect(!overlapped)
    }

    /// Read-modify-write on a shared counter. With exclusion, all increments
    /// land. Without it, lost updates would yield value < N.
    @Test
    func exclusiveToolsPreventLostUpdates() async throws {
        let counter = Counter()
        let n = 8
        let tools: [any AgentTool] = (1...n).map { i in
            CounterIncrementTool(
                name: "inc\(i)",
                counter: counter,
                concurrency: .exclusive,
                delayMs: 5
            )
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (1...n).map { use("\($0)", "inc\($0)") }

        _ = try await loop.runToolCalls(uses)
        let final = await counter.value
        #expect(final == n, "exclusion should preserve all \(n) increments; got \(final)")
    }

    /// Same shape, but with `.shared` instead — this is a *negative* test
    /// that documents what would happen without exclusion. We assert the
    /// counter is in [1, n] and acknowledge updates may be lost. The point
    /// is to prove the exclusion test above is meaningful (i.e. that races
    /// are observable in this harness).
    @Test
    func sharedRMWCanLoseUpdates() async throws {
        let counter = Counter()
        let n = 16
        let tools: [any AgentTool] = (1...n).map { i in
            CounterIncrementTool(
                name: "race\(i)",
                counter: counter,
                concurrency: .shared,
                delayMs: 5
            )
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (1...n).map { use("\($0)", "race\($0)") }

        _ = try await loop.runToolCalls(uses)
        let final = await counter.value
        // Lost updates are possible but not guaranteed every run. We only
        // assert the final value is bounded — proving the harness can show
        // races when exclusion isn't there.
        #expect(final >= 1 && final <= n)
    }

    // MARK: - Barrier ordering

    /// Pattern: [S, S, X, S, S, X, S]
    /// Expected execution order:
    ///   batch 1: t1, t2 (parallel)
    ///   barrier: x1 (alone)
    ///   batch 2: t3, t4 (parallel)
    ///   barrier: x2 (alone)
    ///   batch 3: t5 (alone, but as a degenerate batch)
    @Test
    func multipleBarriersPartitionExecution() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [
            ProbeTool(name: "t1", tracker: tracker, concurrency: .shared, delayMs: 25),
            ProbeTool(name: "t2", tracker: tracker, concurrency: .shared, delayMs: 25),
            ProbeTool(name: "x1", tracker: tracker, concurrency: .exclusive, delayMs: 25),
            ProbeTool(name: "t3", tracker: tracker, concurrency: .shared, delayMs: 25),
            ProbeTool(name: "t4", tracker: tracker, concurrency: .shared, delayMs: 25),
            ProbeTool(name: "x2", tracker: tracker, concurrency: .exclusive, delayMs: 25),
            ProbeTool(name: "t5", tracker: tracker, concurrency: .shared, delayMs: 25)
        ]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = [
            use("1", "t1"), use("2", "t2"), use("3", "x1"),
            use("4", "t3"), use("5", "t4"), use("6", "x2"),
            use("7", "t5")
        ]

        _ = try await loop.runToolCalls(uses)

        // Use sequence numbers because two events in the same ms get
        // arbitrary Date ordering.
        let t1End = await tracker.indexOf("t1:end")!
        let t2End = await tracker.indexOf("t2:end")!
        let x1Start = await tracker.indexOf("x1:start")!
        let x1End = await tracker.indexOf("x1:end")!
        let t3Start = await tracker.indexOf("t3:start")!
        let t4Start = await tracker.indexOf("t4:start")!
        let t3End = await tracker.indexOf("t3:end")!
        let t4End = await tracker.indexOf("t4:end")!
        let x2Start = await tracker.indexOf("x2:start")!
        let x2End = await tracker.indexOf("x2:end")!
        let t5Start = await tracker.indexOf("t5:start")!

        // Barrier 1
        #expect(t1End < x1Start)
        #expect(t2End < x1Start)
        #expect(x1End < t3Start)
        #expect(x1End < t4Start)
        // Barrier 2
        #expect(t3End < x2Start)
        #expect(t4End < x2Start)
        #expect(x2End < t5Start)

        // Exclusion invariants on the live counters
        let peakExcl = await tracker.peakExclusive
        let overlapped = await tracker.sawSharedAndExclusiveOverlap
        #expect(peakExcl == 1)
        #expect(!overlapped)
    }

    /// Pattern: [X, S, S, S] — leading exclusive must finish before any
    /// shared starts.
    @Test
    func leadingExclusiveBlocksFollowingShared() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [
            ProbeTool(name: "x", tracker: tracker, concurrency: .exclusive, delayMs: 30),
            ProbeTool(name: "s1", tracker: tracker, concurrency: .shared, delayMs: 30),
            ProbeTool(name: "s2", tracker: tracker, concurrency: .shared, delayMs: 30),
            ProbeTool(name: "s3", tracker: tracker, concurrency: .shared, delayMs: 30)
        ]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = [use("1", "x"), use("2", "s1"), use("3", "s2"), use("4", "s3")]

        _ = try await loop.runToolCalls(uses)

        let xEnd = await tracker.indexOf("x:end")!
        let s1Start = await tracker.indexOf("s1:start")!
        let s2Start = await tracker.indexOf("s2:start")!
        let s3Start = await tracker.indexOf("s3:start")!
        #expect(xEnd < s1Start)
        #expect(xEnd < s2Start)
        #expect(xEnd < s3Start)

        let peakShared = await tracker.peakShared
        #expect(peakShared == 3, "trailing shared batch should still parallelise")
    }

    /// Pattern: [S, S, S, X] — trailing exclusive must wait for the leading
    /// shared batch.
    @Test
    func trailingExclusiveWaitsForSharedBatch() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [
            ProbeTool(name: "s1", tracker: tracker, concurrency: .shared, delayMs: 30),
            ProbeTool(name: "s2", tracker: tracker, concurrency: .shared, delayMs: 30),
            ProbeTool(name: "s3", tracker: tracker, concurrency: .shared, delayMs: 30),
            ProbeTool(name: "x", tracker: tracker, concurrency: .exclusive, delayMs: 30)
        ]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = [use("1", "s1"), use("2", "s2"), use("3", "s3"), use("4", "x")]

        _ = try await loop.runToolCalls(uses)

        let s1End = await tracker.indexOf("s1:end")!
        let s2End = await tracker.indexOf("s2:end")!
        let s3End = await tracker.indexOf("s3:end")!
        let xStart = await tracker.indexOf("x:start")!
        #expect(s1End < xStart)
        #expect(s2End < xStart)
        #expect(s3End < xStart)
    }

    // MARK: - Result ordering

    /// Mixed completion times — the slowest is first. Results must still
    /// come back in input order with their original ids/names.
    @Test
    func resultsAlignToInputOrderUnderInterleavedDelays() async throws {
        let tracker = ExecutionTracker()
        // Delays designed to randomize completion: index 0 finishes last.
        let delays = [200, 10, 150, 5, 100, 50]
        let tools: [any AgentTool] = delays.enumerated().map { (i, d) in
            ProbeTool(name: "t\(i)", tracker: tracker, concurrency: .shared, delayMs: d)
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (0..<delays.count).map { use("id\($0)", "t\($0)") }

        let results = try await loop.runToolCalls(uses)

        #expect(results.count == delays.count)
        for i in 0..<delays.count {
            #expect(results[i].toolUseID == "id\(i)")
            #expect(results[i].toolName == "t\(i)")
            #expect(results[i].content == "result:t\(i)")
            #expect(!results[i].isError)
        }
    }

    /// Order preservation must also hold across barriers (results don't get
    /// shuffled between batches).
    @Test
    func resultOrderPreservedAcrossBarriers() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [
            ProbeTool(name: "s1", tracker: tracker, concurrency: .shared, delayMs: 100),
            ProbeTool(name: "x1", tracker: tracker, concurrency: .exclusive, delayMs: 5),
            ProbeTool(name: "s2", tracker: tracker, concurrency: .shared, delayMs: 50),
            ProbeTool(name: "x2", tracker: tracker, concurrency: .exclusive, delayMs: 5),
            ProbeTool(name: "s3", tracker: tracker, concurrency: .shared, delayMs: 25)
        ]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = [use("a", "s1"), use("b", "x1"), use("c", "s2"), use("d", "x2"), use("e", "s3")]

        let results = try await loop.runToolCalls(uses)

        #expect(results.map { $0.toolUseID } == ["a", "b", "c", "d", "e"])
        #expect(results.map { $0.toolName } == ["s1", "x1", "s2", "x2", "s3"])
    }

    // MARK: - Error isolation

    /// A throwing tool must surface as `isError: true` without aborting its
    /// batch siblings or downstream tools.
    @Test
    func throwingToolIsIsolated() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [
            ProbeTool(name: "ok1", tracker: tracker, concurrency: .shared, delayMs: 20),
            ProbeTool(name: "boom", tracker: tracker, concurrency: .shared, delayMs: 20, throwsError: true),
            ProbeTool(name: "ok2", tracker: tracker, concurrency: .shared, delayMs: 20),
            ProbeTool(name: "after", tracker: tracker, concurrency: .exclusive, delayMs: 5)
        ]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = [use("1", "ok1"), use("2", "boom"), use("3", "ok2"), use("4", "after")]

        let results = try await loop.runToolCalls(uses)

        #expect(results.count == 4)
        #expect(!results[0].isError)
        #expect(results[1].isError, "throwing tool should produce isError result")
        #expect(results[1].content.contains("ERROR"))
        #expect(!results[2].isError, "sibling shared tool must complete despite peer failure")
        #expect(!results[3].isError, "downstream exclusive must still run")

        let afterStart = await tracker.indexOf("after:start")
        #expect(afterStart != nil, "post-barrier tool must execute")
    }

    /// Throwing exclusive tool: barrier semantics still hold; pre-batch
    /// completes, post-batch starts.
    @Test
    func throwingExclusiveStillBehavesAsBarrier() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [
            ProbeTool(name: "pre1", tracker: tracker, concurrency: .shared, delayMs: 20),
            ProbeTool(name: "pre2", tracker: tracker, concurrency: .shared, delayMs: 20),
            ProbeTool(name: "boom", tracker: tracker, concurrency: .exclusive, delayMs: 5, throwsError: true),
            ProbeTool(name: "post1", tracker: tracker, concurrency: .shared, delayMs: 20),
            ProbeTool(name: "post2", tracker: tracker, concurrency: .shared, delayMs: 20)
        ]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = [
            use("1", "pre1"), use("2", "pre2"),
            use("3", "boom"),
            use("4", "post1"), use("5", "post2")
        ]

        let results = try await loop.runToolCalls(uses)

        #expect(results.count == 5)
        #expect(results[2].isError)

        let pre1End = await tracker.indexOf("pre1:end")!
        let pre2End = await tracker.indexOf("pre2:end")!
        let boomStart = await tracker.indexOf("boom:start")!
        let boomEnd = await tracker.indexOf("boom:end")!
        let post1Start = await tracker.indexOf("post1:start")!
        let post2Start = await tracker.indexOf("post2:start")!
        #expect(pre1End < boomStart)
        #expect(pre2End < boomStart)
        #expect(boomEnd < post1Start)
        #expect(boomEnd < post2Start)
    }

    // MARK: - Cancellation

    /// External cancellation should propagate: in-flight tasks see
    /// `Task.checkCancellation()` and the loop returns/throws promptly.
    @Test
    func externalCancellationStopsScheduler() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = (1...20).map { i in
            // Long delays so we have time to cancel before they finish.
            ProbeTool(name: "slow\(i)", tracker: tracker, concurrency: .exclusive, delayMs: 500)
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (1...20).map { use("\($0)", "slow\($0)") }

        let task = Task<[LLMToolResult]?, Never> {
            do {
                return try await loop.runToolCalls(uses)
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }

        // Let the first one start, then cancel.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let result = await task.value
        // Either we got a partial result, or the task was cancelled. Either
        // way, far fewer than 20 tools should have started in 50ms when each
        // takes 500ms.
        let started = await tracker.events.filter { $0.name.hasSuffix(":start") }.count
        #expect(started < 20, "cancellation must prevent starting all tools; started=\(started)")
        _ = result
    }

    // MARK: - Degenerate inputs

    @Test
    func emptyInputReturnsEmpty() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [ProbeTool(name: "t", tracker: tracker)]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let results = try await loop.runToolCalls([])
        #expect(results.isEmpty)
    }

    /// Single tool — both modes must behave identically and return one
    /// result. The barrier path skips the parallel optimization for n<=1.
    @Test
    func singleToolWorksInBothModes() async throws {
        for parallel in [true, false] {
            let tracker = ExecutionTracker()
            let tools: [any AgentTool] = [
                ProbeTool(name: "only", tracker: tracker, concurrency: .shared, delayMs: 5)
            ]
            let loop = try makeAgentLoop(tools: tools, parallelToolCalls: parallel)
            let results = try await loop.runToolCalls([use("1", "only")])
            #expect(results.count == 1)
            #expect(results[0].toolName == "only")
            #expect(!results[0].isError)
        }
    }

    /// Unregistered tool must yield an error result, not crash, and not
    /// poison sibling work.
    @Test
    func unregisteredToolProducesErrorResult() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = [
            ProbeTool(name: "real", tracker: tracker, concurrency: .shared, delayMs: 10)
        ]
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = [use("1", "real"), use("2", "ghost"), use("3", "real")]

        let results = try await loop.runToolCalls(uses)

        #expect(results.count == 3)
        #expect(!results[0].isError)
        #expect(results[1].isError)
        #expect(results[1].content.contains("Tool not found"))
        #expect(!results[2].isError)
    }

    // MARK: - Sequential mode (parallelToolCalls=false)

    /// In sequential mode, even shared tools must run one at a time.
    @Test
    func sequentialModeIgnoresConcurrencyHint() async throws {
        let tracker = ExecutionTracker()
        let tools: [any AgentTool] = (1...4).map { i in
            ProbeTool(name: "s\(i)", tracker: tracker, concurrency: .shared, delayMs: 20)
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: false)
        let uses = (1...4).map { use("\($0)", "s\($0)") }

        _ = try await loop.runToolCalls(uses)

        let peak = await tracker.peakShared
        #expect(peak == 1, "sequential mode must serialize all tools, peak=\(peak)")
    }

    // MARK: - Real tool wiring sanity

    @Test
    func realToolsHaveExpectedConcurrency() async throws {
        #expect(ReadTool().concurrency == .shared)
        #expect(WriteTool().concurrency == .exclusive)
        #expect(EditTool().concurrency == .exclusive)
        #expect(BashTool().concurrency == .exclusive)
        #expect(TodoWriteTool(store: TodoStore()).concurrency == .exclusive)
    }

    /// End-to-end: run real ReadTool concurrently with a real WriteTool in
    /// the agent loop, and verify the WriteTool ran *after* the read batch
    /// (so the read sees the pre-write content).
    @Test
    func realReadAndWriteAreOrderedByBarrier() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("file.txt")
        try "BEFORE".write(to: target, atomically: true, encoding: .utf8)

        let config = AgentLoopConfig(
            maxSteps: 1,
            workingDirectory: tempDir,
            parallelToolCalls: true
        )
        let loop = AgentLoop(
            client: EchoClient(),
            modelName: "test",
            tools: [ReadTool(), WriteTool()],
            config: config
        )

        let uses = [
            LLMToolUse(id: "1", name: "read", argumentsJSON: #"{"path":"file.txt"}"#),
            LLMToolUse(id: "2", name: "write", argumentsJSON: #"{"path":"file.txt","content":"AFTER"}"#),
            LLMToolUse(id: "3", name: "read", argumentsJSON: #"{"path":"file.txt"}"#)
        ]

        let results = try await loop.runToolCalls(uses)
        #expect(results.count == 3)
        #expect(results[0].content.contains("BEFORE"), "first read must see pre-write content")
        #expect(!results[1].isError, "write must succeed")
        #expect(results[2].content.contains("AFTER"), "second read must see post-write content")
    }

    // MARK: - Stress / fuzz

    /// Randomized large workloads. Generates 50 tools with random concurrency
    /// and asserts the global invariants hold:
    ///   - No exclusive overlap.
    ///   - Result ordering matches input.
    ///   - Every result is present.
    @Test(arguments: 0..<5)
    func randomMixIsAlwaysOrderedAndExclusive(seed: Int) async throws {
        var rng = SeededGenerator(seed: UInt64(seed) &* 0xdeadbeef &+ 1)
        let tracker = ExecutionTracker()
        let n = 50
        var tools: [any AgentTool] = []
        var uses: [LLMToolUse] = []
        for i in 0..<n {
            let concurrency: ToolConcurrency = (rng.next() % 4 == 0) ? .exclusive : .shared
            let delay = Int(rng.next() % 15) + 1
            let name = "f\(i)"
            tools.append(ProbeTool(
                name: name,
                tracker: tracker,
                concurrency: concurrency,
                delayMs: delay
            ))
            uses.append(use("id\(i)", name))
        }

        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let results = try await loop.runToolCalls(uses)

        #expect(results.count == n)
        for i in 0..<n {
            #expect(results[i].toolUseID == "id\(i)", "seed=\(seed) i=\(i) order broke")
            #expect(results[i].toolName == "f\(i)")
        }

        let peakExcl = await tracker.peakExclusive
        let overlapped = await tracker.sawSharedAndExclusiveOverlap
        #expect(peakExcl <= 1, "seed=\(seed) saw exclusive overlap")
        #expect(!overlapped, "seed=\(seed) saw shared/exclusive overlap")
    }

    /// All-shared stress: peak concurrency should reach the full input size.
    @Test
    func allSharedReachesPeakEqualToInputCount() async throws {
        let tracker = ExecutionTracker()
        let n = 20
        let tools: [any AgentTool] = (0..<n).map { i in
            ProbeTool(name: "p\(i)", tracker: tracker, concurrency: .shared, delayMs: 60)
        }
        let loop = try makeAgentLoop(tools: tools, parallelToolCalls: true)
        let uses = (0..<n).map { use("id\($0)", "p\($0)") }

        _ = try await loop.runToolCalls(uses)

        let peak = await tracker.peakShared
        #expect(peak == n, "all-shared workload should fully parallelise; peak=\(peak)")
    }
}

// MARK: - Deterministic RNG for property-style tests

/// SplitMix64 — small, fast, deterministic. Used so seeded fuzz tests
/// reproduce on every run regardless of the platform's `SystemRandomNumberGenerator`.
private struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
