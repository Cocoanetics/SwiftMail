import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPErrorHandlingTests {
    // MARK: - SMTPError LocalizedError

    @Test
    func testSMTPErrorLocalizedDescriptionReturnsRealMessage() {
        let error: Error = SMTPError.connectionFailed("Connection refused")
        #expect(error.localizedDescription == "SMTP connection failed: Connection refused")
    }

    @Test
    func testSMTPErrorLocalizedDescriptionForAllCases() {
        let cases: [(SMTPError, String)] = [
            (.connectionFailed("timeout"), "SMTP connection failed: timeout"),
            (.invalidResponse("garbled"), "SMTP invalid response: garbled"),
            (.sendFailed("broken pipe"), "SMTP send failed: broken pipe"),
            (.authenticationFailed("bad creds"), "SMTP authentication failed: bad creds"),
            (.commandFailed("550 denied"), "SMTP command failed: 550 denied"),
            (.invalidEmailAddress("bad@"), "SMTP invalid email address: bad@"),
            (.tlsFailed("handshake"), "SMTP TLS failed: handshake"),
            (
                .messageTooLarge(messageSizeOctets: 100, maximumMessageSizeOctets: 50),
                "SMTP message too large: 100 bytes exceeds 50 byte limit"
            )
        ]
        for (error, expected) in cases {
            let asError: Error = error
            #expect(asError.localizedDescription == expected)
        }
    }
}
