import Foundation
import NIOIMAPCore
import NIO
import os.log

/** Handler for the CLOSE command */
final class CloseHandler: IMAPCommandHandler {
    typealias ResultType = Void
    typealias InboundIn = Response
    typealias InboundOut = Never
    
    private let promise: EventLoopPromise<Void>
    private let commandTag: String
    private let logger: Logger
    private var scheduledTask: Scheduled<Void>?
    
    static func createHandler(commandTag: String, promise: EventLoopPromise<ResultType>, timeoutSeconds: Int, logger: Logger) -> Self {
        return self.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds, logger: logger)
    }
    
    init(commandTag: String, promise: EventLoopPromise<Void>, timeoutSeconds: Int, logger: Logger) {
        self.promise = promise
        self.commandTag = commandTag
        self.logger = logger
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        handleResponse(response)
    }
    
    func handleResponse(_ response: Response) {
        switch response {
            case .tagged(let tagged) where tagged.tag == commandTag:
                switch tagged.state {
                    case .ok:
                        promise.succeed(())
                    case .no(let text):
                        promise.fail(IMAPError.commandFailed("NO response: \(text)"))
                    case .bad(let text):
                        promise.fail(IMAPError.commandFailed("BAD response: \(text)"))
                }
                
            case .tagged, .untagged, .fatal, .fetch, .authenticationChallenge, .idleStarted:
                break // Ignore other responses
        }
    }
    
    func handleTimeout() {
        promise.fail(IMAPError.timeout)
    }
    
    func cancelTimeout() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
    
    func setupTimeout(on eventLoop: EventLoop) {
        let deadline = NIODeadline.now() + .seconds(5)
        scheduledTask = eventLoop.scheduleTask(deadline: deadline) { [weak self] in
            self?.handleTimeout()
        }
    }
} 