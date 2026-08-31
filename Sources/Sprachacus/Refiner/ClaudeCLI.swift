import Foundation

/// Shared non-interactive invocation of the Claude Code CLI, used by the
/// dictation refiner, the assist composer and the meeting summarizer.
enum ClaudeCLI {
    struct CLIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// GUI apps don't inherit the shell PATH, so resolve the binary once
    /// via a login shell and cache the result.
    static func resolvePath() -> String? {
        if let cached = Settings.shared.claudePath,
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        Settings.shared.claudePath = path
        return path
    }

    static var isAvailable: Bool { resolvePath() != nil }

    /// Runs `claude -p` with the given system prompt, feeding `input` via stdin.
    /// Tools are disabled and a hard dollar cap is applied.
    static func run(systemPrompt: String,
                    input: String,
                    maxBudgetUSD: String,
                    timeout: TimeInterval) async throws -> String {
        guard let claudePath = resolvePath() else {
            throw CLIError(message: "claude CLI nicht gefunden")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = [
            "-p",
            "--model", "haiku",
            "--output-format", "text",
            "--tools", "",
            "--no-session-persistence",
            "--max-budget-usd", maxBudgetUSD,
            "--system-prompt", systemPrompt
        ]
        process.currentDirectoryURL = AppPaths.supportDir

        // The claude launcher is a node script (#!/usr/bin/env node) — make sure
        // node is findable next to the claude binary.
        var env = ProcessInfo.processInfo.environment
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        env["PATH"] = "\(claudeDir):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(input.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        // Read stdout on a background thread so the pipe can't fill up and deadlock.
        let readTask = Task.detached {
            try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        }

        let finished: Bool = await withCheckedContinuation { continuation in
            let resumed = OnceFlag()
            process.terminationHandler = { _ in
                if resumed.take() { return }
                continuation.resume(returning: true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if resumed.take() { return }
                process.terminate()
                continuation.resume(returning: false)
            }
        }
        guard finished else { throw CLIError(message: "claude CLI Timeout") }
        guard process.terminationStatus == 0 else {
            throw CLIError(message: "claude CLI Exit-Code \(process.terminationStatus)")
        }
        let data = try await readTask.value
        guard let output = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "claude CLI: ungültige Ausgabe")
        }
        return output
    }
}

/// First caller of `take()` gets `false` and flips the flag — used to make
/// sure a continuation is resumed exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = taken
        taken = true
        return old
    }
}
