// SMTPServer+SubmissionCommand.swift
// Timeout- and cancellation-aware execution for SMTP submission commands.

import Foundation
import NIO
import NIOCore
import NIOConcurrencyHelpers

private final class SMTPSubmissionWriteResolution: @unchecked Sendable {
    private let lock = NIOLock()
    private var isResolved = false

    func claim() -> Bool {
        lock.withLock {
            guard !isResolved else { return false }
            isResolved = true
            return true
        }
    }
}

final class SMTPSubmissionContentDispatchState: @unchecked Sendable {
    private let lock = NIOLock()
    private var dispatchedContent = false

    var hasDispatchedContent: Bool {
        lock.withLock { dispatchedContent }
    }

    func markContentDispatched() {
        lock.withLock {
            dispatchedContent = true
        }
    }
}

extension SMTPServer {
    /// Keep DATA writes bounded so RFC 5321's per-buffer upload timeout grows
    /// naturally with message size instead of timing the entire message.
    static let submissionDataBufferBytes = 64 * 1_024

    /// Execute one command of the submission dialogue.
    ///
    /// Differs from ``executeCommand(_:)`` in three ways that the outcome
    /// classification depends on:
    /// - errors are rethrown untouched (no re-wrapping into
    ///   `SMTPError.connectionFailed`), so the classifier sees original types;
    /// - upload and response timeouts fail with the internal marker
    ///   `SMTPSubmissionTimeoutError` instead of a string-only error;
    /// - the response budget starts only after the command has been flushed,
    ///   so message upload time cannot consume the final-reply budget;
    /// - awaiting the reply is cancellation-aware: `EventLoopFuture.get()`
    ///   ignores task cancellation, so without this a task cancelled after the
    ///   content terminator would silently keep waiting and could even return
    ///   success. Cancellation fails the pending promise immediately; the
    ///   caller then classifies the outcome and closes the connection.
    func executeSubmissionCommand<CommandType: SMTPCommand>(
        _ command: CommandType,
        writeTimeout: TimeInterval,
        responseTimeout: TimeInterval,
        writeTimeoutStage: SMTPSendError.TimeoutStage = .commandWrite,
        responseTimeoutStage: SMTPSendError.TimeoutStage = .commandResponse,
        contentDispatchState: SMTPSubmissionContentDispatchState? = nil
    ) async throws -> CommandType.ResultType {
        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }

        try command.validate()

        let resultPromise = channel.eventLoop.makePromise(of: CommandType.ResultType.self)
        let commandTag = UUID().uuidString
        let commandData = command.toCommandData()
        let handler = command.makeHandler(commandTag: commandTag, promise: resultPromise)

        do {
            try await channel.pipeline.addHandler(handler).get()

            // Send the command as bounded buffers. Each successful flush
            // advances progress and starts a fresh RFC 5321 upload budget for
            // the next buffer instead of timing one monolithic DATA write.
            try await flushSubmissionData(
                commandData,
                through: channel,
                timeout: writeTimeout,
                timeoutStage: writeTimeoutStage,
                contentDispatchState: contentDispatchState
            )

            // Start the response budget only after the command bytes have
            // flushed. In particular, a large DATA upload cannot consume the
            // server's separate final-acceptance-reply allowance.
            let responseTimeoutTask = channel.eventLoop.scheduleTask(
                in: Self.nioTimeAmount(seconds: responseTimeout)
            ) {
                resultPromise.fail(SMTPSubmissionTimeoutError(stage: responseTimeoutStage))
            }
            defer { responseTimeoutTask.cancel() }

            let result = try await withTaskCancellationHandler {
                try await resultPromise.futureResult.get()
            } onCancel: {
                resultPromise.fail(CancellationError())
            }
            duplexLogger.flushInboundBuffer()
            return result
        } catch {
            // Ensure the promise is resolved to prevent NIO "leaking promise" fatal error
            resultPromise.fail(error)
            duplexLogger.flushInboundBuffer()
            throw error
        }
    }

    private func flushSubmissionData(
        _ data: Data,
        through channel: Channel,
        timeout: TimeInterval,
        timeoutStage: SMTPSendError.TimeoutStage,
        contentDispatchState: SMTPSubmissionContentDispatchState?
    ) async throws {
        var index = data.startIndex

        repeat {
            try Task.checkCancellation()

            let remaining = data.distance(from: index, to: data.endIndex)
            let contentCount = min(Self.submissionDataBufferBytes, remaining)
            let nextIndex = data.index(index, offsetBy: contentCount)
            let isFinalBuffer = nextIndex == data.endIndex

            var buffer = channel.allocator.buffer(
                capacity: contentCount + (isFinalBuffer ? 2 : 0)
            )
            if contentCount > 0 {
                buffer.writeBytes(data[index..<nextIndex])
            }
            if isFinalBuffer {
                buffer.writeBytes([0x0D, 0x0A]) // CRLF
            }

            try await flushSubmissionBuffer(
                buffer,
                through: channel,
                timeout: timeout,
                timeoutStage: timeoutStage,
                contentDispatchState: contentDispatchState
            )
            index = nextIndex
        } while index != data.endIndex
    }

    private func flushSubmissionBuffer(
        _ buffer: ByteBuffer,
        through channel: Channel,
        timeout: TimeInterval,
        timeoutStage: SMTPSendError.TimeoutStage,
        contentDispatchState: SMTPSubmissionContentDispatchState?
    ) async throws {
        let resolution = SMTPSubmissionWriteResolution()
        let completionPromise = channel.eventLoop.makePromise(of: Void.self)
        let timeoutTask = channel.eventLoop.scheduleTask(
            in: Self.nioTimeAmount(seconds: timeout)
        ) {
            if resolution.claim() {
                completionPromise.fail(SMTPSubmissionTimeoutError(stage: timeoutStage))
            }
        }

        let writeFuture: EventLoopFuture<Void> = channel.writeAndFlush(buffer)
        // Record only after the buffer has actually been handed to NIO. A
        // cancellation caught before this call remains provably pre-content.
        contentDispatchState?.markContentDispatched()
        writeFuture.whenComplete { result in
            if resolution.claim() {
                timeoutTask.cancel()
                completionPromise.completeWith(result)
            }
        }

        try await withTaskCancellationHandler {
            try await completionPromise.futureResult.get()
        } onCancel: {
            if resolution.claim() {
                timeoutTask.cancel()
                completionPromise.fail(CancellationError())
            }
        }
    }

    private static func nioTimeAmount(seconds: TimeInterval) -> TimeAmount {
        let nanoseconds = seconds * 1_000_000_000
        return .nanoseconds(Int64(nanoseconds.rounded(.up)))
    }
}
