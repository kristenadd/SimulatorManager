import Foundation

struct ShellError: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(command) failed (exit \(status))" + (message.isEmpty ? "" : ": \(message)")
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum Shell {
    /// Runs a process off the main thread and returns stdout. Never blocks the caller's actor.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain both pipes concurrently so a full stderr buffer can't deadlock us.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let name = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(3))
                        .joined(separator: " ")
                    continuation.resume(throwing: ShellError(
                        command: name,
                        status: process.terminationStatus,
                        stderr: String(decoding: errBox.data, as: UTF8.self)))
                }
            }
        }
    }
}
