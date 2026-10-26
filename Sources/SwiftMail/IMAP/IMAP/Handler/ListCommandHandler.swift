//
//  ListCommandHandler.swift
//  SwiftIMAP
//
//  Created by Oliver Drobnik on 04.03.25.
//

import Foundation
import NIOIMAPCore
import NIO
import Logging

/// Handler for processing LIST command responses
final class ListCommandHandler: BaseIMAPCommandHandler<[Mailbox.Info]>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = [Mailbox.Info]
    typealias InboundIn = Response
    typealias InboundOut = Never

    private var mailboxes: [NIOIMAPCore.MailboxInfo] = []

    /// Shared with the listing's other LIST commands; see ``ListResponseBudget``.
    private let budget: ListResponseBudget

    /// Set once the budget is exhausted: nothing read afterwards is kept or passed on.
    private var exceededBudget = false

    init(commandTag: String, promise: EventLoopPromise<[Mailbox.Info]>, budget: ListResponseBudget) {
        self.budget = budget
        super.init(commandTag: commandTag, promise: promise)
    }

    override init(commandTag: String, promise: EventLoopPromise<[Mailbox.Info]>) {
        self.budget = ListResponseBudget(maximumCount: .max)
        super.init(commandTag: commandTag, promise: promise)
    }

    override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Responses the same network read already decoded keep arriving until the close lands.
        guard !exceededBudget else { return }

        let response = self.unwrapInboundIn(data)

        switch response {
            case .tagged(let tagged) where tagged.tag == commandTag:
                handleTaggedResponse(tagged)
                context.pipeline.removeHandler(self, promise: nil)
            case .untagged(let untagged):
                if case .mailboxData(.list(let info)) = untagged {
                    do {
                        try budget.consume()
                    } catch {
                        failClosed(context: context, error: error)
                        return
                    }
                    mailboxes.append(info)
                }
                context.fireChannelRead(data)
            default:
                context.fireChannelRead(data)
        }
    }

    override func errorCaught(context: ChannelHandlerContext, error: Error) {
        failWithError(error)
        context.fireErrorCaught(error)
    }

    /// Fails the listing rather than return part of it, and closes the connection: like a parser
    /// limit, a server that sends more than allowed is not read from any further.
    private func failClosed(context: ChannelHandlerContext, error: Error) {
        exceededBudget = true
        mailboxes.removeAll()
        logger.warning("LIST response limit exceeded, closing connection: \(error)")
        failWithError(error)
        context.close(promise: nil)
    }

    private func handleTaggedResponse(_ response: TaggedResponse) {
        switch response.state {
            case .ok:
                // Convert NIOIMAPCore.MailboxInfo to our Mailbox.Info
                let convertedMailboxes = mailboxes.map { Mailbox.Info(nio: $0) }
                succeedWithResult(convertedMailboxes)
            case .no, .bad:
                failWithError(IMAPError.commandFailed("List command failed"))
        }
    }
}
