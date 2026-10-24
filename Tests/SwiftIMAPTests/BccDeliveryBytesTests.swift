import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
extension BccAppendTests {
    /// A draft another client wrote in a legacy 8-bit charset reaches SMTP
    /// byte for byte, less its Bcc field.
    @Test("sendDraft delivers a draft's bytes unchanged except its Bcc field")
    func sendDraftKeepsDeliveryBytes() async throws {
        let before = "From: sender@example.com\r\nTo: to@example.com\r\n"
        let after = "Subject: Legacy bytes\r\nMessage-ID: <legacy@example.com>\r\n"
            + "Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
        var body = Data("caf".utf8)
        body.append(contentsOf: [0xE9, 0xFF, 0x0D, 0x0A])
        body.append(Data("Bcc: body-text@example.com\r\n".utf8))
        var draft = Data((before + "Bcc: Hidden <hidden@example.com>\r\n" + after).utf8)
        draft.append(body)
        var expected = Data((before + after).utf8)
        expected.append(body)
        // SendContentCommand ends the content with a CRLF before the DATA terminator.
        expected.append(Data("\r\n".utf8))

        let smtp = SMTPCaptureServer()
        try await smtp.start()
        let testServer = try await Self.runTestServer(seeding: draft) { server in
            let client = SMTPServer(host: "127.0.0.1", port: smtp.port, transportSecurity: .plainText)
            try await client.connect()
            _ = try await server.sendDraft(uid: UID(1), via: client, from: "Drafts", to: "Sent")
            try await client.disconnect()
        }
        try await smtp.stop()
        #expect(smtp.recipients.sorted() == ["hidden@example.com", "to@example.com"])
        #expect(smtp.content == expected)
        #expect(testServer.appendedMessages.count == 1)
        let sent = try #require(testServer.appendedMessages.first)
        #expect(sent.range(of: Data("\r\nBcc: Hidden <hidden@example.com>\r\n".utf8)) != nil)
    }
}
#endif
