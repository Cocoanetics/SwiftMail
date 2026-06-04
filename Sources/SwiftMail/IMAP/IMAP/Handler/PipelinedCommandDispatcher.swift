// PipelinedCommandDispatcher.swift
// NIO channel handler that routes responses to multiple in-flight pipelined command handlers.
//
// IMAP RFC 3501 §5.5 allows clients to send multiple commands without waiting for responses.
// The server processes commands in order and sends tagged responses (A001 OK, A002 OK, etc.)
// so responses can be matched to commands by tag. Untagged responses (e.g., * FETCH data)
// carry no tag; they arrive in command order and are routed to the oldest command whose
// untagged response has not yet finished, advancing on each response's `.finish`. A server
// may stream data for several pipelined commands before sending any tagged OK (RFC 3501
// §5.5), so advancing only on the tagged OK would misdeliver a later command's data to an
// already-finished earlier handler and silently drop it.
//
// This handler sits in the NIO pipeline during a pipelined batch. It maintains an ordered
// registry of (tag → PipelinedHandler) and routes responses accordingly.

import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

final class PipelinedCommandDispatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias InboundOut = Response

    private let lock = NIOLock()

    /// A registered pipelined command awaiting its responses. `finishedUntagged` flips
    /// once this command's untagged FETCH response has fully arrived (its `.finish`), so
    /// subsequent untagged data routes to the next command even before any tagged OK.
    private struct PendingCommand {
        let tag: String
        let handler: any PipelinedHandler
        var finishedUntagged: Bool
    }

    /// Ordered registry — insertion order matches send order. Untagged FETCH responses
    /// route to the oldest entry whose untagged response has not finished.
    private var entries: [PendingCommand] = []

    private let logger = Logger(label: "com.cocoanetics.SwiftMail.PipelinedDispatcher")

    /// Register a handler for a command tag. Must be called in send order.
    func register(tag: String, handler: any PipelinedHandler) {
        lock.withLock {
            entries.append(PendingCommand(tag: tag, handler: handler, finishedUntagged: false))
        }
    }

    // MARK: - ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)

        lock.withLock {
            switch response {
                case .tagged(let taggedResponse):
                    // Route to the handler that owns this tag
                    if let idx = entries.firstIndex(where: { $0.tag == taggedResponse.tag }) {
                        let handler = entries[idx].handler
                        handler.processTaggedResponse(taggedResponse)
                        entries.remove(at: idx)
                    }

                case .fetch(let fetchResponse):
                    routeUntaggedFetch(fetchResponse)

                case .untagged(let payload):
                    // BYE — server is terminating. Fail all pending handlers.
                    if case .conditionalState(let status) = payload, case .bye(let text) = status {
                        failAllPending(IMAPError.connectionFailed("Server terminated connection: \(text.text)"))
                    }

                case .fatal(let text):
                    failAllPending(IMAPError.connectionFailed("Server fatal error: \(text.text)"))

                default:
                    break
            }
        }

        // Always forward to the next handler in the pipeline (UntaggedResponseBuffer)
        context.fireChannelRead(data)
    }

    /// Route an untagged FETCH response to the oldest command whose untagged response has
    /// not yet finished, marking it finished when its `.finish` arrives so the next response
    /// routes to the next command. A server may emit untagged data for several pipelined
    /// commands before any tagged OK (RFC 3501 §5.5); routing on the first entry and advancing
    /// only on the tagged OK would misdeliver a later part's bytes to an already-finished
    /// earlier handler — which drops them — leaving the later part (e.g. a multipart message's
    /// text/html body) empty. Caller holds `lock`.
    private func routeUntaggedFetch(_ fetchResponse: FetchResponse) {
        guard let idx = entries.firstIndex(where: { !$0.finishedUntagged }) else { return }
        entries[idx].handler.processFetchResponse(fetchResponse)
        if case .finish = fetchResponse {
            entries[idx].finishedUntagged = true
        }
    }

    /// Fail every pending handler and clear the registry. Caller holds `lock`.
    private func failAllPending(_ error: Error) {
        for entry in entries {
            entry.handler.fail(error)
        }
        entries.removeAll()
    }

    func channelInactive(context: ChannelHandlerContext) {
        let error = IMAPError.connectionFailed("Connection closed during pipelined fetch")
        lock.withLock {
            failAllPending(error)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.withLock {
            failAllPending(error)
        }
        context.fireErrorCaught(error)
    }

    /// Number of handlers still pending (for diagnostics).
    var pendingCount: Int {
        lock.withLock { entries.count }
    }
}
