import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct XOAuth2AuthHandlerTests {
    private func makeHandler() async throws -> (EmbeddedChannel, EventLoopFuture<AuthResult>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: AuthResult.self)
        try await channel.pipeline.addHandler(XOAuth2AuthHandler(commandTag: nil, promise: promise)).get()
        return (channel, promise.futureResult)
    }

    @Test("The XOAUTH2 command uses the handler that answers the error continuation")
    func commandUsesXOAuth2Handler() {
        #expect(XOAuth2AuthCommand.HandlerType.self == XOAuth2AuthHandler.self)
    }

    @Test("A 235 completes at once")
    func success() async throws {
        let (channel, result) = try await makeHandler()
        try channel.writeInbound(SMTPResponse(code: 235, message: "2.7.0 Accepted"))
        #expect(try await result.get().success)
        _ = try? channel.finish()
    }

    @Test("A rejected token's 334 is answered with an empty line, and the 535 completes with both messages")
    func rejectionViaContinuation() async throws {
        let (channel, result) = try await makeHandler()
        let payload = #"{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}"#

        try channel.writeInbound(SMTPResponse(code: 334, message: "334 " + Data(payload.utf8).base64EncodedString()))
        let answer = try channel.readOutbound(as: ByteBuffer.self)
        #expect(answer.map { String(buffer: $0) } == "\r\n")

        try channel.writeInbound(SMTPResponse(code: 535, message: "5.7.8 Username and Password not accepted."))
        let outcome = try await result.get()
        #expect(outcome.success == false)
        #expect(outcome.errorMessage?.contains("5.7.8") == true)
        #expect(outcome.errorMessage?.contains(#""status":"400""#) == true)
        _ = try? channel.finish()
    }

    @Test("A continuation that isn't base64 is kept as it came")
    func plainContinuation() async throws {
        let (channel, result) = try await makeHandler()
        try channel.writeInbound(SMTPResponse(code: 334, message: "334 not base64!"))
        _ = try channel.readOutbound(as: ByteBuffer.self)
        try channel.writeInbound(SMTPResponse(code: 535, message: "5.7.8 Rejected"))
        #expect(try await result.get().errorMessage == "5.7.8 Rejected (not base64!)")
        _ = try? channel.finish()
    }

    @Test("A rejection without a continuation completes too")
    func directRejection() async throws {
        let (channel, result) = try await makeHandler()
        try channel.writeInbound(SMTPResponse(code: 535, message: "5.7.8 Rejected"))
        let outcome = try await result.get()
        #expect(outcome.success == false && outcome.errorMessage == "5.7.8 Rejected")
        _ = try? channel.finish()
    }

    @Test("Through the real reply parser, the 334's JSON is decoded and the 535 completes")
    func rejectionThroughResponseParser() async throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: AuthResult.self)
        try await channel.pipeline.addHandler(SMTPResponseHandler()).get()
        try await channel.pipeline.addHandler(XOAuth2AuthHandler(commandTag: nil, promise: promise)).get()
        let payload = #"{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}"#

        // What Gmail sends, as the line decoder hands it over.
        try channel.writeInbound("334 " + Data(payload.utf8).base64EncodedString())
        let answer = try channel.readOutbound(as: ByteBuffer.self)
        #expect(answer.map { String(buffer: $0) } == "\r\n")

        try channel.writeInbound("535-5.7.8 Username and Password not accepted. For more information, go to")
        try channel.writeInbound("535 5.7.8  https://support.google.com/mail/?p=BadCredentials")
        let outcome = try await promise.futureResult.get()
        #expect(outcome.success == false)
        #expect(outcome.errorMessage?.contains("5.7.8") == true)
        #expect(outcome.errorMessage?.contains(payload) == true)
        #expect(outcome.errorMessage?.contains("334 ") == false)
        _ = try? channel.finish()
    }

    @Test("The reply code is stripped from every line of a continuation")
    func continuationPayloadStripsCodes() {
        #expect(XOAuth2AuthHandler.continuationPayload(of: SMTPResponse(code: 334, message: "334 eyJh")) == "eyJh")
        #expect(XOAuth2AuthHandler.continuationPayload(of: SMTPResponse(code: 334, message: "334-eyJh\n334 YmM=")) == "eyJhYmM=")
        #expect(XOAuth2AuthHandler.continuationPayload(of: SMTPResponse(code: 334, message: "334")) == "")
        // A payload that isn't prefixed (a caller's own fabricated reply) is kept.
        #expect(XOAuth2AuthHandler.continuationPayload(of: SMTPResponse(code: 334, message: "eyJh")) == "eyJh")
    }

    @Test("The handler is released once it leaves the pipeline")
    func handlerIsReleased() async throws {
        weak var released: XOAuth2AuthHandler?
        do {
            let channel = EmbeddedChannel()
            let promise = channel.eventLoop.makePromise(of: AuthResult.self)
            let handler = XOAuth2AuthHandler(commandTag: nil, promise: promise)
            released = handler
            try await channel.pipeline.addHandler(handler).get()
            try channel.writeInbound(SMTPResponse(code: 235, message: "235 2.7.0 Accepted"))
            #expect(try await promise.futureResult.get().success)
            _ = try? channel.finish()
        }
        #expect(released == nil)
    }
}
