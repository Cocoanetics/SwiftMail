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
        guard delayMs >= 0 else { throw ValidationError("--delay-ms must not be negative") }
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

            let checks = LiveTestChecks(
                server: server, environment: environment, mailbox: mailbox,
                messages: messages, messageCount: fetched, delay: .milliseconds(delayMs)
            )
            var outcomes: [LiveTestOutcome] = []
            for check in [
                checks.cancelCommand, checks.cancelStream, checks.disconnectDuringCommand,
                checks.receiveLimit, checks.abortDuringCommand
            ] {
                let outcome = await check()
                print(outcome.line)
                outcomes.append(outcome)
            }
            try? await server.disconnect()

            let failed = outcomes.filter { $0.verdict == .fail }.count
            let inconclusive = outcomes.filter { $0.verdict == .inconclusive }.count
            print("\n\(outcomes.count - failed - inconclusive) passed, \(failed) failed, \(inconclusive) inconclusive.")
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
