import Foundation
import SwiftMail

struct LiveTestChecks {
    let server: IMAPServer
    let environment: IMAPEnvironment
    let mailbox: String
    let messages: SequenceNumberSet
    let messageCount: Int
    let delay: Duration

    /// Enough per message that the reply takes a while to arrive.
    private static let heavy: FetchMessageInfoOptions = [
        .envelope, .internalDate, .flags, .size, .bodyStructure, .fullHeader
    ]

    // MARK: - Checks

    /// Cancelling the task that runs a command closes its connection; the next command reconnects.
    func cancelCommand() async -> LiveTestOutcome {
        let name = "Cancel a running command"
        let interruption = await interruptSlowFetch { $0.cancel() }
        if let early = notInFlight(name, interruption, requireClosed: true) { return early }
        guard case .failure(let error) = interruption.result, error is CancellationError else {
            return fail(name, "expected CancellationError, the fetch ended with \(describe(interruption.result))")
        }
        return await finish(name, "cancelled in \(interruption.elapsed.milliseconds) ms", interruption.elapsed)
    }

    /// Cancelling a stream's consumer stops the command in flight and sends no later chunk.
    func cancelStream() async -> LiveTestOutcome {
        let name = "Cancel a fetch stream"
        let consumer = Task { [server, messages] in
            var seen = 0
            for try await _ in server.fetchMessageInfos(using: messages, options: Self.heavy, chunkSize: 5) {
                seen += 1
            }
            return seen
        }
        try? await Task.sleep(for: delay)
        let start = ContinuousClock.now
        consumer.cancel()
        let result = await consumer.result
        let elapsed = start.duration(to: .now)
        if case .success(let seen) = result, seen >= messageCount {
            return LiveTestOutcome(
                name: name, verdict: .inconclusive, detail: "the stream delivered all \(seen) messages first")
        }
        if case .failure(let error) = result, !(error is CancellationError) {
            return fail(name, "the stream ended with \(liveTestErrorName(error))")
        }
        return await finish(name, "stream ended in \(elapsed.milliseconds) ms", elapsed)
    }

    /// `disconnect()` returns without waiting for the running command; the next command reconnects.
    func disconnectDuringCommand() async -> LiveTestOutcome {
        let name = "disconnect() during a command"
        let interruption = await interruptSlowFetch { [server] _ in try? await server.disconnect() }
        if let early = notInFlight(name, interruption, requireClosed: false) { return early }
        return await finish(
            name, "returned and settled the fetch in \(interruption.elapsed.milliseconds) ms", interruption.elapsed)
    }

    /// A reply limit of one fails a two-message fetch with a typed error; the next command works.
    func receiveLimit() async -> LiveTestOutcome {
        let name = "FETCH reply limit"
        do {
            let infos = try await server.fetchMessageInfosBulk(
                using: messages, options: .uidFlagsOnly, limits: FetchReceiveLimits(maximumReplies: 1))
            return fail(name, "returned \(infos.count) messages instead of throwing")
        } catch let error as FetchReceiveLimitExceededError {
            guard error.dimension == .replies, error.limit == 1 else { return fail(name, "unexpected error \(error)") }
            return await finish(name, "threw FetchReceiveLimitExceededError", .zero)
        } catch {
            return fail(name, "expected FetchReceiveLimitExceededError, got \(liveTestErrorName(error))")
        }
    }

    /// `abort()` fails the running command, blocks later ones, and `connect()` brings the connection back.
    func abortDuringCommand() async -> LiveTestOutcome {
        let name = "abort() during a command"
        let interruption = await interruptSlowFetch { [server] _ in await server.abort() }
        if let early = notInFlight(name, interruption, requireClosed: false) { return early }
        guard case .failure(let error) = interruption.result, error is IMAPConnectionAbortedError else {
            return fail(
                name, "expected IMAPConnectionAbortedError, the fetch ended with \(describe(interruption.result))")
        }
        do {
            _ = try await server.noop()
            return fail(name, "a command succeeded after abort() without connect()")
        } catch is IMAPConnectionAbortedError {
            // Expected: the connection stays aborted until connect().
        } catch {
            return fail(
                name, "a command after abort() threw \(liveTestErrorName(error)), not IMAPConnectionAbortedError")
        }
        do {
            try await server.connect()
        } catch {
            return fail(name, "connect() after abort() failed: \(liveTestErrorName(error))")
        }
        var note = "aborted in \(interruption.elapsed.milliseconds) ms; later command refused; connect() restored it"
        if await recover() != nil {
            // connect() alone was not enough; log in again as the abort() documentation says.
            do {
                try await authenticate(server: server, using: environment)
            } catch {
                return fail(name, "authenticating after connect() failed: \(liveTestErrorName(error))")
            }
            note += " after logging in again"
        }
        return await finish(name, note, interruption.elapsed)
    }

    // MARK: - Helpers

    /// Starts the slow fetch, lets it run for `delay`, interrupts it and waits for it to end.
    private func interruptSlowFetch(
        _ interrupt: @escaping @Sendable (Task<Int, Error>) async -> Void
    ) async -> LiveTestInterruption {
        let fetch = Task { [server, messages] in
            try await server.fetchMessageInfosBulk(using: messages, options: Self.heavy).count
        }
        try? await Task.sleep(for: delay)
        let start = ContinuousClock.now
        await interrupt(fetch)
        let result = await fetch.result
        let elapsed = start.duration(to: .now)
        return LiveTestInterruption(result: result, elapsed: elapsed, closedConnection: !(await server.isConnected))
    }

    /// An inconclusive outcome when the fetch was not executing at the moment it was interrupted.
    private func notInFlight(
        _ name: String, _ interruption: LiveTestInterruption, requireClosed: Bool
    ) -> LiveTestOutcome? {
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
    private func recover() async -> String? {
        do {
            _ = try await server.selectMailbox(mailbox)
            _ = try await server.noop()
            return nil
        } catch {
            return liveTestErrorName(error)
        }
    }

    /// Passes when the interruption was prompt and an ordinary command works afterwards.
    private func finish(_ name: String, _ detail: String, _ elapsed: Duration) async -> LiveTestOutcome {
        guard elapsed <= liveTestPromptLimit else {
            return fail(name, "\(detail), which is slower than \(liveTestPromptLimit.milliseconds) ms")
        }
        let start = ContinuousClock.now
        if let problem = await recover() {
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
