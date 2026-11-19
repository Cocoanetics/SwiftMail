import Foundation
import NIO
import NIOEmbedded
import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

extension IMAPBootstrapRaceTests {
    // MARK: Harness

    func makeConnection(_ group: EventLoopGroup, security: MailTransportSecurity = .plainText) -> IMAPConnection {
        IMAPConnection(host: "127.0.0.1", port: 143, transportSecurity: security,
                       minimumTLSVersion: .tlsv12, group: group, loggerLabel: "test.bootstrap",
                       outboundLabel: "test.bootstrap.out", inboundLabel: "test.bootstrap.in",
                       connectionID: "bootstrap", connectionRole: "test", parserLimits: .default, minimumCommandTimeoutSeconds: 0)
    }

    func activeChannel() async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
        return channel
    }

    @discardableResult func installTransport(_ connection: IMAPConnection) async throws -> NIOAsyncTestingChannel {
        let channel = try await activeChannel()
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        connection.replaceCapabilitiesForTesting([Capability("IMAP4rev1"), .id, .saslIR,
                                                  .authenticate(.plain),
                                                  .authenticate(AuthenticationMechanism("XOAUTH2")!)])
        return channel
    }

    func installFreshTransport(_ connection: IMAPConnection) async throws {
        connection.operationOwnerFinishedForTesting = nil
        connection.replaceConnectForTesting {
            _ = try await installTransport(connection)
            connection.replaceCapabilitiesForTesting([Capability("IMAP4rev1")])
        }
        try await connection.connect()
        connection.markSessionAuthenticated()
        let channel = try #require(connection.channel as? NIOAsyncTestingChannel)
        let noop = Task { try await connection.noop() }
        let line = try await outbound(channel)
        let tag = try #require(line.split(separator: " ").first)
        #expect(line.contains("NOOP"))
        try await inbound(channel, "\(tag) OK fresh\r\n")
        _ = try await noop.value
    }

    func inbound(_ channel: NIOAsyncTestingChannel, _ line: String) async throws {
        try await channel.writeInbound(channel.allocator.buffer(string: line))
    }

    func outbound(_ channel: NIOAsyncTestingChannel) async throws -> String {
        var buffer = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        return buffer.readString(length: buffer.readableBytes) ?? ""
    }
}

final class BootstrapDriver {
    typealias Initializer = (Channel) -> EventLoopFuture<Void>
    let initializer = IMAPTerminal<Initializer>()
    let tcp: EventLoopPromise<Channel>

    init(_ connection: IMAPConnection) {
        tcp = connection.group.next().makePromise(of: Channel.self)
        connection.bootstrapOverrideForTesting = { [self] initialize in
            initializer.complete(.success(initialize))
            return tcp.futureResult
        }
    }

    func initializeChannel() async throws -> NIOAsyncTestingChannel {
        let initialize = try await initializer.value()
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 143))
        try await channel.eventLoop.flatSubmit { initialize(channel) }.get()
        return channel
    }
}

final class HoldGate: @unchecked Sendable {
    let stage: String
    let entered = IMAPTestSignal()
    let release = IMAPTestSignal()
    let exited = IMAPTestSignal()

    init(_ stage: String) { self.stage = stage }

    func visit(_ stage: String) async {
        guard stage == self.stage else { return }
        entered.signal()
        await release.wait()
        exited.signal()
    }
}

final class AuthenticationContinuationWriteGate: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = IMAPClientHandler.OutboundIn

    let entered = IMAPTestSignal()
    private let lock = NSLock()
    private var held: (EventLoopPromise<Void>, EventLoop)?

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let outbound = unwrapOutboundIn(data)
        if case .part(.continuationResponse) = outbound, let promise {
            lock.withLock { held = (promise, context.eventLoop) }
            entered.signal()
            return
        }
        context.write(data, promise: promise)
    }

    func failHeldWrite() async throws {
        let held = lock.withLock { () -> (EventLoopPromise<Void>, EventLoop)? in
            defer { self.held = nil }
            return self.held
        }
        let (promise, eventLoop) = try #require(held)
        try await eventLoop.submit {
            promise.fail(ChannelError.ioOnClosedChannel)
        }.get()
    }
}

struct HeldCommand: IMAPTaggedCommand {
    typealias ResultType = [IMAPServerEvent]
    typealias HandlerType = NoopHandler
    let entered: IMAPTestSignal
    let release: IMAPTestSignal

    func toTaggedCommand(tag: String) -> TaggedCommand { TaggedCommand(tag: tag, command: .noop) }

    func send(on channel: Channel, tag: String,
              whenWritten: @escaping @Sendable (EventLoopFuture<Void>) -> Void) async throws {
        entered.signal()
        await release.wait()
        try await NoopCommand().send(on: channel, tag: tag, whenWritten: whenWritten)
    }
}
