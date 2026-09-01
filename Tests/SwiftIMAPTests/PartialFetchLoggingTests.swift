import Logging
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite("Partial BODY.PEEK diagnostic bounds")
struct PartialFetchLoggingTests {
    @Test("Diagnostics stay bounded and reset after flushing")
    func boundedDiagnostics() throws {
        let logger = IMAPLogger(
            outboundLogger: Logger(label: "partial-fetch-test.out"),
            inboundLogger: Logger(label: "partial-fetch-test.in")
        )
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(logger)
        var fragment = ByteBufferAllocator().buffer(capacity: 1)
        fragment.writeString("x")
        for _ in 0..<10_000 {
            try channel.writeInbound(Response.fetch(.streamingBytes(fragment)))
            _ = try channel.readInbound(as: Response.self)
        }
        #expect(logger.inboundBuffer.isEmpty)

        for _ in 0..<1_000 {
            try channel.writeInbound(Response.untagged(.mailboxData(.sort([2, 1], 1))))
            _ = try channel.readInbound(as: Response.self)
        }
        #expect(logger.inboundBuffer.count <= MailLogger.maximumInboundBufferEntries)
        #expect(logger.inboundBufferByteCount <= MailLogger.maximumInboundBufferBytes)
        #expect(logger.droppedInboundResponseCount > 0)

        logger.flushInboundBuffer()
        #expect(logger.inboundBuffer.isEmpty)
        #expect(logger.inboundBufferByteCount == 0)
        #expect(logger.droppedInboundResponseCount == 0)
        logger.bufferInboundResponse("fresh")
        #expect(logger.inboundBuffer == ["fresh"])
        logger.flushInboundBuffer()

        logger.bufferInboundResponse(String(repeating: "é", count: 40_000))
        #expect(logger.inboundBuffer.isEmpty)
        #expect(logger.inboundBufferByteCount == 0)
        #expect(logger.droppedInboundResponseCount == 1)
        #expect(logger.hasBufferedMessages())
        logger.flushInboundBuffer()
        #expect(logger.droppedInboundResponseCount == 0)
        #expect(!logger.hasBufferedMessages())

        let mediumMessage = String(repeating: "x", count: 40 * 1024)
        logger.bufferInboundResponse(mediumMessage)
        logger.bufferInboundResponse(mediumMessage)
        #expect(logger.inboundBuffer == [mediumMessage])
        #expect(logger.inboundBufferByteCount == mediumMessage.utf8.count)
        #expect(logger.droppedInboundResponseCount == 1)
        logger.flushInboundBuffer()
        _ = try channel.finish()
    }
}
