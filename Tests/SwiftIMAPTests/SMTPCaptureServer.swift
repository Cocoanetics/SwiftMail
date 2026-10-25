// SMTPCaptureServer.swift
// A minimal SMTP server for IMAP tests that also send mail (`sendDraft`).
// It accepts every command and records the envelope recipients and the
// message content it receives.

import Foundation
import NIO

final class SMTPCaptureServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: Channel?
    private var recipientsStorage: [String] = []
    private var contentStorage = Data()

    /// The port the server listens on, once started.
    var port: Int { channel?.localAddress?.port ?? 0 }

    /// The address of every `RCPT TO` command, in order.
    var recipients: [String] { lock.withLock { recipientsStorage } }

    /// The message content of the last DATA command, dot-stuffing removed.
    var content: Data { lock.withLock { contentStorage } }

    func start() async throws {
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(SMTPCaptureSession(server: self))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() async throws {
        try await channel?.close()
        try await group.shutdownGracefully()
    }

    fileprivate func record(recipient: String) {
        lock.withLock { recipientsStorage.append(recipient) }
    }

    fileprivate func record(content: Data) {
        lock.withLock { contentStorage = content }
    }
}

/// One SMTP connection to an ``SMTPCaptureServer``.
private final class SMTPCaptureSession: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let server: SMTPCaptureServer
    private var pending = [UInt8]()
    private var inData = false
    private var content = [UInt8]()

    init(server: SMTPCaptureServer) {
        self.server = server
    }

    func channelActive(context: ChannelHandlerContext) {
        reply("220 capture.test ESMTP ready", context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readBytes(length: buffer.readableBytes) ?? []
        while let lineFeed = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = Array(pending[..<lineFeed])
            pending.removeSubrange(...lineFeed)
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            handle(line: line, context: context)
        }
    }

    private func handle(line: [UInt8], context: ChannelHandlerContext) {
        if inData {
            if line == [UInt8(ascii: ".")] {
                inData = false
                server.record(content: Data(content))
                reply("250 OK queued", context: context)
            } else {
                let unstuffed = line.first == UInt8(ascii: ".") ? Array(line.dropFirst()) : line
                content += unstuffed + [0x0D, 0x0A]
            }
            return
        }
        let command = String(bytes: line, encoding: .utf8) ?? ""
        let verb = command.uppercased()
        if verb.hasPrefix("EHLO") || verb.hasPrefix("HELO") {
            reply("250-capture.test\r\n250 8BITMIME", context: context)
        } else if verb.hasPrefix("RCPT TO:") {
            let address = command.dropFirst("RCPT TO:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            server.record(recipient: address)
            reply("250 OK", context: context)
        } else if verb == "DATA" {
            inData = true
            content = []
            reply("354 End data with <CR><LF>.<CR><LF>", context: context)
        } else if verb == "QUIT" {
            reply("221 Bye", context: context)
            context.close(promise: nil)
        } else {
            reply("250 OK", context: context)
        }
    }

    private func reply(_ text: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count + 2)
        buffer.writeString(text + "\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
