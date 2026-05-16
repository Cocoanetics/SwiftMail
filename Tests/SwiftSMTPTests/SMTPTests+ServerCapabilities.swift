import Foundation
@testable import SwiftMail
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPServerCapabilitiesTests {
    @Test
    func requiresSTARTTLSUpgradePolicy() {
        #expect(
            SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "STARTTLS", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresSTARTTLSUpgrade(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 465,
                    transportSecurity: .automatic
                ),
                capabilities: ["STARTTLS"]
            )
        )
    }

    @Test
    func missingSTARTTLSIsFatalForExplicitSTARTTLSPolicy() {
        #expect(
            SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .startTLS
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 587,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 465,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )

        #expect(
            !SMTPServer.requiresMissingSTARTTLSError(
                transportMode: SMTPServer.resolveTransportMode(
                    port: 25,
                    transportSecurity: .automatic
                ),
                capabilities: ["SIZE", "AUTH PLAIN"]
            )
        )
    }

    @Test
    func maximumMessageSizeOctetsParsesSIZECapability() {
        #expect(
            SMTPServer.maximumMessageSizeOctets(
                from: ["PIPELINING", "SIZE 12345678", "AUTH PLAIN"]
            ) == 12_345_678
        )
    }

    @Test
    func maximumMessageSizeOctetsIgnoresMalformedSIZECapability() {
        #expect(SMTPServer.maximumMessageSizeOctets(from: ["SIZE nope"]) == nil)
        #expect(SMTPServer.maximumMessageSizeOctets(from: ["SIZE 0"]) == nil)
        #expect(SMTPServer.maximumMessageSizeOctets(from: ["AUTH PLAIN"]) == nil)
    }

    @Test
    func mailFromCommandFormatsSizeAnd8BitMIMEParameters() throws {
        let plain = try MailFromCommand(senderAddress: "sender@example.com", messageSizeOctets: 4096)
        #expect(plain.toCommandString() == "MAIL FROM:<sender@example.com> SIZE=4096")

        let eightBit = try MailFromCommand(senderAddress: "sender@example.com", use8BitMIME: true)
        #expect(eightBit.toCommandString() == "MAIL FROM:<sender@example.com> BODY=8BITMIME")

        let combined = try MailFromCommand(
            senderAddress: "sender@example.com",
            use8BitMIME: true,
            messageSizeOctets: 4096
        )
        #expect(combined.toCommandString() == "MAIL FROM:<sender@example.com> BODY=8BITMIME SIZE=4096")
    }

    @Test
    func messageSizeOctetsTracksGeneratedContentForAttachments() {
        let inlineAttachment = Attachment(
            filename: "inline.png",
            mimeType: "image/png",
            data: Data(repeating: 0x42, count: 1024),
            contentID: "inline-image",
            isInline: true
        )
        let regularAttachment = Attachment(
            filename: "report.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 0x5A, count: 2048)
        )
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Large",
            textBody: "Hello",
            htmlBody: "<p>Hello<img src=\"cid:inline-image\"></p>",
            attachments: [inlineAttachment, regularAttachment]
        )

        let quotedPrintableSize = email.messageSizeOctets(use8BitMIME: false)
        let eightBitSize = email.messageSizeOctets(use8BitMIME: true)

        #expect(quotedPrintableSize > 0)
        #expect(eightBitSize > 0)
        #expect(quotedPrintableSize == email.constructContent(use8BitMIME: false).utf8.count)
        #expect(eightBitSize == email.constructContent(use8BitMIME: true).utf8.count)
    }

    @Test
    func prepareEmailForSendOmitsMailFromSizeWhenServerDoesNotAdvertiseSIZE() throws {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )

        let prepared = try SMTPServer.prepareEmailForSend(
            email,
            capabilities: ["PIPELINING", "8BITMIME"]
        )

        #expect(prepared.use8BitMIME)
        #expect(prepared.emailSizeOctets > 0)
        #expect(prepared.mailFromMessageSizeOctets == nil)
    }

    @Test
    func prepareEmailForSendUsesMailFromSizeWhenServerAdvertisesSIZE() throws {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: "Body"
        )

        let prepared = try SMTPServer.prepareEmailForSend(
            email,
            capabilities: ["PIPELINING", "SIZE 999999"]
        )

        #expect(prepared.emailSizeOctets > 0)
        #expect(prepared.mailFromMessageSizeOctets == prepared.emailSizeOctets)
    }

    @Test
    func prepareEmailForSendRejectsMessagesExceedingAdvertisedSIZE() {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "recipient@example.com")],
            subject: "Hello",
            textBody: String(repeating: "A", count: 4096)
        )

        #expect(throws: SMTPError.self) {
            try SMTPServer.prepareEmailForSend(
                email,
                capabilities: ["PIPELINING", "SIZE 128"]
            )
        }
    }
}
