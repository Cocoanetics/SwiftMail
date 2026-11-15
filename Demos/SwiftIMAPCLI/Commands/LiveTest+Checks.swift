import Foundation
import SwiftMail

struct LiveTestChecks {
    let server: IMAPServer
    let environment: IMAPEnvironment
    let mailbox: String
    let messages: SequenceNumberSet
    let messageCount: Int
    let delay: Duration

    /// How long the slow fetch and the slow stream take when nothing interrupts them.
    /// An interruption only counts when it comes well inside this time.
    private(set) var commandBaseline = Duration.zero
    private(set) var streamBaseline = Duration.zero

    /// Enough per message that the reply takes a while to arrive.
    private static let heavy: FetchMessageInfoOptions = [
        .envelope, .internalDate, .flags, .size, .bodyStructure, .fullHeader
    ]

    private static func slowFetch(_ server: IMAPServer, _ messages: SequenceNumberSet) async throws -> Int {
        try await server.fetchMessageInfosBulk(using: messages, options: heavy).count
    }

    private static func slowStream(_ server: IMAPServer, _ messages: SequenceNumberSet) async throws -> Int {
        var seen = 0
        for try await _ in server.fetchMessageInfos(using: messages, options: heavy, chunkSize: 5) {
            seen += 1
        }
        return seen
    }

    /// Runs the slow fetch and the slow stream once each, uninterrupted, and records how long they take.
    mutating func measureBaselines() async throws {
        var start = ContinuousClock.now
        _ = try await Self.slowFetch(server, messages)
        commandBaseline = start.duration(to: .now)
        start = ContinuousClock.now
        _ = try await Self.slowStream(server, messages)
        streamBaseline = start.duration(to: .now)
    }

    // MARK: - Checks

    /// Cancelling the task that runs a command closes its connection; the next command reconnects.
    func cancelCommand() async -> LiveTestOutcome {
        await check("Cancel a running command") { name in
            if let early = tooShortToInterrupt(name, baseline: commandBaseline) { return early }
            let interruption = try await interruptSlowFetch { $0.cancel() }
            if let early = try await notInFlight(name, interruption, requireClosed: true) { return early }
            guard case .failure(let error) = interruption.result, error is CancellationError else {
                return fail(name, "expected CancellationError, the fetch ended with \(describe(interruption.result))")
            }
            return try await finish(
                name, "cancelled in \(interruption.elapsed.milliseconds) ms", interruption.elapsed)
        }
    }

    /// Cancelling a stream's consumer stops the command in flight and sends no later chunk.
    func cancelStream() async -> LiveTestOutcome {
        await check("Cancel a fetch stream") { name in
            if let early = tooShortToInterrupt(name, baseline: streamBaseline) { return early }
            let consumer = await started { [server, messages] in try await Self.slowStream(server, messages) }
            try? await Task.sleep(for: delay)
            let start = ContinuousClock.now
            consumer.cancel()
            guard let result = await liveTestRace(within: liveTestPromptLimit, { await consumer.result }) else {
                throw LiveTestHang(step: "the cancelled stream", limit: liveTestPromptLimit)
            }
            let elapsed = start.duration(to: .now)
            if case .success(let seen) = result, seen >= messageCount {
                return LiveTestOutcome(
                    name: name, verdict: .inconclusive, detail: "the stream delivered all \(seen) messages first")
            }
            if case .failure(let error) = result, !(error is CancellationError) {
                return fail(name, "the stream ended with \(liveTestErrorName(error))")
            }
            return try await finish(name, "stream ended in \(elapsed.milliseconds) ms", elapsed)
        }
    }

    /// `disconnect()` returns without waiting for the running command; the next command reconnects.
    func disconnectDuringCommand() async -> LiveTestOutcome {
        await check("disconnect() during a command") { name in
            if let early = tooShortToInterrupt(name, baseline: commandBaseline) { return early }
            let interruption = try await interruptSlowFetch { [server] _ in try? await server.disconnect() }
            if let early = try await notInFlight(name, interruption, requireClosed: false) { return early }
            return try await finish(
                name, "returned and settled the fetch in \(interruption.elapsed.milliseconds) ms", interruption.elapsed)
        }
    }

    /// A reply limit of one fails a two-message fetch with a typed error; the next command works.
    func receiveLimit() async -> LiveTestOutcome {
        await check("FETCH reply limit") { name in
            do {
                let fetched = try await liveTestBounded("the fetch with a reply limit") { [server, messages] in
                    try await server.fetchMessageInfosBulk(
                        using: messages, options: .uidFlagsOnly, limits: FetchReceiveLimits(maximumReplies: 1)
                    ).count
                }
                return fail(name, "returned \(fetched) messages instead of throwing")
            } catch let error as FetchReceiveLimitExceededError {
                guard error.dimension == .replies, error.limit == 1 else {
                    return fail(name, "unexpected error \(error)")
                }
                return try await finish(name, "threw FetchReceiveLimitExceededError", .zero)
            } catch let hang as LiveTestHang {
                throw hang
            } catch {
                return fail(name, "expected FetchReceiveLimitExceededError, got \(liveTestErrorName(error))")
            }
        }
    }

    /// `abort()` fails the running command, blocks later ones, and `connect()` brings the connection back.
    func abortDuringCommand() async -> LiveTestOutcome {
        await check("abort() during a command") { name in
            if let early = tooShortToInterrupt(name, baseline: commandBaseline) { return early }
            let interruption = try await interruptSlowFetch { [server] _ in await server.abort() }
            if let early = try await notInFlight(name, interruption, requireClosed: false) { return early }
            guard case .failure(let error) = interruption.result, error is IMAPConnectionAbortedError else {
                return fail(
                    name, "expected IMAPConnectionAbortedError, the fetch ended with \(describe(interruption.result))")
            }
            return try await restoreAfterAbort(name, interruption.elapsed)
        }
    }

    /// After `abort()`: a later command is refused, `connect()` restores the connection, and the next command works.
    private func restoreAfterAbort(_ name: String, _ elapsed: Duration) async throws -> LiveTestOutcome {
        do {
            try await liveTestBounded("NOOP after abort()") { [server] in _ = try await server.noop() }
            return fail(name, "a command succeeded after abort() without connect()")
        } catch is IMAPConnectionAbortedError {
            // Expected: the connection stays aborted until connect().
        } catch let hang as LiveTestHang {
            throw hang
        } catch {
            return fail(
                name, "a command after abort() threw \(liveTestErrorName(error)), not IMAPConnectionAbortedError")
        }
        do {
            try await liveTestBounded("connect() after abort()") { [server] in try await server.connect() }
        } catch let hang as LiveTestHang {
            throw hang
        } catch {
            return fail(name, "connect() after abort() failed: \(liveTestErrorName(error))")
        }
        var note = "aborted in \(elapsed.milliseconds) ms; later command refused; connect() restored it"
        if try await recover() != nil {
            // connect() alone was not enough; log in again as the abort() documentation says.
            do {
                try await liveTestBounded("logging in after connect()") { [server, environment] in
                    try await authenticate(server: server, using: environment)
                }
            } catch let hang as LiveTestHang {
                throw hang
            } catch {
                return fail(name, "authenticating after connect() failed: \(liveTestErrorName(error))")
            }
            note += " after logging in again"
        }
        return try await finish(name, note, elapsed)
    }

    // MARK: - Helpers

    /// Runs a check's steps. A step that throws ``LiveTestHang`` fails the check and stops the run,
    /// because the hung command still holds the connection.
    private func check(
        _ name: String, _ steps: (String) async throws -> LiveTestOutcome
    ) async -> LiveTestOutcome {
        do {
            return try await steps(name)
        } catch let hang as LiveTestHang {
            return LiveTestOutcome(
                name: name, verdict: .fail,
                detail: "\(hang.step) did not finish within \(hang.limit.milliseconds) ms", stopsRun: true)
        } catch {
            return fail(name, "unexpected \(liveTestErrorName(error))")
        }
    }

    /// Starts the slow fetch, lets it run for `delay`, interrupts it and waits for it to end.
    /// Throws ``LiveTestHang`` when the interruption or the fetch has not settled within the prompt limit.
    private func interruptSlowFetch(
        _ interrupt: @escaping @Sendable (Task<Int, Error>) async -> Void
    ) async throws -> LiveTestInterruption {
        let fetch = await started { [server, messages] in try await Self.slowFetch(server, messages) }
        try? await Task.sleep(for: delay)
        let start = ContinuousClock.now
        let settled = await liveTestRace(within: liveTestPromptLimit) {
            await interrupt(fetch)
            return await fetch.result
        }
        guard let result = settled else {
            throw LiveTestHang(step: "the interrupted fetch", limit: liveTestPromptLimit)
        }
        let elapsed = start.duration(to: .now)
        return LiveTestInterruption(result: result, elapsed: elapsed, closedConnection: !(await server.isConnected))
    }

    /// Starts `body` in a task and returns once that task is running, so `delay` counts from its start.
    private func started<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> Value
    ) async -> Task<Value, Error> {
        let (signal, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            continuation.finish()
            return try await body()
        }
        for await _ in signal {}
        return task
    }

    /// An inconclusive outcome when the uninterrupted operation is too quick for `delay` to land inside it.
    private func tooShortToInterrupt(_ name: String, baseline: Duration) -> LiveTestOutcome? {
        guard delay * 2 > baseline else { return nil }
        return LiveTestOutcome(
            name: name, verdict: .inconclusive,
            detail: "it takes only \(baseline.milliseconds) ms uninterrupted, too short to interrupt "
                + "after \(delay.milliseconds) ms")
    }

    /// An inconclusive outcome when the fetch was not executing at the moment it was interrupted.
    /// The interruption has still happened, so this restores the connection for the next check.
    private func notInFlight(
        _ name: String, _ interruption: LiveTestInterruption, requireClosed: Bool
    ) async throws -> LiveTestOutcome? {
        let fetchReturned: Bool
        if case .success = interruption.result { fetchReturned = true } else { fetchReturned = false }
        guard fetchReturned || (requireClosed && !interruption.closedConnection) else { return nil }
        // After abort() only an explicit connect() brings the connection back.
        if !(await server.isConnected) {
            _ = try? await liveTestBounded("reconnecting") { [server] in try await server.connect() }
        }
        _ = try await recover()
        if case .success(let fetched) = interruption.result {
            return LiveTestOutcome(
                name: name, verdict: .inconclusive,
                detail: "the fetch returned \(fetched) messages before the interruption")
        }
        if requireClosed, !interruption.closedConnection {
            return LiveTestOutcome(
                name: name, verdict: .inconclusive, detail: "the fetch was interrupted before it reached the server")
        }
        return nil
    }

    /// Selects the mailbox and sends NOOP. Returns what went wrong, or `nil`.
    /// Throws ``LiveTestHang`` when the two have not finished within ``liveTestHangLimit``.
    private func recover() async throws -> String? {
        do {
            try await liveTestBounded("the next command (SELECT and NOOP)") { [server, mailbox] in
                _ = try await server.selectMailbox(mailbox)
                _ = try await server.noop()
            }
            return nil
        } catch let hang as LiveTestHang {
            throw hang
        } catch {
            return liveTestErrorName(error)
        }
    }

    /// Passes when the interruption was prompt and an ordinary command works afterwards.
    private func finish(_ name: String, _ detail: String, _ elapsed: Duration) async throws -> LiveTestOutcome {
        guard elapsed <= liveTestPromptLimit else {
            return fail(name, "\(detail), which is slower than \(liveTestPromptLimit.milliseconds) ms")
        }
        let start = ContinuousClock.now
        if let problem = try await recover() {
            return fail(name, "\(detail), but the next command failed: \(problem)")
        }
        let recovery = start.duration(to: .now).milliseconds
        return LiveTestOutcome(
            name: name, verdict: .pass, detail: "\(detail); next command worked after \(recovery) ms")
    }

    private func fail(_ name: String, _ detail: String) -> LiveTestOutcome {
        LiveTestOutcome(name: name, verdict: .fail, detail: detail)
    }

    private func describe(_ result: Result<Int, Error>) -> String {
        switch result {
            case .success(let fetched): return "\(fetched) messages"
            case .failure(let error): return liveTestErrorName(error)
        }
    }
}
