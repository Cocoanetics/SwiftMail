import Foundation
import Testing
@testable import SwiftMail

#if os(macOS)
    /// A message appended over IMAP is stored with CRLF line endings only, whatever line
    /// endings and characters its body uses (RFC 3501 §6.3.11 appends an RFC 5322 message).
    struct AppendLineEndingTests {
        @Test(arguments: [
            "one\ntwo\rthree\r\nfour",
            "one\n\u{301}two\r\u{FE0F}three\r\n\u{1F3FB}four"
        ])
        func appendedMessageHasOnlyCRLFLineEndings(body: String) async throws {
            let server = try await BccAppendTests.runTestServer { server in
                let email = Email(
                    sender: EmailAddress(address: "sender@example.com"),
                    recipients: [EmailAddress(address: "to@example.com")],
                    subject: "Line endings",
                    textBody: body
                )
                try await server.append(email: email, to: "Sent", flags: [.seen])
            }
            let messages = server.appendedMessages
            #expect(messages.count == 1)
            guard let bytes = messages.first.map(Array.init) else { return }
            for index in bytes.indices {
                if bytes[index] == 0x0A {
                    #expect(index > 0 && bytes[index - 1] == 0x0D, "LF without CR at octet \(index)")
                }
                if bytes[index] == 0x0D {
                    #expect(index + 1 < bytes.count && bytes[index + 1] == 0x0A, "CR without LF at octet \(index)")
                }
            }
        }
    }
#endif
