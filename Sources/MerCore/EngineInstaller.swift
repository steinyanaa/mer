import Foundation
import Combine

/// Installs optional engines (ffmpeg, pandoc …) through Homebrew without opening Terminal.
/// Nothing is bundled: the engines are installed from Homebrew on the user's request, which keeps
/// Mer free of GPL-licensed binaries.
@MainActor
public final class EngineInstaller: ObservableObject {
    public static let shared = EngineInstaller()

    public enum State: Equatable {
        case idle
        case installing(String)      // latest line of brew output
        case failed(String)
        case done
    }

    @Published public private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public var brewPath: String? { Tooling.find("brew") }

    public func state(for engine: EngineInfo) -> State {
        if engine.installed, states[engine.binary] == nil || states[engine.binary] == .idle { return .done }
        return states[engine.binary] ?? .idle
    }

    public func install(_ engine: EngineInfo) {
        guard let brew = brewPath else {
            states[engine.binary] = .failed("Homebrew is not installed (see brew.sh)")
            return
        }
        guard tasks[engine.binary] == nil else { return }
        states[engine.binary] = .installing("Starting…")

        let args = ["install"] + engine.brew.split(separator: " ").map(String.init)
        tasks[engine.binary] = Task { [weak self] in
            do {
                try await Shell.run(brew, args,
                                    env: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                                          "NONINTERACTIVE": "1"],
                                    onStderr: { chunk in Task { @MainActor in self?.progress(engine, chunk) } },
                                    onStdout: { chunk in Task { @MainActor in self?.progress(engine, chunk) } })
                ActionRegistry.shared.reload()
                self?.states[engine.binary] = engine.installed ? .done : .failed("Installed, but \(engine.binary) was not found")
            } catch is CancellationError {
                self?.states[engine.binary] = .idle
            } catch {
                self?.states[engine.binary] = .failed(error.localizedDescription)
            }
            self?.tasks[engine.binary] = nil
        }
    }

    public func cancel(_ engine: EngineInfo) { tasks[engine.binary]?.cancel() }

    private func progress(_ engine: EngineInfo, _ chunk: String) {
        // brew redraws progress bars with carriage returns; keep the last readable line
        let line = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.allSatisfy { "#=-> %.0123456789".contains($0) } }
        if let line, case .installing = states[engine.binary] { states[engine.binary] = .installing(String(line.prefix(90))) }
    }
}
