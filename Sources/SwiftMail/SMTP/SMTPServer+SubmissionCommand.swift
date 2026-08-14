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
    private enum EndOfDataWriteState {
        case notStarted
        case inFlight
        case succeeded
        case failed
    }

    private let lock = NIOLock()
    private var endOfDataWriteState = EndOfDataWriteState.notStarted

    var endOfDataMayHaveBeenDispatched: Bool {
        lock.withLock {
            switch endOfDataWriteState {
                case .inFlight, .succeeded:
                    return true
                case .notStarted, .failed:
                    return false
            }
        }
    }

    func beginEndOfDataWrite() {
        lock.withLock {
            endOfDataWriteState = .inFlight
        }
    }

    func completeEndOfDataWrite(succeeded: Bool) {
        lock.withLock {
            endOfDataWriteState = succeeded ? .succeeded : .failed
        }
    }
}

private struct SMTPSubmissionWriteContext {
    let channel: Channel
    let permit: SMTPOperationGate.Permit
    let timeout: TimeInterval
    let timeoutStage: SMTPSendError.TimeoutStage
    let contentDispatchState: SMTPSubmissionContentDispatchState?
}

struct SMTPSubmissionBufferPlan: Equatable, Sendable {
    let offset: Int
    let count: Int
    let isFinal: Bool
}

extension SMTPServer {
    /// Keep DATA writes bounded so RFC 5321's per-buffer upload timeout grows
    /// naturally with message size instead of timing the entire message.
    static let submissionDataBufferBytes = 64 * 1_024

    /// Execute one command of the submission dialogue.
    ///
    /// Differs from ``executeCommand(_:)`` in four ways that the outcome
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
        holding permit: SMTPOperationGate.Permit,
        writeTimeout: TimeInterval,
        responseTimeout: TimeInterval,
        writeTimeoutStage: SMTPSendError.TimeoutStage = .commandWrite,
        responseTimeoutStage: SMTPSendError.TimeoutStage = .commandResponse,
        contentDispatchState: SMTPSubmissionContentDispatchState? = nil
    ) async throws -> CommandType.ResultType {
        precondition(operationGate.isHeld(permit), "SMTP submission command executed without owning the channel")

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
            let writeContext = SMTPSubmissionWriteContext(
                channel: channel,
                permit: permit,
                timeout: writeTimeout,
                timeoutStage: writeTimeoutStage,
                contentDispatchState: contentDispatchState
            )
            try await flushSubmissionData(
                commandData,
                context: writeContext
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
        context: SMTPSubmissionWriteContext
    ) async throws {
        for plannedBuffer in Self.submissionBufferPlan(dataByteCount: data.count) {
            try Task.checkCancellation()

            let lowerBound = data.index(data.startIndex, offsetBy: plannedBuffer.offset)
            let upperBound = data.index(lowerBound, offsetBy: plannedBuffer.count)

            var buffer = context.channel.allocator.buffer(
                capacity: plannedBuffer.count + (plannedBuffer.isFinal ? 2 : 0)
            )
            if plannedBuffer.count > 0 {
                buffer.writeBytes(data[lowerBound..<upperBound])
            }
            if plannedBuffer.isFinal {
                buffer.writeBytes([0x0D, 0x0A]) // CRLF
            }

            try await flushSubmissionBuffer(
                buffer,
                context: context,
                dispatchesEndOfData: plannedBuffer.isFinal
            )
        }
    }

    static func submissionBufferPlan(dataByteCount: Int) -> [SMTPSubmissionBufferPlan] {
        precondition(dataByteCount >= 0, "SMTP submission byte count cannot be negative")
        var result: [SMTPSubmissionBufferPlan] = []
        var offset = 0

        repeat {
            let count = min(submissionDataBufferBytes, dataByteCount - offset)
            let nextOffset = offset + count
            result.append(SMTPSubmissionBufferPlan(
                offset: offset,
                count: count,
                isFinal: nextOffset == dataByteCount
            ))
            offset = nextOffset
        } while offset != dataByteCount

        return result
    }

    private func flushSubmissionBuffer(
        _ buffer: ByteBuffer,
        context: SMTPSubmissionWriteContext,
        dispatchesEndOfData: Bool
    ) async throws {
        precondition(operationGate.isHeld(context.permit), "SMTP buffer written without owning the channel")
        let resolution = SMTPSubmissionWriteResolution()
        let completionPromise = context.channel.eventLoop.makePromise(of: Void.self)
        let timeoutTask = context.channel.eventLoop.scheduleTask(
            in: Self.nioTimeAmount(seconds: context.timeout)
        ) {
            if resolution.claim() {
                completionPromise.fail(SMTPSubmissionTimeoutError(stage: context.timeoutStage))
            }
        }

        // Once the final write is in flight, a timeout or cancellation cannot
        // prove whether the terminator reached the server. Only a write failure
        // that wins this buffer's resolution race proves non-acceptance.
        if dispatchesEndOfData {
            context.contentDispatchState?.beginEndOfDataWrite()
        }
        let writeFuture: EventLoopFuture<Void> = context.channel.writeAndFlush(buffer)
        writeFuture.whenComplete { result in
            if resolution.claim() {
                timeoutTask.cancel()
                if dispatchesEndOfData {
                    let writeSucceeded: Bool
                    switch result {
                        case .success:
                            writeSucceeded = true
                        case .failure:
                            writeSucceeded = false
                    }
                    context.contentDispatchState?.completeEndOfDataWrite(
                        succeeded: writeSucceeded
                    )
                }
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
