import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO
import os.log

/// Command to list all available mailboxes
struct ListCommand: IMAPCommand {
    typealias ResultType = [Mailbox.Info]
    typealias HandlerType = ListCommandHandler
    
    let timeoutSeconds: Int = 30
    
    var handlerType: HandlerType.Type {
        return ListCommandHandler.self
    }
    
    func validate() throws {
        // No validation needed for LIST command
    }
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
        // LIST "" "*" - List all mailboxes
        let reference = MailboxName(ByteBuffer(string: ""))
        let pattern = MailboxPatterns.pattern([ByteBuffer(string: "*")])
        return TaggedCommand(tag: tag, command: .list(nil, reference: reference, pattern))
    }
}

/// Handler for processing LIST command responses
final class ListCommandHandler: IMAPCommandHandler, RemovableChannelHandler {
    typealias ResultType = [Mailbox.Info]
    typealias InboundIn = Response
    typealias InboundOut = Never
    
    private var mailboxes: [NIOIMAPCore.MailboxInfo] = []
    private let promise: EventLoopPromise<[Mailbox.Info]>
    private let logger: Logger
    private var timeoutTask: Scheduled<Void>?
    private let commandTag: String
    private let timeoutSeconds: Int
    
    required init(commandTag: String, promise: EventLoopPromise<[Mailbox.Info]>, timeoutSeconds: Int, logger: Logger?) {
        self.commandTag = commandTag
        self.promise = promise
        self.timeoutSeconds = timeoutSeconds
        self.logger = logger ?? Logger(subsystem: "com.cocoanetics.SwiftIMAP", category: "ListCommandHandler")
    }
    
    static func createHandler(commandTag: String, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int, logger: Logger) -> Self {
        return self.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    func setupTimeout(on eventLoop: EventLoop) {
        guard timeoutSeconds > 0 else { return }
        
        timeoutTask = eventLoop.scheduleTask(in: .seconds(Int64(timeoutSeconds))) { [weak self] in
            guard let self = self else { return }
            self.promise.fail(IMAPError.timeout)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
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
    
    func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }
} 