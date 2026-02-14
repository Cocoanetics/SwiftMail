import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Command for appending a message to a mailbox.
struct AppendCommand: IMAPCommand {
    typealias ResultType = AppendResult
    typealias HandlerType = AppendHandler

    let mailboxName: String
    let message: String
    let flags: [Flag]
    let internalDate: ServerMessageDate?

    var timeoutSeconds: Int { return 30 }

    func validate() throws {
        guard !mailboxName.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name must not be empty")
        }
    }

    func send(on channel: Channel, tag: String) async throws {
        var messageBuffer = channel.allocator.buffer(capacity: message.utf8.count)
        messageBuffer.writeString(message)

        var mailboxBuffer = channel.allocator.buffer(capacity: mailboxName.utf8.count)
        mailboxBuffer.writeString(mailboxName)
        let mailbox = MailboxName(mailboxBuffer)

        let nioFlags = flags.map { $0.toNIO() }
        let appendOptions = AppendOptions(flagList: nioFlags, internalDate: internalDate)
        let metadata = AppendMessage(options: appendOptions, data: AppendData(byteCount: messageBuffer.readableBytes))

        channel.write(IMAPClientHandler.OutboundIn.part(.append(.start(tag: tag, appendingTo: mailbox))), promise: nil)
        channel.write(IMAPClientHandler.OutboundIn.part(.append(.beginMessage(message: metadata))), promise: nil)
        // Flush APPEND metadata first so servers can respond with literal continuation.
        channel.flush()

        // Do not await write promises here. These writes may be continuation-gated by the IMAP state machine,
        // and awaiting them can deadlock this command send path until timeout.
        channel.write(IMAPClientHandler.OutboundIn.part(.append(.messageBytes(messageBuffer))), promise: nil)
        channel.write(IMAPClientHandler.OutboundIn.part(.append(.endMessage)), promise: nil)
        channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.append(.finish)), promise: nil)
    }
}
