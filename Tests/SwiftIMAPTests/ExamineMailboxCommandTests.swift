import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ExamineMailboxCommandTests {
    @Test
    func rejectsEmptyMailboxName() {
        let command = ExamineMailboxCommand(mailboxName: "")

        #expect(throws: IMAPError.self) {
            try command.validate()
        }
    }

    @Test
    func serializesExamineRatherThanSelect() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let command = ExamineMailboxCommand(mailboxName: "INBOX")
        let tagged = command.toTaggedCommand(tag: "E001")
        let outbound = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))

        try await channel.writeAndFlush(outbound)

        guard var buffer = try await channel.readOutbound(as: ByteBuffer.self) else {
            Issue.record("Expected outbound bytes")
            return
        }
        let wire = buffer.readString(length: buffer.readableBytes)

        #expect(wire == "E001 EXAMINE \"INBOX\"\r\n")
        #expect(wire?.contains("SELECT") == false)
    }
}
