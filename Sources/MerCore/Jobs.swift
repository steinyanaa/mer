import Foundation
import Combine

public final class Job: ObservableObject, Identifiable {
    public enum State: Equatable {
        case queued, running, done
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let action: MerAction
    public let inputs: [URL]
    public let params: [String: String]
    public let startedAt = Date()

    @Published public var state: State = .queued
    @Published public var progress: Double = 0
    @Published public var outputs: [URL] = []

    fileprivate var task: Task<Void, Never>?

    init(action: MerAction, inputs: [URL], params: [String: String]) {
        self.action = action
        self.inputs = inputs
        self.params = params
    }

    public var title: String {
        let name = inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files"
        return "\(name) → \(action.displayTitle)"
    }

    public var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    public func cancel() { task?.cancel() }
}

private actor Gate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

@MainActor
public final class JobCenter: ObservableObject {
    public static let shared = JobCenter()

    @Published public private(set) var jobs: [Job] = []
    public var onJobFinished: ((Job) -> Void)?

    private let gate = Gate(2)

    public init() {}

    @discardableResult
    public func submit(_ action: MerAction,
                       inputs: [URL],
                       params: [String: String] = [:],
                       policy: OutputPolicy = OutputPolicy(),
                       trashOriginals: Bool = false) -> Job {
        let job = Job(action: action, inputs: inputs, params: params)
        jobs.insert(job, at: 0)
        if jobs.count > 50 { jobs = Array(jobs.prefix(50)) }
        UsageStats.record(action.id)

        job.task = Task { [gate] in
            await gate.acquire()
            defer { Task { await gate.release() } }
            if Task.isCancelled { job.state = .cancelled; self.finish(job); return }
            job.state = .running

            let units = action.batch ? [inputs] : inputs.map { [$0] }
            var outputs: [URL] = []
            do {
                for (i, unit) in units.enumerated() {
                    try Task.checkCancellation()
                    let base = Double(i) / Double(units.count)
                    let span = 1.0 / Double(units.count)
                    let ctx = RunContext(policy: policy, params: params) { p in
                        Task { @MainActor in job.progress = base + p * span }
                    }
                    outputs += try await action.work(unit, ctx)
                    job.progress = Double(i + 1) / Double(units.count)
                }
                job.outputs = outputs
                if trashOriginals {
                    for url in inputs where !outputs.contains(url) {
                        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                }
                job.state = .done
            } catch is CancellationError {
                job.state = .cancelled
            } catch {
                job.state = .failed(error.localizedDescription)
            }
            self.finish(job)
        }
        return job
    }

    private func finish(_ job: Job) {
        onJobFinished?(job)
        objectWillChange.send()
    }

    public func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    /// Convenience used by the CLI: runs and awaits.
    public func runAndWait(_ action: MerAction, inputs: [URL],
                           params: [String: String] = [:],
                           policy: OutputPolicy = OutputPolicy()) async -> Job {
        let job = submit(action, inputs: inputs, params: params, policy: policy)
        _ = await job.task?.value
        return job
    }
}
