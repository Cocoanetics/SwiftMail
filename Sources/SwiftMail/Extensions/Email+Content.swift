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
        /// Whether the SMTP server announced `8BITMIME`. Threaded through so the
        /// calendar-invite helpers can label non-ASCII ICS `8bit` only when the
        /// server negotiated it (otherwise they fall back to base64).
        let use8BitMIME: Bool

        init(email: Email, use8BitMIME: Bool) {
            self.use8BitMIME = use8BitMIME
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
        content += "From: \(self.sender.headerString())\r\n"
        if !self.recipients.isEmpty {
            content += "To: \(self.recipients.map { $0.headerString() }.joined(separator: ", "))\r\n"
        }
        if !self.ccRecipients.isEmpty {
            content += "Cc: \(self.ccRecipients.map { $0.headerString() }.joined(separator: ", "))\r\n"
        }
        content += "Subject: \(self.subject.rfc2047EncodedHeader())\r\n"
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

        // iMIP invite shortcut (RFC 6047 §2.2): when the message carries exactly one
        // text/calendar part and nothing else, ship it as multipart/alternative —
        // text/plain body alternative + the ICS. Mail clients (Apple Mail, Outlook,
        // Gmail, iCloud) key their Accept/Decline UI off this shape;
        // multipart/mixed with the same parts does not trigger it. Note: clients
        // (Outlook especially) also require the ICS to carry a `method` parameter
        // (e.g. `text/calendar; method=REQUEST`) before they offer Accept/Decline —
        // that parameter is the caller's responsibility on the Attachment mimeType.
        if !hasHtmlBody && !hasInline,
           self.regularAttachments.count == 1,
           let invite = calendarInviteText(for: self.regularAttachments[0], use8BitMIME: context.use8BitMIME) {
            writeCalendarAlternative(
                context: context,
                invite: self.regularAttachments[0],
                icsText: invite.text,
                encoding: invite.encoding,
                into: &content
            )
            return
        }

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
            if let invite = calendarInviteText(for: attachment, use8BitMIME: context.use8BitMIME) {
                // RFC 6047 iMIP: calendar invites need an inline (or absent)
                // Content-Disposition for clients to render the Accept/Decline UI,
                // and the ICS shipped verbatim (base64/quoted-printable re-encoding
                // is exactly what breaks invite recognition). The transfer encoding
                // is 7bit for pure-ASCII ICS, 8bit when the server negotiated
                // 8BITMIME, else the part falls back to the base64 branch below.
                // The filename keeps non-calendar clients able to save the .ics,
                // mirroring how Gmail's own outgoing invites are formatted.
                content += "Content-Transfer-Encoding: \(invite.encoding)\r\n"
                content += "Content-Disposition: inline; filename=\"\(attachment.filename)\"\r\n\r\n"
                content += terminatedICSBody(invite.text)
            } else {
                content += "Content-Transfer-Encoding: base64\r\n"
                content += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n\r\n"
                content += encodedAttachmentBody(attachment.data) + "\r\n\r\n"
            }
        }
        content += "--\(context.mainBoundary)--\r\n"
    }

    /// Returns the ICS text (normalized to CRLF line endings) together with the
    /// transfer encoding to label it with, when the attachment is a text/calendar
    /// part whose data is valid UTF-8 (a byte-level check — the declared charset
    /// parameter is not consulted) and safe to ship verbatim. `nil` routes the
    /// attachment through the regular base64 path.
    ///
    /// Encoding selection keeps the wire bytes identical to the ICS while staying
    /// honest about what is on the wire (RFC 2045 §6.2: `7bit` means no octet > 127):
    /// - **pure ASCII** → `7bit` (the field-proven shape for an all-ASCII invite).
    /// - **non-ASCII, server advertised 8BITMIME** → `8bit` (real invites carry
    ///   non-ASCII in SUMMARY/LOCATION/attendee names; an honest `8bit` label keeps
    ///   bytes identical and is what clients recognize).
    /// - **non-ASCII, no 8BITMIME** → `nil` so the part falls back to base64 rather
    ///   than putting unnegotiated 8-bit octets on a 7-bit path where an MTA may
    ///   strip the high bits and corrupt the invite.
    ///
    /// Content that is unsafe for verbatim transmission — NUL/control bytes, or a
    /// line over the RFC 5322 §2.1.1 998-octet limit (unfolded `DESCRIPTION`,
    /// `X-ALT-DESC`) — also returns `nil`, since such a line would overrun SMTP's
    /// limit. NUL/control safety reuses ``String/isSafe8BitContent()`` (the gate the
    /// text and HTML bodies already pass through); the line length is measured here
    /// in UTF-8 *octets* between hard CRLFs, because `isSafe8BitContent` counts
    /// grapheme clusters — which undercounts multibyte ICS lines (a 600-character
    /// `SUMMARY` of 2-byte chars is 1200 octets) — and splits on Unicode separators
    /// (U+2028/U+2029) that SMTP does not treat as line breaks.
    private func calendarInviteText(
        for attachment: Attachment,
        use8BitMIME: Bool
    ) -> (text: String, encoding: String)? {
        let mimeType = attachment.mimeType.lowercased()
        guard mimeType == "text/calendar" || mimeType.hasPrefix("text/calendar;") else { return nil }
        guard let decoded = String(data: attachment.data, encoding: .utf8) else { return nil }
        // SMTP DATA requires CRLF-only line endings (RFC 5321 §2.3.8) and the
        // send path's dot-stuffing assumes canonical CRLF framing, while ICS
        // producers commonly emit bare LF — normalize before shipping verbatim.
        let icsText = decoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        guard icsText.isSafe8BitContent(),
              icsText.components(separatedBy: "\r\n").allSatisfy({ $0.utf8.count <= 998 })
        else { return nil }
        if icsText.utf8.allSatisfy({ $0 < 128 }) { return (icsText, "7bit") }
        if use8BitMIME { return (icsText, "8bit") }
        return nil
    }

    /// ICS body terminated so the following boundary marker starts on its own line.
    private func terminatedICSBody(_ icsText: String) -> String {
        icsText.hasSuffix("\r\n") ? icsText + "\r\n" : icsText + "\r\n\r\n"
    }

    /// multipart/alternative envelope for a single-invite message: the text/plain
    /// body followed by the text/calendar part shipped verbatim without an
    /// attachment disposition, per RFC 6047 iMIP transport conventions. The
    /// transfer encoding (`7bit`/`8bit`) is chosen by ``calendarInviteText(for:use8BitMIME:)``.
    private func writeCalendarAlternative(
        context: MIMEBuildContext,
        invite: Attachment,
        icsText: String,
        encoding: String,
        into content: inout String
    ) {
        content += "Content-Type: multipart/alternative; boundary=\"\(context.altBoundary)\"\r\n\r\n"
        content += "This is a multi-part message in MIME format.\r\n\r\n"

        content += "--\(context.altBoundary)\r\n"
        content += "Content-Type: text/plain; charset=UTF-8\r\n"
        content += "Content-Transfer-Encoding: \(context.textEncoding)\r\n\r\n"
        content += "\(context.textBody)\r\n\r\n"

        content += "--\(context.altBoundary)\r\n"
        content += "Content-Type: \(invite.mimeType)\r\n"
        content += "Content-Transfer-Encoding: \(encoding)\r\n\r\n"
        content += terminatedICSBody(icsText)

        content += "--\(context.altBoundary)--\r\n"
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
        // MIME (RFC 2045) requires CRLF line endings between wrapped base64
        // lines. `.endLineWithCarriageReturn` alone emits a bare CR, which some
        // clients fail to de-wrap, saving the raw base64 text as the attachment.
        data.base64EncodedString(options: [
            .lineLength76Characters,
            .endLineWithCarriageReturn,
            .endLineWithLineFeed
        ])
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
