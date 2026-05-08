import Foundation

/// Status of a single todo task.
public enum TodoStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case abandoned
}

/// A single tracked task within a phase. `content` doubles as the identifier —
/// keep it stable once introduced.
public struct TodoItem: Codable, Sendable, Equatable {
    public var content: String
    public var status: TodoStatus
    public var notes: [String]

    public init(content: String, status: TodoStatus = .pending, notes: [String] = []) {
        self.content = content
        self.status = status
        self.notes = notes
    }
}

/// A named bucket of related tasks. `name` doubles as the identifier.
public struct TodoPhase: Codable, Sendable, Equatable {
    public var name: String
    public var tasks: [TodoItem]

    public init(name: String, tasks: [TodoItem] = []) {
        self.name = name
        self.tasks = tasks
    }
}

/// Thread-safe store backing `TodoWriteTool`. UI layers can subscribe to
/// `phasesStream` to reflect updates live; the AgentLoop never reads from it
/// directly — the textual return value of the tool call already feeds the
/// model.
public actor TodoStore {
    private var phases: [TodoPhase]
    private var continuations: [UUID: AsyncStream<[TodoPhase]>.Continuation] = [:]

    public init(initialPhases: [TodoPhase] = []) {
        self.phases = initialPhases
    }

    /// Snapshot of the current phases.
    public func snapshot() -> [TodoPhase] {
        phases
    }

    /// Async stream of phase snapshots. Emits the current state immediately,
    /// then a new snapshot on every mutation.
    public func phasesStream() -> AsyncStream<[TodoPhase]> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(phases)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast() {
        for continuation in continuations.values {
            continuation.yield(phases)
        }
    }

    // MARK: - Mutations

    /// Replace the entire list. Mirrors `op: "init"`.
    func replace(with newPhases: [TodoPhase]) {
        phases = newPhases
        normalizeInProgress()
        broadcast()
    }

    /// Append items to a phase, lazily creating the phase if needed.
    func append(phase phaseName: String, items: [String]) {
        if let idx = phases.firstIndex(where: { $0.name == phaseName }) {
            phases[idx].tasks.append(contentsOf: items.map { TodoItem(content: $0) })
        } else {
            phases.append(TodoPhase(name: phaseName, tasks: items.map { TodoItem(content: $0) }))
        }
        normalizeInProgress()
        broadcast()
    }

    func setStatus(forTask content: String, status: TodoStatus) -> Bool {
        for pIdx in phases.indices {
            if let tIdx = phases[pIdx].tasks.firstIndex(where: { $0.content == content }) {
                phases[pIdx].tasks[tIdx].status = status
                normalizeInProgress()
                broadcast()
                return true
            }
        }
        return false
    }

    func setStatus(forPhase phaseName: String, status: TodoStatus) -> Bool {
        guard let idx = phases.firstIndex(where: { $0.name == phaseName }) else { return false }
        for tIdx in phases[idx].tasks.indices {
            phases[idx].tasks[tIdx].status = status
        }
        normalizeInProgress()
        broadcast()
        return true
    }

    func remove(task content: String) -> Bool {
        for pIdx in phases.indices {
            if let tIdx = phases[pIdx].tasks.firstIndex(where: { $0.content == content }) {
                phases[pIdx].tasks.remove(at: tIdx)
                normalizeInProgress()
                broadcast()
                return true
            }
        }
        return false
    }

    func remove(phase phaseName: String) -> Bool {
        guard let idx = phases.firstIndex(where: { $0.name == phaseName }) else { return false }
        phases.remove(at: idx)
        normalizeInProgress()
        broadcast()
        return true
    }

    func removeAll() {
        phases.removeAll()
        broadcast()
    }

    func addNote(toTask content: String, text: String) -> Bool {
        for pIdx in phases.indices {
            if let tIdx = phases[pIdx].tasks.firstIndex(where: { $0.content == content }) {
                phases[pIdx].tasks[tIdx].notes.append(text)
                broadcast()
                return true
            }
        }
        return false
    }

    /// Ensure at most one in_progress task exists; auto-promote the first
    /// pending task if none is in progress and there is work left to do.
    private func normalizeInProgress() {
        var foundInProgress = false
        for pIdx in phases.indices {
            for tIdx in phases[pIdx].tasks.indices {
                if phases[pIdx].tasks[tIdx].status == .inProgress {
                    if foundInProgress {
                        // Demote duplicates back to pending — only one task may
                        // be in progress at a time.
                        phases[pIdx].tasks[tIdx].status = .pending
                    } else {
                        foundInProgress = true
                    }
                }
            }
        }

        if foundInProgress { return }

        // No in-progress task — promote the first pending one.
        for pIdx in phases.indices {
            for tIdx in phases[pIdx].tasks.indices {
                if phases[pIdx].tasks[tIdx].status == .pending {
                    phases[pIdx].tasks[tIdx].status = .inProgress
                    return
                }
            }
        }
    }
}
