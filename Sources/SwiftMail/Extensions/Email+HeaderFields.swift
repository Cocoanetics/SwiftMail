import Foundation

extension Email {
    /// One top-level header field, written as `name: value` and a CRLF.
    struct HeaderField {
        let name: String
        let value: String
        /// Whether this is the `Bcc` field this library writes from
        /// ``Email/bccRecipients`` for a copy the sender keeps.
        var namesBccRecipients = false
    }

    /// Top-level RFC 5322 header fields (`From`, `To`, `Cc`, optional `Bcc`, `Subject`,
    /// `Date`, `Message-Id`, `MIME-Version`) plus any caller-supplied additional
    /// headers, suppressing a duplicate `Message-Id` when one is already set.
    func headerFields(includeBccHeader: Bool) -> [HeaderField] {
        var fields = [HeaderField(name: "From", value: self.sender.headerString())]
        let bcc = includeBccHeader ? [("Bcc", self.bccRecipients)] : []
        for (name, addresses) in [("To", self.recipients), ("Cc", self.ccRecipients)] + bcc where !addresses.isEmpty {
            fields.append(HeaderField(
                name: name, value: addresses.map { $0.headerString() }.joined(separator: ", "),
                namesBccRecipients: name == "Bcc"))
        }
        fields.append(HeaderField(name: "Subject", value: self.subject.rfc2047EncodedHeader()))
        fields.append(HeaderField(name: "Date", value: Self.rfc2822Date()))

        let resolvedHeaderID = resolvedMessageIDHeader()
        let suppressAdditionalMessageID = self.messageID != nil || resolvedHeaderID != nil
        if let msgID = self.messageID ?? resolvedHeaderID {
            fields.append(HeaderField(name: "Message-Id", value: msgID.description))
        } else if !hasMessageIDHeaderInAdditionalHeaders() {
            let generated = MessageID.generate(domain: Self.senderDomain(from: self.sender))
            fields.append(HeaderField(name: "Message-Id", value: generated.description))
        }
        fields.append(HeaderField(name: "MIME-Version", value: "1.0"))

        if let additionalHeaders {
            for (key, value) in additionalHeaders.sorted(by: { $0.key < $1.key }) {
                if suppressAdditionalMessageID && Self.isMessageIDHeaderName(key) {
                    continue
                }
                fields.append(HeaderField(name: key, value: value))
            }
        }
        return fields
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
