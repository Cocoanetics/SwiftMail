import Foundation
import ArgumentParser
import SwiftMail

/// Checks cancellation, abort, disconnect and FETCH limits against a live mailbox.
///
/// It only reads: SELECT, FETCH and NOOP. Each check interrupts a slow metadata
/// fetch and then issues an ordinary command to see how the connection recovers.
struct LiveTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "livetest",
        abstract: "Check cancellation, abort, disconnect and FETCH limits against a live mailbox (read-only)"
    )

    @Option(name: .shortAndLong, help: "Mailbox to read from")
    var mailbox: String = "INBOX"

    @Option(name: .shortAndLong, help: "How many of the latest messages the slow fetch asks for")
    var count: Int = 200

    @Option(help: "Milliseconds the fetch runs before it is interrupted")
    var delayMs: Int = 30

    func validate() throws {
        guard count >= 2 else { throw ValidationError("--count must be at least 2") }
        guard delayMs >= 1 else { throw ValidationError("--delay-ms must be at least 1") }
    }

    func run() throws {
        runAsyncBlock {
            let environment = try loadIMAPEnvironment()
            let server = IMAPServer(host: environment.host, port: environment.port)
            print("Connecting to \(environment.host):\(environment.port)...")
            try await server.connect()
            try await authenticate(server: server, using: environment)
            let status = try await server.selectMailbox(mailbox)
            guard status.messageCount >= 2, let messages = status.latest(count) else {
                throw ValidationError("\(mailbox) needs at least two messages for this test")
            }
            let fetched = min(count, status.messageCount)
            print("\(mailbox): \(status.messageCount) messages; the slow fetch asks for the latest \(fetched).\n")

            var checks = LiveTestChecks(
                server: server, environment: environment, mailbox: mailbox,
                messages: messages, messageCount: fetched, delay: .milliseconds(delayMs)
            )
            try await checks.measureBaselines()
            print("Uninterrupted, the slow fetch takes \(checks.commandBaseline.milliseconds) ms "
                + "and the slow stream \(checks.streamBaseline.milliseconds) ms.\n")
            let allChecks = [
                checks.cancelCommand, checks.cancelStream, checks.disconnectDuringCommand,
                checks.receiveLimit, checks.abortDuringCommand
            ]
            var outcomes: [LiveTestOutcome] = []
            for check in allChecks {
                let outcome = await check()
                print(outcome.line)
                outcomes.append(outcome)
                if outcome.stopsRun {
                    print("A command is still running and would hold up every later one; "
                        + "skipping the remaining checks.")
                    break
                }
            }
            _ = await liveTestRace(within: liveTestPromptLimit) { try? await server.disconnect() }

            let failed = outcomes.filter { $0.verdict == .fail }.count
            let inconclusive = outcomes.filter { $0.verdict == .inconclusive }.count
            let skipped = allChecks.count - outcomes.count
            print("\n\(outcomes.count - failed - inconclusive) passed, \(failed) failed, \(inconclusive) inconclusive"
                + (skipped > 0 ? ", \(skipped) skipped." : "."))
            if inconclusive > 0 {
                print("Inconclusive means the fetch was not in flight when interrupted; adjust --count or --delay-ms.")
            }
            if failed > 0 { Foundation.exit(1) }
        }
    }
}

struct LiveTestOutcome {
    enum Verdict: String { case pass = "PASS", fail = "FAIL", inconclusive = "INCONCLUSIVE" }

    let name: String
    let verdict: Verdict
    let detail: String
    /// A step of this check hung and still holds the connection, so no later check can run.
    var stopsRun = false

    var line: String { "[\(verdict.rawValue)] \(name): \(detail)" }
}

/// How an interrupted fetch ended.
struct LiveTestInterruption {
    let result: Result<Int, Error>
    let elapsed: Duration
    /// The primary connection was closed, so the fetch was executing when interrupted.
    let closedConnection: Bool
}

extension Duration {
    var milliseconds: Int { Int(self / .milliseconds(1)) }
}

func liveTestErrorName(_ error: Error) -> String {
    "\(type(of: error)) (\(error))"
}

/// A recovery or settlement slower than this is reported as a failure.
let liveTestPromptLimit = Duration.seconds(2)

/// The value of `operation`, or `nil` when it has not finished within `limit`.
///
/// The operation is not cancelled on a timeout; a check that hangs is reported and left behind.
func liveTestRace<Value: Sendable>(
    within limit: Duration, _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    let (results, continuation) = AsyncStream<Value?>.makeStream()
    Task {
        continuation.yield(await operation())
        continuation.finish()
    }
    Task {
        try? await Task.sleep(for: limit)
        continuation.yield(nil)
        continuation.finish()
    }
    for await result in results { return result }
    return nil
}

/// How long an ordinary step (reconnecting, logging in, SELECT, NOOP, a small fetch) may take
/// before the run treats it as hung. Generous, so a slow server is not mistaken for a hang.
let liveTestHangLimit = Duration.seconds(30)

/// A step that did not finish in time. It is left running and holds the connection's command
/// queue, so every later command would wait behind it; the run stops after the check that hit it.
struct LiveTestHang: Error {
    let step: String
    let limit: Duration
}

/// The value of `operation`, rethrowing its error; throws ``LiveTestHang`` when it has not finished within `limit`.
func liveTestBounded<Value: Sendable>(
    _ step: String, within limit: Duration = liveTestHangLimit,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let settled = await liveTestRace(within: limit) { () async -> Result<Value, Error> in
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
    guard let settled else { throw LiveTestHang(step: step, limit: limit) }
    return try settled.get()
}
