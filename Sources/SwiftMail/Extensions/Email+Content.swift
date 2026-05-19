import Foundation

extension Email {
    struct PreparedContent {
        let contentData: Data
        let messageSizeOctets: Int
    }

    /// Bundled per-build state for ``constructContent`` and its helpers.
    /// Selects encoding/text once and shares the three boundary tokens so the
    /// writer helpers can stay closure-of-references.
    private struct MIMEBuildContext {
        let textEncoding: String
        let textBody: String
        let htmlBody: String?
        let mainBoundary: String
        let altBoundary: String
        let relatedBoundary: String

        init(email: Email, use8BitMIME: Bool) {
            let safe8Bit = use8BitMIME && email.textBody.isSafe8BitContent()
                && (email.htmlBody == nil || email.htmlBody!.isSafe8BitContent())
            if safe8Bit {
                self.textEncoding = "8bit"
                self.textBody = email.textBody
                self.htmlBody = email.htmlBody
            } else {
                self.textEncoding = "quoted-printable"
                self.textBody = email.textBody.quotedPrintableEncoded()
                self.htmlBody = email.htmlBody?.quotedPrintableEncoded()
            }
            self.mainBoundary = "SwiftSMTP-Boundary-\(UUID().uuidString)"
            self.altBoundary = "SwiftSMTP-Alt-Boundary-\(UUID().uuidString)"
            self.relatedBoundary = "SwiftSMTP-Related-Boundary-\(UUID().uuidString)"
        }
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
        var content = ""
        writeHeaders(into: &content)
        writeBody(use8BitMIME: use8BitMIME, into: &content)
        return content
    }

    /// Top-level RFC 5322 header block (`From`, `To`, `Cc`, `Subject`, `Date`,
    /// `Message-Id`, `MIME-Version`) plus any caller-supplied additional
    /// headers, suppressing a duplicate `Message-Id` when one is already set.
    private func writeHeaders(into content: inout String) {
        content += "From: \(self.sender)\r\n"
        if !self.recipients.isEmpty {
            content += "To: \(self.recipients.map { $0.description }.joined(separator: ", "))\r\n"
        }
        if !self.ccRecipients.isEmpty {
            content += "Cc: \(self.ccRecipients.map { $0.description }.joined(separator: ", "))\r\n"
        }
        content += "Subject: \(self.subject)\r\n"
        content += "Date: \(Self.rfc2822Date())\r\n"

        let resolvedHeaderID = resolvedMessageIDHeader()
        let suppressAdditionalMessageID = self.messageID != nil || resolvedHeaderID != nil
        if let msgID = self.messageID ?? resolvedHeaderID {
            content += "Message-Id: \(msgID)\r\n"
        } else if !hasMessageIDHeaderInAdditionalHeaders() {
            let generated = MessageID.generate(domain: Self.senderDomain(from: self.sender))
            content += "Message-Id: \(generated)\r\n"
        }
        content += "MIME-Version: 1.0\r\n"

        if let additionalHeaders {
            for (key, value) in additionalHeaders.sorted(by: { $0.key < $1.key }) {
                if suppressAdditionalMessageID && Self.isMessageIDHeaderName(key) {
                    continue
                }
                content += "\(key): \(value)\r\n"
            }
        }
    }

    /// Dispatch to the correct multipart structure based on which body parts
    /// and attachments are present, then emit it.
    private func writeBody(use8BitMIME: Bool, into content: inout String) {
        let context = MIMEBuildContext(email: self, use8BitMIME: use8BitMIME)
        let hasHtmlBody = self.htmlBody != nil
        let hasInline = !self.inlineAttachments.isEmpty
        let hasRegular = !self.regularAttachments.isEmpty

        if hasRegular {
            writeMultipartMixed(context: context, hasHtmlBody: hasHtmlBody, hasInline: hasInline, into: &content)
        } else if hasHtmlBody && hasInline {
            content += "Content-Type: multipart/related; boundary=\"\(context.relatedBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            writeHTMLWithInlineAttachments(context: context, into: &content)
        } else if hasHtmlBody {
            content += "Content-Type: multipart/alternative; boundary=\"\(context.altBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            writeAlternativeTextAndHTML(context: context, into: &content)
        } else {
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(context.textEncoding)\r\n\r\n"
            content += context.textBody
        }
    }

    /// Outer `multipart/mixed` envelope for any email that has regular (non-inline)
    /// attachments. Wraps an inner multipart/related or multipart/alternative for
    /// the bodies, then appends each regular attachment.
    private func writeMultipartMixed(
        context: MIMEBuildContext,
        hasHtmlBody: Bool,
        hasInline: Bool,
        into content: inout String
    ) {
        content += "Content-Type: multipart/mixed; boundary=\"\(context.mainBoundary)\"\r\n\r\n"
        content += "This is a multi-part message in MIME format.\r\n\r\n"

        if hasHtmlBody {
            content += "--\(context.mainBoundary)\r\n"
            if hasInline {
                content += "Content-Type: multipart/related; boundary=\"\(context.relatedBoundary)\"\r\n\r\n"
                writeHTMLWithInlineAttachments(context: context, into: &content)
            } else {
                content += "Content-Type: multipart/alternative; boundary=\"\(context.altBoundary)\"\r\n\r\n"
                writeAlternativeTextAndHTML(context: context, into: &content)
            }
            content += "\r\n"
        } else {
            content += "--\(context.mainBoundary)\r\n"
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(context.textEncoding)\r\n\r\n"
            content += "\(context.textBody)\r\n\r\n"
        }

        for attachment in self.regularAttachments {
            content += "--\(context.mainBoundary)\r\n"
            content += "Content-Type: \(attachment.mimeType)\r\n"
            content += "Content-Transfer-Encoding: base64\r\n"
            content += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n\r\n"
            content += encodedAttachmentBody(attachment.data) + "\r\n\r\n"
        }
        content += "--\(context.mainBoundary)--\r\n"
    }

    /// multipart/related body: a multipart/alternative bodies section followed by
    /// each inline attachment, closed by the related boundary.
    private func writeHTMLWithInlineAttachments(
        context: MIMEBuildContext,
        into content: inout String
    ) {
        content += "--\(context.relatedBoundary)\r\n"
        content += "Content-Type: multipart/alternative; boundary=\"\(context.altBoundary)\"\r\n\r\n"
        writeAlternativeTextAndHTML(context: context, into: &content)
        content += "\r\n"

        for attachment in self.inlineAttachments {
            content += "--\(context.relatedBoundary)\r\n"
            content += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
            content += "Content-Transfer-Encoding: base64\r\n"
            if let contentID = attachment.contentID {
                content += "Content-ID: <\(contentID)>\r\n"
            }
            content += "Content-Disposition: inline; filename=\"\(attachment.filename)\"\r\n\r\n"
            content += encodedAttachmentBody(attachment.data) + "\r\n\r\n"
        }

        content += "--\(context.relatedBoundary)--\r\n"
    }

    /// Two-part text/plain + text/html body, closed by the alternative boundary.
    private func writeAlternativeTextAndHTML(
        context: MIMEBuildContext,
        into content: inout String
    ) {
        content += "--\(context.altBoundary)\r\n"
        content += "Content-Type: text/plain; charset=UTF-8\r\n"
        content += "Content-Transfer-Encoding: \(context.textEncoding)\r\n\r\n"
        content += "\(context.textBody)\r\n\r\n"
        content += "--\(context.altBoundary)\r\n"
        content += "Content-Type: text/html; charset=UTF-8\r\n"
        content += "Content-Transfer-Encoding: \(context.textEncoding)\r\n\r\n"
        content += "\(context.htmlBody ?? "")\r\n\r\n"
        content += "--\(context.altBoundary)--\r\n"
    }

    private func encodedAttachmentBody(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
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
