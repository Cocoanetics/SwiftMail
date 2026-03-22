import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

struct PlainAuthenticationTests {

    // MARK: - Credential buffer format

    @Test
    func testPlainCredentialBufferFormat() async throws {
        // RFC 4616: message = [authzid] UTF8NUL authcid UTF8NUL passwd
        // We use empty authzid, so: \0 username \0 password
        let channel = NIOAsyncTestingChannel()

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.writeInteger(UInt8(0x00))
        buffer.writeString("user@example.com")
        buffer.writeInteger(UInt8(0x00))
        buffer.writeString("s3cret")

        let bytes = buffer.readableBytesView
        #expect(bytes.first == 0x00)

        // Find second NUL
        let secondNulIndex = bytes.dropFirst().firstIndex(of: 0x00)!
        let username = String(bytes: bytes[bytes.startIndex + 1 ..< secondNulIndex], encoding: .utf8)
        let password = String(bytes: bytes[secondNulIndex + 1 ..< bytes.endIndex], encoding: .utf8)

        #expect(username == "user@example.com")
        #expect(password == "s3cret")
    }

    // MARK: - Handler tests

    @Test
    func testHandlerSucceedsOnTaggedOK() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: [Capability].self)
        var creds = channel.allocator.buffer(capacity: 10)
        creds.writeString("\0user\0pass")

        let handler = PlainAuthenticationHandler(
            commandTag: "A001",
            promise: promise,
            credentials: creds,
            expectsChallenge: false
        )
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        var okBuffer = channel.allocator.buffer(capacity: 64)
        okBuffer.writeString("A001 OK AUTHENTICATE completed\r\n")
        try await channel.writeInbound(okBuffer)

        let caps = try await promise.futureResult.get()
        #expect(caps.isEmpty)
    }

    @Test
    func testHandlerFailsOnTaggedNO() async throws {
        let channel = NIOAsyncTestingChannel()

        try await channel.pipeline.addHandler(IMAPClientHandler())

        let promise = channel.eventLoop.makePromise(of: [Capability].self)
        var creds = channel.allocator.buffer(capacity: 10)
        creds.writeString("\0user\0wrongpass")

        let handler = PlainAuthenticationHandler(
            commandTag: "A002",
            promise: promise,
            credentials: creds,
            expectsChallenge: false
        )
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A002", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        var noBuffer = channel.allocator.buffer(capacity: 64)
        noBuffer.writeString("A002 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
        try await channel.writeInbound(noBuffer)

        do {
            _ = try await promise.futureResult.get()
            Issue.record("Expected auth failure")
        } catch {
            #expect(error is IMAPError)
        }
    }
}
