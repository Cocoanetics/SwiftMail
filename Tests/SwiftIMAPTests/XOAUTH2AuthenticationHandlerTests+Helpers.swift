import Foundation
import Logging
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
@testable import SwiftMail

struct XOAUTH2TimeoutError: Error {}

final class XOAUTH2FailContinuationWriteHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = IMAPClientHandler.OutboundIn

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let outbound = unwrapOutboundIn(data)
        if case .part(.continuationResponse) = outbound {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        context.write(data, promise: promise)
    }
}

enum XOAUTH2TestFixtures {
    static let email = "user@example.com"
    static let token = "ya29.A0AfH6SExample"

    static let logger: Logger = {
        var logger = Logger(label: "com.swiftmail.tests.xoauth2")
        logger.logLevel = .critical
        return logger
    }()

    struct TestChannel {
        let channel: NIOAsyncTestingChannel
        let promise: EventLoopPromise<[Capability]>
        let handler: XOAUTH2AuthenticationHandler
    }

    static func setUpChannel(
        tag: String,
        expectsChallenge: Bool,
        failContinuationWrite: Bool = false
    ) async throws -> TestChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(IMAPClientHandler())

        if failContinuationWrite {
            try await channel.pipeline.addHandler(XOAUTH2FailContinuationWriteHandler())
        }

        let promise = channel.eventLoop.makePromise(of: [Capability].self)
        let handler = XOAUTH2AuthenticationHandler(
            commandTag: tag,
            promise: promise,
            credentials: makeCredentialBuffer(using: channel.allocator),
            expectsChallenge: expectsChallenge,
            logger: logger
        )
        try await channel.pipeline.addHandler(handler)

        return TestChannel(channel: channel, promise: promise, handler: handler)
    }

    static func makeCredentialBuffer(using allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: email.utf8.count + token.utf8.count + 32)
        buffer.writeString("user=")
        buffer.writeString(email)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeString("auth=Bearer ")
        buffer.writeString(token)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeInteger(UInt8(0x01))
        return buffer
    }

    static func makeBase64String() -> String {
        let raw = "user=\(email)\u{01}auth=Bearer \(token)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }

    static func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw XOAUTH2TimeoutError()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
