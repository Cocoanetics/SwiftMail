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
public final class ListCommandHandler: BaseIMAPCommandHandler<[Mailbox.Info]>, IMAPCommandHandler, @unchecked Sendable {
    public typealias ResultType = [Mailbox.Info]
    public typealias InboundIn = Response
    public typealias InboundOut = Never
    
    private var mailboxes: [NIOIMAPCore.MailboxInfo] = []
    
	public override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        
        switch response {
        case .tagged(let tagged) where tagged.tag == commandTag:
            handleTaggedResponse(tagged)
            context.pipeline.removeHandler(self, promise: nil)
        case .untagged(let untagged):
            if case .mailboxData(.list(let info)) = untagged {
                mailboxes.append(info)
            }
            context.fireChannelRead(data)
        default:
            context.fireChannelRead(data)
        }
    }
    
	public override func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }
    
    private func handleTaggedResponse(_ response: TaggedResponse) {
        switch response.state {
        case .ok:
            // Convert NIOIMAPCore.MailboxInfo to our Mailbox.Info
            let convertedMailboxes = mailboxes.map { Mailbox.Info(from: $0) }
            promise.succeed(convertedMailboxes)
        case .no, .bad:
            promise.fail(IMAPError.commandFailed("List command failed"))
        }
    }
} 
