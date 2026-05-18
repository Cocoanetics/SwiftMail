// EmailMessageConversionTests+Fixtures.swift
// Shared helpers used by the Email <-> Message conversion test files.

import Foundation
import SwiftMail

enum EmailMessageConversionFixtures {
    static func makeMessage(
        from: String? = "Alice <alice@example.com>",
        to: [String] = ["bob@example.com"],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String? = "Hello",
        messageId: MessageID? = nil,
        additionalFields: [String: String]? = nil,
        parts: [MessagePart] = []
    ) -> Message {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(1),
            uid: UID(1),
            subject: subject,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            messageId: messageId,
            additionalFields: additionalFields
        )
        return Message(header: header, parts: parts)
    }

    static func textPart(_ body: String, section: String = "1") -> MessagePart {
        MessagePart(
            sectionString: section,
            contentType: "text/plain",
            disposition: nil,
            encoding: "7bit",
            data: body.data(using: .utf8)
        )
    }

    static func htmlPart(_ body: String, section: String = "2") -> MessagePart {
        MessagePart(
            sectionString: section,
            contentType: "text/html",
            disposition: nil,
            encoding: "7bit",
            data: body.data(using: .utf8)
        )
    }
}
