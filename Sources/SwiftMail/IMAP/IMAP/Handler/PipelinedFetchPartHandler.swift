// PipelinedFetchPartHandler.swift
// Lightweight handler for pipelined fetch-part commands.
// Managed by PipelinedCommandDispatcher — not added to the NIO pipeline directly.

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Protocol for handlers managed by PipelinedCommandDispatcher.
protocol PipelinedHandler: AnyObject, Sendable {
    /// Process an untagged FETCH response (data streaming).
    func processFetchResponse(_ response: FetchResponse)
    /// Process the tagged OK/NO/BAD response that completes this command.
    func processTaggedResponse(_ response: TaggedResponse)
    /// Fail this handler (channel closed, timeout, etc.).
    /// Safe to call multiple times — only the first call resolves the promise.
    func fail(_ error: Error)
}

/// Collects streaming body-part data for a single pipelined FETCH BODY[section] command.
/// Similar to `FetchPartHandler` but not a NIO handler — managed by the dispatcher.
///
/// Thread safety: all mutable state is protected by `lock`. The lock is held for the
/// entire duration of `processFetchResponse` to prevent races between EventLoop
/// callbacks (streaming data) and async callers (timeout/fail).
final class PipelinedFetchPartHandler: PipelinedHandler, @unchecked Sendable {
    let promise: EventLoopPromise<Data>
    private let lock = NIOLock()
    private var partData = Data()
    private var isCompleted = false
    private var didFinishPart = false

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func processFetchResponse(_ response: FetchResponse) {
        lock.withLock {
            guard !isCompleted, !didFinishPart else { return }
            switch response {
            case .start:
                partData.removeAll(keepingCapacity: true)

            case .streamingBegin:
                break

            case .streamingBytes(let buffer):
                partData.append(Data(buffer.readableBytesView))

            case .finish:
                didFinishPart = true

            case .simpleAttribute:
                break

            default:
                break
            }
        }
    }

    func processTaggedResponse(_ response: TaggedResponse) {
        let (data, shouldSucceed) = lock.withLock { () -> (Data, Bool) in
            guard !isCompleted else { return (Data(), false) }
            isCompleted = true
            return (partData, true)
        }
        guard shouldSucceed else { return }

        if case .ok = response.state {
            promise.succeed(data)
        } else {
            promise.fail(IMAPError.fetchFailed(String(describing: response.state)))
        }
    }

    func fail(_ error: Error) {
        let shouldFail = lock.withLock { () -> Bool in
            guard !isCompleted else { return false }
            isCompleted = true
            return true
        }
        guard shouldFail else { return }
        promise.fail(error)
    }
}
