import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct UntaggedResponseBufferTests {
    @Test
    func testTracksBufferedByeAsTerminationSignal() async throws {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()

        let buffer = UntaggedResponseBuffer()
        try await channel.pipeline.addHandler(buffer)

        var byeLine = channel.allocator.buffer(capacity: 0)
        byeLine.writeString("* BYE connection timeout\r\n")
        try await channel.writeInbound(byeLine)

        #expect(buffer.hasBufferedConnectionTermination)

        let reasons = buffer.consumeBufferedConnectionTerminationReasons()
        #expect(reasons.count == 1)
        #expect(reasons[0].contains("timeout"))

        #expect(!buffer.hasBufferedConnectionTermination)
    }
}
