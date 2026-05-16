import Foundation

extension Email {
    struct PreparedContent {
        let contentData: Data
        let messageSizeOctets: Int
    }

    /// Text and HTML bodies after applying the chosen Content-Transfer-Encoding.
    fileprivate struct EncodedBodies {
        let encoding: String
        let text: String
        let html: String?
    }

    /// Boundary identifiers used when building multipart MIME structures.
    fileprivate struct Boundaries {
        let main: String
        let alt: String
        let related: String
    }

    func preparedContent(use8BitMIME: Bool = false) -> PreparedContent {
        let content = constructContent(use8BitMIME: use8BitMIME)
        let contentData = Data(content.utf8)
        return PreparedContent(contentData: contentData, messageSizeOctets: contentData.count)
    }

    public func messageSizeOctets(use8BitMIME: Bool = false) -> Int {
        preparedContent(use8BitMIME: use8BitMIME).messageSizeOctets
    }

    /**
     Build the MIME encoded email body.

     This helper assembles the full message body including all MIME headers
     and boundaries. The method automatically chooses between quoted
     printable and 8bit transfer encoding based on the provided flag and the
     content of the email.

     - Parameter use8BitMIME: Set to `true` if the SMTP server announced the
       `8BITMIME` capability. The text and HTML bodies are only transmitted as
       8bit if they are deemed safe via ``String/isSafe8BitContent()``.
     - Returns: The complete message body ready to be sent via SMTP.
     */
    public func constructContent(use8BitMIME: Bool = false) -> String {
        var content = renderHeaders()
        let bodies = renderTextBodies(use8BitMIME: use8BitMIME)
        let boundaries = Boundaries(
            main: "SwiftSMTP-Boundary-\(UUID().uuidString)",
            alt: "SwiftSMTP-Alt-Boundary-\(UUID().uuidString)",
            related: "SwiftSMTP-Related-Boundary-\(UUID().uuidString)"
        )

        let hasHtmlBody = htmlBody != nil
        let hasInlineAttachments = !inlineAttachments.isEmpty
        let hasRegularAttachments = !regularAttachments.isEmpty

        if hasRegularAttachments {
            content += renderMixedBody(
                bodies: bodies,
                hasHtmlBody: hasHtmlBody,
                hasInlineAttachments: hasInlineAttachments,
                boundaries: boundaries
            )
        } else if hasHtmlBody, hasInlineAttachments {
            content += renderRelatedBody(bodies: bodies, boundaries: boundaries)
        } else if hasHtmlBody {
            content += renderAlternativeBody(bodies: bodies, altBoundary: boundaries.alt)
        } else {
            content += renderSimpleTextBody(bodies: bodies)
        }

        return content
    }

    /// Render the message headers section (everything up to but not including the body Content-Type).
    private func renderHeaders() -> String {
        var content = ""
        content += "From: \(sender)\r\n"

        if !recipients.isEmpty {
            content += "To: \(recipients.map(\.description).joined(separator: ", "))\r\n"
        }
        if !ccRecipients.isEmpty {
            content += "Cc: \(ccRecipients.map(\.description).joined(separator: ", "))\r\n"
        }

        content += "Subject: \(subject)\r\n"
        content += "Date: \(Self.rfc2822Date())\r\n"

        let resolvedAdditionalHeaderMessageID = resolvedMessageIDHeader()
        let shouldSuppressAdditionalHeaderMessageID = messageID != nil || resolvedAdditionalHeaderMessageID != nil

        if let msgID = messageID ?? resolvedAdditionalHeaderMessageID {
            content += "Message-Id: \(msgID)\r\n"
        } else if !hasMessageIDHeaderInAdditionalHeaders() {
            let generatedMessageID = MessageID.generate(domain: Self.senderDomain(from: sender))
            content += "Message-Id: \(generatedMessageID)\r\n"
        }
        content += "MIME-Version: 1.0\r\n"

        if let additionalHeaders {
            for (key, value) in additionalHeaders.sorted(by: { $0.key < $1.key }) {
                if shouldSuppressAdditionalHeaderMessageID, Self.isMessageIDHeaderName(key) {
                    continue
                }
                content += "\(key): \(value)\r\n"
            }
        }
        return content
    }

    /// Returns the transfer encoding plus encoded text/html bodies, chosen based on 8BITMIME safety.
    private func renderTextBodies(use8BitMIME: Bool) -> EncodedBodies {
        if use8BitMIME, textBody.isSafe8BitContent(),
           htmlBody == nil || htmlBody!.isSafe8BitContent() {
            return EncodedBodies(encoding: "8bit", text: textBody, html: htmlBody)
        }
        return EncodedBodies(
            encoding: "quoted-printable",
            text: textBody.quotedPrintableEncoded(),
            html: htmlBody?.quotedPrintableEncoded()
        )
    }

    /// Render the simple text/plain-only body (no HTML, no attachments).
    private func renderSimpleTextBody(bodies: EncodedBodies) -> String {
        var content = ""
        content += "Content-Type: text/plain; charset=UTF-8\r\n"
        content += "Content-Transfer-Encoding: \(bodies.encoding)\r\n\r\n"
        content += bodies.text
        return content
    }

    /// Render a multipart/alternative body (text + HTML, no attachments).
    private func renderAlternativeBody(bodies: EncodedBodies, altBoundary: String) -> String {
        var content = ""
        content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
        content += "This is a multi-part message in MIME format.\r\n\r\n"
        content += renderAlternativePartsBody(bodies: bodies, altBoundary: altBoundary)
        content += "--\(altBoundary)--\r\n"
        return content
    }

    /// Render the inner text+HTML alternative parts (used inside alternative and related bodies).
    private func renderAlternativePartsBody(bodies: EncodedBodies, altBoundary: String) -> String {
        var content = ""
        content += "--\(altBoundary)\r\n"
        content += "Content-Type: text/plain; charset=UTF-8\r\n"
        content += "Content-Transfer-Encoding: \(bodies.encoding)\r\n\r\n"
        content += "\(bodies.text)\r\n\r\n"
        content += "--\(altBoundary)\r\n"
        content += "Content-Type: text/html; charset=UTF-8\r\n"
        content += "Content-Transfer-Encoding: \(bodies.encoding)\r\n\r\n"
        content += "\(bodies.html ?? "")\r\n\r\n"
        return content
    }

    /// Render a multipart/related body (HTML + inline attachments, no regular attachments).
    private func renderRelatedBody(bodies: EncodedBodies, boundaries: Boundaries) -> String {
        var content = ""
        content += "Content-Type: multipart/related; boundary=\"\(boundaries.related)\"\r\n\r\n"
        content += "This is a multi-part message in MIME format.\r\n\r\n"
        content += renderRelatedInner(bodies: bodies, boundaries: boundaries)
        content += "--\(boundaries.related)--\r\n"
        return content
    }

    /// Render the inner contents of a multipart/related body: alternative parts + inline attachments.
    private func renderRelatedInner(bodies: EncodedBodies, boundaries: Boundaries) -> String {
        var content = ""
        content += "--\(boundaries.related)\r\n"
        content += "Content-Type: multipart/alternative; boundary=\"\(boundaries.alt)\"\r\n\r\n"
        content += renderAlternativePartsBody(bodies: bodies, altBoundary: boundaries.alt)
        content += "--\(boundaries.alt)--\r\n\r\n"

        for attachment in inlineAttachments {
            content += "--\(boundaries.related)\r\n"
            content += renderInlineAttachment(attachment)
        }
        return content
    }

    /// Render a multipart/mixed body (top-level, with regular attachments and possibly inline+HTML).
    private func renderMixedBody(
        bodies: EncodedBodies,
        hasHtmlBody: Bool,
        hasInlineAttachments: Bool,
        boundaries: Boundaries
    ) -> String {
        var content = ""
        content += "Content-Type: multipart/mixed; boundary=\"\(boundaries.main)\"\r\n\r\n"
        content += "This is a multi-part message in MIME format.\r\n\r\n"

        if hasHtmlBody {
            content += "--\(boundaries.main)\r\n"
            if hasInlineAttachments {
                content += "Content-Type: multipart/related; boundary=\"\(boundaries.related)\"\r\n\r\n"
                content += renderRelatedInner(bodies: bodies, boundaries: boundaries)
                content += "--\(boundaries.related)--\r\n\r\n"
            } else {
                content += "Content-Type: multipart/alternative; boundary=\"\(boundaries.alt)\"\r\n\r\n"
                content += renderAlternativePartsBody(bodies: bodies, altBoundary: boundaries.alt)
                content += "--\(boundaries.alt)--\r\n\r\n"
            }
        } else {
            content += "--\(boundaries.main)\r\n"
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(bodies.encoding)\r\n\r\n"
            content += "\(bodies.text)\r\n\r\n"
        }

        for attachment in regularAttachments {
            content += "--\(boundaries.main)\r\n"
            content += renderRegularAttachment(attachment)
        }

        content += "--\(boundaries.main)--\r\n"
        return content
    }

    /// Render the per-attachment block (headers + base64 data) for an inline attachment.
    private func renderInlineAttachment(_ attachment: Attachment) -> String {
        var content = ""
        content += "Content-Type: \(attachment.mimeType)"
        content += "; name=\"\(attachment.filename)\"\r\n"
        content += "Content-Transfer-Encoding: base64\r\n"
        if let contentID = attachment.contentID {
            content += "Content-ID: <\(contentID)>\r\n"
        }
        content += "Content-Disposition: inline; filename=\"\(attachment.filename)\"\r\n\r\n"
        let base64Data = attachment.data.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn]
        )
        content += "\(base64Data)\r\n\r\n"
        return content
    }

    /// Render the per-attachment block (headers + base64 data) for a regular (non-inline) attachment.
    private func renderRegularAttachment(_ attachment: Attachment) -> String {
        var content = ""
        content += "Content-Type: \(attachment.mimeType)\r\n"
        content += "Content-Transfer-Encoding: base64\r\n"
        content += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n\r\n"
        let base64Data = attachment.data.base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn]
        )
        content += "\(base64Data)\r\n\r\n"
        return content
    }

    /// Formats the current date in RFC 2822 format for the Date header.
    private static func rfc2822Date() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }

    /// Extracts the domain from the sender address for Message-Id generation.
    private static func senderDomain(from sender: EmailAddress) -> String {
        if let atIndex = sender.address.lastIndex(of: "@") {
            let domain = sender.address[sender.address.index(after: atIndex)...]
            if !domain.isEmpty {
                return String(domain)
            }
        }
        return "localhost"
    }

    private func resolvedMessageIDHeader() -> MessageID? {
        guard let additionalHeaders else { return nil }

        for (key, value) in additionalHeaders where Self.isMessageIDHeaderName(key) {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let messageID = MessageID(trimmedValue) {
                return messageID
            }
        }

        return nil
    }

    private func hasMessageIDHeaderInAdditionalHeaders() -> Bool {
        guard let additionalHeaders else { return false }
        return additionalHeaders.keys.contains(where: Self.isMessageIDHeaderName)
    }

    private static func isMessageIDHeaderName(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).compare(
            "message-id",
            options: [.caseInsensitive]
        ) == .orderedSame
    }
}
