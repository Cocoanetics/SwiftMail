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

        try await channel.write(IMAPClientHandler.OutboundIn.part(.append(.start(tag: tag, appendingTo: mailbox)))).get()
        // Flush APPEND metadata before waiting on message-bytes write completion.
        // Otherwise the server never receives the literal header and cannot send continuation.
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.append(.beginMessage(message: metadata)))).get()
        try await channel.write(IMAPClientHandler.OutboundIn.part(.append(.messageBytes(messageBuffer)))).get()
        try await channel.write(IMAPClientHandler.OutboundIn.part(.append(.endMessage))).get()
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.append(.finish))).get()
    }
}
