import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let out: String
    public let err: String
}

private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}

public enum Shell {
    /// Runs an executable and waits for it. Cancels (terminates) the process if the task is cancelled.
    @discardableResult
    public static func run(_ executable: String,
                           _ args: [String],
                           cwd: URL? = nil,
                           env: [String: String]? = nil,
                           onStderr: (@Sendable (String) -> Void)? = nil,
                           onStdout: (@Sendable (String) -> Void)? = nil,
                           allowFailure: Bool = false) async throws -> ShellResult {
        let box = ProcessBox()
        let p = box.process
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        let outBuf = Buffer(), errBuf = Buffer()
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            outBuf.append(d)
            onStdout?(String(decoding: d, as: UTF8.self))
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            errBuf.append(d)
            onStderr?(String(decoding: d, as: UTF8.self))
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
                do { try p.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain whatever is left in the pipes.
        outBuf.append((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
        errBuf.append((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())

        try Task.checkCancellation()
        let result = ShellResult(status: status, out: outBuf.string, err: errBuf.string)
        if status != 0 && !allowFailure {
            let tail = result.err.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw MerError.failed("\((executable as NSString).lastPathComponent) exited with \(status)\(tail.isEmpty ? "" : ": " + tail)")
        }
        return result
    }
}

/// Finds helper binaries (system and third-party engines).
public enum Tooling {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String?] = [:]

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mer", isDirectory: true)
    }

    public static var searchDirs: [String] {
        var dirs = [supportDirectory.appendingPathComponent("bin").path,
                    "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                    "/Applications/LibreOffice.app/Contents/MacOS"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        return dirs
    }

    public static func find(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        var found: String?
        for dir in searchDirs {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { found = p; break }
        }
        cache[name] = found
        return found
    }

    public static func resetCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    public static func require(_ name: String) throws -> String {
        guard let p = find(name) else { throw MerError.toolMissing(name) }
        return p
    }
}
