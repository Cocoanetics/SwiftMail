import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RenameDeleteMailboxCommandTests {
    @Test
    func renameRejectsEmptyOrEqualNames() {
        #expect(throws: IMAPError.self) { try RenameMailboxCommand(from: "", to: "B").validate() }
        #expect(throws: IMAPError.self) { try RenameMailboxCommand(from: "A", to: "").validate() }
        #expect(throws: IMAPError.self) { try RenameMailboxCommand(from: "A", to: "A").validate() }
    }

    @Test
    func deleteRejectsEmptyName() {
        #expect(throws: IMAPError.self) { try DeleteMailboxCommand(mailboxName: "").validate() }
    }

    @Test
    func serializesRename() async throws {
        let command = RenameMailboxCommand(from: "Folders/Work", to: "Folders/Job")
        let wire = try await Self.wire(command.toTaggedCommand(tag: "R001"))
        #expect(wire == "R001 RENAME \"Folders/Work\" \"Folders/Job\"\r\n")
    }

    @Test
    func serializesDelete() async throws {
        let wire = try await Self.wire(DeleteMailboxCommand(mailboxName: "Folders/Old").toTaggedCommand(tag: "D001"))
        #expect(wire == "D001 DELETE \"Folders/Old\"\r\n")
    }

    private static func wire(_ tagged: TaggedCommand) async throws -> String? {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged)))
        guard var buffer = try await channel.readOutbound(as: ByteBuffer.self) else { return nil }
        return buffer.readString(length: buffer.readableBytes)
    }
}
