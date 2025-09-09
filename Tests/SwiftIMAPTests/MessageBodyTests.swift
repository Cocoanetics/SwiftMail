import Testing
import Foundation
import SwiftMail
import NIOIMAP
import NIOIMAPCore
import OrderedCollections

@Test
func testFindHtmlBodyWithCharset() throws {
        // Create a message with HTML content type that includes charset
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: "Test Email",
            from: "test@example.com",
            to: ["recipient@example.com"],
            cc: [],
            date: Date(),
            flags: []
        )
        
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )
        
        let textPart = MessagePart(
            section: Section([2]),
            contentType: "text/plain; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "Test plain text content".data(using: .utf8)
        )
        
        let message = Message(header: header, parts: [htmlPart, textPart])
        
        // Test the new unified API
        let bodies = message.bodies
        #expect(bodies.count == 2)
        
        let htmlBodyPart = message.findHtmlBodyPart()
        #expect(htmlBodyPart != nil)
        #expect(htmlBodyPart?.contentType == "text/html; charset=utf-8")
        
        let textBodyPart = message.findTextBodyPart()
        #expect(textBodyPart != nil)
        #expect(textBodyPart?.contentType == "text/plain; charset=utf-8")
        
        // Test the legacy API (now fixed)
        let htmlBody = message.htmlBody
        #expect(htmlBody != nil)
        #expect(htmlBody?.contains("Test HTML content") == true)
        
        let textBody = message.textBody
        #expect(textBody != nil)
        #expect(textBody?.contains("Test plain text content") == true)
}

@Test
func testFindBodiesExcludesAttachments() throws {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: "Test Email",
            from: "test@example.com",
            to: ["recipient@example.com"],
            cc: [],
            date: Date(),
            flags: []
        )
        
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )
        
        let attachmentPart = MessagePart(
            section: Section([2]),
            contentType: "text/plain; charset=utf-8",
            disposition: "attachment",
            encoding: "base64",
            filename: "test.txt",
            contentId: nil,
            data: "Test attachment content".data(using: .utf8)
        )
        
        let message = Message(header: header, parts: [htmlPart, attachmentPart])
        
        // Test that attachments are excluded from bodies
        let bodies = message.bodies
        #expect(bodies.count == 1)
        #expect(bodies.first?.contentType == "text/html; charset=utf-8")
        
        // Test that attachments are still found
        let attachments = message.attachments
        #expect(attachments.count == 1)
        #expect(attachments.first?.filename == "test.txt")
}

@Test
func testGetTextContentFromPart() throws {
        let htmlPart = MessagePart(
            section: Section([1]),
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            encoding: "quoted-printable",
            filename: nil,
            contentId: nil,
            data: "<html><body>Test HTML content</body></html>".data(using: .utf8)
        )

        // Test the new textContent property
        let content = htmlPart.textContent
        #expect(content != nil)
        #expect(content?.contains("Test HTML content") == true)
}

@Test
func testDecodesMIMEEncodedAttachmentFilename() throws {
        let encodedName = "=?utf-8?Q?HC=5F1161254447.pdf?="
        var params = OrderedDictionary<String, String>()
        params["filename"] = encodedName
        let fields = BodyStructure.Fields(
            parameters: params,
            id: nil,
            contentDescription: nil,
            encoding: .base64,
            octetCount: 0
        )
        let single = BodyStructure.Singlepart(
            kind: .basic(.init(topLevel: "application", sub: "pdf")),
            fields: fields,
            extension: nil
        )
        let structure = BodyStructure.singlepart(single)

        let parts = Array<MessagePart>(structure)
        #expect(parts.count == 1)
        #expect(parts.first?.filename == "HC_1161254447.pdf")
        #expect(parts.first?.suggestedFilename == "HC_1161254447.pdf")
}

@Test
func testFetchMessagesSequentialOrder() async throws {
        final class FakeServer {
            var callOrder: [String] = []

            func fetchMessageInfo<T: SwiftMail.MessageIdentifier>(for identifier: T) async throws -> MessageInfo? {
                callOrder.append("info")
                return MessageInfo(
                    sequenceNumber: SwiftMail.SequenceNumber(1),
                    uid: SwiftMail.UID(1),
                    subject: nil,
                    from: nil,
                    to: [],
                    cc: [],
                    date: Date(),
                    flags: []
                )
            }

            func fetchMessage(from header: MessageInfo) async throws -> Message {
                callOrder.append("message")
                return Message(header: header, parts: [])
            }

            nonisolated func fetchMessages<T: SwiftMail.MessageIdentifier>(using identifierSet: SwiftMail.MessageIdentifierSet<T>) -> AsyncThrowingStream<Message, Error> {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            guard !identifierSet.isEmpty else {
                                throw IMAPError.emptyIdentifierSet
                            }

                            for identifier in identifierSet.toArray() {
                                try Task.checkCancellation()
                                if let header = try await fetchMessageInfo(for: identifier) {
                                    let email = try await fetchMessage(from: header)
                                    continuation.yield(email)
                                }
                            }

                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }

                    continuation.onTermination = { @Sendable _ in
                        task.cancel()
                    }
                }
            }
        }

        let server = FakeServer()
        let set = SwiftMail.MessageIdentifierSet<SwiftMail.SequenceNumber>([SwiftMail.SequenceNumber(1), SwiftMail.SequenceNumber(2)])
        var messages: [Message] = []
        for try await message in server.fetchMessages(using: set) {
            messages.append(message)
        }

        #expect(messages.count == 2)
        #expect(server.callOrder == ["info", "message", "info", "message"])
}
