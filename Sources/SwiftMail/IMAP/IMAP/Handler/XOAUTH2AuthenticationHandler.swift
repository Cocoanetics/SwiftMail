import Foundation
import Logging
import NIO
import NIOIMAP
import NIOIMAPCore

/// Handler responsible for managing the IMAP XOAUTH2 authentication exchange.
final class XOAUTH2AuthenticationHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler, @unchecked Sendable {
    private var collectedCapabilities: [Capability] = []
    private var shouldSendCredentialsOnChallenge: Bool
    private var credentials: ByteBuffer
    private let sentInlineInitialResponse: Bool
    private let serverLogger: Logger
    private var lastServerError: String?
    private var fallbackContinuationSent = false

    init(
        commandTag: String,
        promise: EventLoopPromise<[Capability]>,
        credentials: ByteBuffer,
        expectsChallenge: Bool,
        logger: Logger
    ) {
        self.credentials = credentials
        self.shouldSendCredentialsOnChallenge = expectsChallenge
        self.serverLogger = logger
        self.sentInlineInitialResponse = !expectsChallenge
        super.init(commandTag: commandTag, promise: promise)
    }

    override init(commandTag: String, promise: EventLoopPromise<[Capability]>) {
        fatalError("Use init(commandTag:promise:credentials:expectsChallenge:logger:) instead")
    }

    override func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)

        if case .authenticationChallenge(var challengeBuffer) = response {
            handleAuthenticationChallenge(&challengeBuffer, context: context)
        }

        super.channelRead(context: context, data: data)
    }

    private func handleAuthenticationChallenge(_ challenge: inout ByteBuffer, context: ChannelHandlerContext) {
        let challengeText = challenge.getString(at: challenge.readerIndex, length: challenge.readableBytes) ?? ""
        let challengeIsEmpty = challengeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let sendCredentials = lock.withLock { () -> Bool in
            if shouldSendCredentialsOnChallenge {
                shouldSendCredentialsOnChallenge = false
                return true
            }

            // Compatibility fallback: some servers advertise SASL-IR but still emit an
            // empty continuation before consuming credentials. Allow one retry.
            if sentInlineInitialResponse && !fallbackContinuationSent && challengeIsEmpty {
                fallbackContinuationSent = true
                return true
            }
            return false
        }

        if sendCredentials {
            let credentialBuffer = credentials
            credentials = context.channel.allocator.buffer(capacity: 0)

            context.channel
                .writeAndFlush(IMAPClientHandler.OutboundIn.part(.continuationResponse(credentialBuffer)))
                .cascadeFailure(to: promise)
            return
        }

        if !challengeText.isEmpty {
            lock.withLock { lastServerError = challengeText }
            serverLogger.error("XOAUTH2 server error: \(challengeText)")
        } else {
            lock.withLock { lastServerError = nil }
        }

        let emptyBuffer = context.channel.allocator.buffer(capacity: 0)
        context.channel
            .writeAndFlush(IMAPClientHandler.OutboundIn.part(.continuationResponse(emptyBuffer)))
            .cascadeFailure(to: promise)
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)

        let capabilities = lock.withLock { collectedCapabilities }
        if !capabilities.isEmpty {
            succeedWithResult(capabilities)
        } else if case .ok(let responseText) = response.state,
                  let code = responseText.code,
                  case .capability(let caps) = code {
            succeedWithResult(caps)
        } else {
            succeedWithResult([])
        }
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        let summary = String(describing: response.state)
        let serverMessage = lock.withLock { lastServerError }
        if let serverMessage, !serverMessage.isEmpty {
            failWithError(IMAPError.authFailed("\(summary) (\(serverMessage))"))
        } else {
            failWithError(IMAPError.authFailed(summary))
        }
    }

    override func handleError(_ error: Error) {
        failWithError(error)
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if super.handleUntaggedResponse(response) {
            return true
        }

        switch response {
        case .untagged(.capabilityData(let capabilities)):
            lock.withLock { collectedCapabilities = capabilities }
        default:
            break
        }

        return false
    }
}
