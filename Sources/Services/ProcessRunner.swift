import Foundation

enum RunError: LocalizedError {
    case notFound(String)
    case exit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .notFound(let t): return "Couldn't find \(t). Install it (e.g. `brew install \(t)`)."
        case .exit(let code, let tail): return "Process exited with code \(code). \(tail)"
        }
    }
}

// Thin async wrapper around Process. Streams combined stdout+stderr as lines.
struct ProcessRunner {

    // Stream lines as the process runs. Throws RunError.exit on non-zero exit.
    static func stream(_ exe: URL,
                       _ args: [String],
                       extraEnv: [String: String] = [:]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = exe
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = BinaryLocator.augmentedPath
            for (k, v) in extraEnv { env[k] = v }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var pending = Data()
            var lastLines: [String] = []   // keep a small tail for error messages

            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                pending.append(chunk)
                // yt-dlp uses \r for progress; treat both as line breaks.
                while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = pending.subdata(in: pending.startIndex..<idx)
                    pending.removeSubrange(pending.startIndex...idx)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        lastLines.append(line)
                        if lastLines.count > 12 { lastLines.removeFirst() }
                        continuation.yield(line)
                    }
                }
            }

            process.terminationHandler = { p in
                handle.readabilityHandler = nil
                if !pending.isEmpty, let s = String(data: pending, encoding: .utf8), !s.isEmpty {
                    continuation.yield(s)
                }
                if p.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    let tail = lastLines.suffix(3).joined(separator: " | ")
                    continuation.finish(throwing: RunError.exit(p.terminationStatus, tail))
                }
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning {
                    process.terminate()
                }
            }

            do { try process.run() }
            catch { continuation.finish(throwing: error) }
        }
    }

    // Run to completion and return the full combined output.
    @discardableResult
    static func capture(_ exe: URL,
                        _ args: [String],
                        extraEnv: [String: String] = [:]) async throws -> String {
        var out = ""
        for try await line in stream(exe, args, extraEnv: extraEnv) {
            out += line + "\n"
        }
        return out
    }
}
