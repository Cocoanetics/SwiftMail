// MessagePart+BodyStructure.swift
// Extension that adds an initializer to Array<MessagePart> from BodyStructure

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

extension Array where Element == MessagePart {
    /**
     Initialize an array of message parts from a BodyStructure

     This creates a flat array of leaf message parts without fetching any content.
     For message/rfc822 parts, it recurses into the nested body structure to extract
     inner parts (text/html, text/plain, nested attachments) while keeping the
     message/rfc822 part itself as an attachment entry with envelope metadata.

     - Parameter structure: The body structure to process
     - Parameter sectionPath: Path representing the section numbering, default is empty
     */
    public init(_ structure: BodyStructure, sectionPath: [Int] = []) {
        self = []
        switch structure {
            case .singlepart(let part):
                appendSinglepart(part, sectionPath: sectionPath)
            case .multipart(let multipart):
                appendMultipart(multipart, sectionPath: sectionPath)
        }
    }

    /// Build the `MessagePart` for one ``BodyStructure.Singlepart`` and append
    /// it, then recurse into the embedded body of any `message/rfc822` part.
    private mutating func appendSinglepart(
        _ part: BodyStructure.Singlepart,
        sectionPath: [Int]
    ) {
        let section = Section(sectionPath.isEmpty ? [1] : sectionPath)
        let contentType = Self.contentType(for: part)
        let encoding = part.fields.encoding?.debugDescription
        let dispositionAndFilename = Self.dispositionAndFilename(for: part, contentType: contentType)
        var filename = dispositionAndFilename.filename
        let disposition = dispositionAndFilename.disposition
        let contentId: String? = part.fields.id.map { String($0) }.flatMap { $0.isEmpty ? nil : $0 }

        // message/rfc822: extract envelope metadata and derive a filename
        // from the subject when one isn't already set.
        var embeddedMessageInfo: MessageInfo?
        if case .message(let message) = part.kind {
            embeddedMessageInfo = Self.embeddedMessageInfo(from: message.envelope)
            if filename == nil {
                filename = Self.filename(forEmbeddedSubject: embeddedMessageInfo?.subject)
            }
        }

        self.append(MessagePart(
            section: section,
            contentType: contentType,
            disposition: disposition,
            encoding: encoding?.isEmpty == true ? nil : encoding,
            filename: filename,
            contentId: contentId,
            data: nil,
            embeddedMessageInfo: embeddedMessageInfo
        ))

        if case .message(let message) = part.kind {
            appendEmbeddedRFC822(message.body, sectionPath: sectionPath)
        }
    }

    /// Recursively walk a multipart structure, numbering children per RFC 3501.
    private mutating func appendMultipart(
        _ multipart: BodyStructure.Multipart,
        sectionPath: [Int]
    ) {
        for (index, childPart) in multipart.parts.enumerated() {
            let childSectionPath = sectionPath.isEmpty ? [index + 1] : sectionPath + [index + 1]
            self.append(contentsOf: [MessagePart](childPart, sectionPath: childSectionPath))
        }
    }

    /// For message/rfc822, append the nested body's parts. Section numbering
    /// per RFC 3501: multipart children get parent.N; a singlepart inner body
    /// is at parent.1.
    private mutating func appendEmbeddedRFC822(
        _ body: BodyStructure,
        sectionPath: [Int]
    ) {
        let parentPath = sectionPath.isEmpty ? [1] : sectionPath
        switch body {
            case .multipart:
                self.append(contentsOf: [MessagePart](body, sectionPath: parentPath))
            case .singlepart:
                self.append(contentsOf: [MessagePart](body, sectionPath: parentPath + [1]))
        }
    }

    /// Render the MIME content-type string (`type/subtype[; charset=...]`)
    /// from a singlepart's typed `kind`.
    private static func contentType(for part: BodyStructure.Singlepart) -> String {
        var contentType: String
        switch part.kind {
            case .basic(let mediaType):
                contentType = "\(String(mediaType.topLevel))/\(String(mediaType.sub))"
            case .text(let text):
                contentType = "text/\(String(text.mediaSubtype))"
            case .message(let message):
                contentType = "message/\(String(message.message))"
        }
        if let charset = part.fields.parameters.first(where: { $0.key.lowercased() == "charset" })?.value {
            contentType += "; charset=\(charset)"
        }
        return contentType
    }

    /// Pull the disposition and filename out of a singlepart's Content-Type
    /// parameters, Content-Disposition extension, content-id fallback, and
    /// the text/calendar default. Returns the resolved values; the
    /// message/rfc822 envelope path is handled separately.
    private static func dispositionAndFilename(
        for part: BodyStructure.Singlepart,
        contentType: String
    ) -> (disposition: String?, filename: String?) {
        var filename = filenameFromContentTypeParameters(part)
        var disposition: String?

        if let ext = part.extension, let disp = ext.dispositionAndLanguage?.disposition {
            disposition = String(disp.kind.rawValue)
            // Content-Disposition's filename overrides Content-Type's filename/name.
            for (key, value) in disp.parameters where key.lowercased() == "filename" && !value.isEmpty {
                filename = value
                break
            }
        }

        // Default filename for text/calendar parts (Outlook often omits filename).
        if filename == nil, contentType.lowercased().hasPrefix("text/calendar") {
            filename = "invite.ics"
        }

        // Content-ID fallback (skip for message/rfc822 — that uses the envelope subject).
        let isMessageKind: Bool = {
            if case .message = part.kind { return true }
            return false
        }()
        if !isMessageKind, filename == nil, let contentId = part.fields.id {
            let cleanId = String(contentId).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if !cleanId.isEmpty {
                filename = cleanId
            }
        }

        // Decode any MIME-encoded filename (=?UTF-8?Q?...?=).
        if let name = filename {
            let decoded = name.decodeMIMEHeader()
            if !decoded.isEmpty {
                filename = decoded
            }
        }
        return (disposition, filename)
    }

    private static func filenameFromContentTypeParameters(_ part: BodyStructure.Singlepart) -> String? {
        for (key, value) in part.fields.parameters {
            let lowerKey = key.lowercased()
            if (lowerKey == "filename" || lowerKey == "name") && !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Build the embedded `MessageInfo` for a `message/rfc822` part from its envelope.
    private static func embeddedMessageInfo(from envelope: Envelope) -> MessageInfo {
        let subject: String? = {
            guard let raw = envelope.subject?.stringValue, !raw.isEmpty else { return nil }
            let decoded = raw.decodeMIMEHeader()
            return decoded.isEmpty ? raw : decoded
        }()
        let from: String? = envelope.from.isEmpty
            ? nil
            : Self.formatEnvelopeAddress(envelope.from[0])
        return MessageInfo(
            sequenceNumber: SequenceNumber(0), // Not available for embedded messages
            subject: subject,
            from: from,
            to: Self.formatEnvelopeAddressesArray(envelope.to),
            cc: Self.formatEnvelopeAddressesArray(envelope.cc),
            date: Self.parseEnvelopeDate(envelope.date)
        )
    }

    /// Derive an `.eml` filename for an embedded `message/rfc822` part from its
    /// envelope subject (sanitising filesystem-invalid characters); falls back
    /// to `"message.eml"` when there's no usable subject.
    private static func filename(forEmbeddedSubject subject: String?) -> String {
        guard let subject, !subject.isEmpty else { return "message.eml" }
        // Sanitize subject for filename: remove characters invalid in filenames
        let invalidChars = try? NSRegularExpression(pattern: "[/\\\\:*?\"<>|]")
        let range = NSRange(subject.startIndex..., in: subject)
        let replaced = invalidChars?.stringByReplacingMatches(
            in: subject,
            range: range,
            withTemplate: "-"
        ) ?? subject
        let sanitized = replaced.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return sanitized.isEmpty ? "message.eml" : "\(sanitized).eml"
    }

    // MARK: - Envelope Helpers

    /// Format an array of IMAP envelope addresses into individual display strings.
    /// Matches the format used by FetchMessageInfoHandler for MessageInfo.to/cc.
    private static func formatEnvelopeAddressesArray(_ addresses: [EmailAddressListElement]) -> [String] {
        addresses.map { formatEnvelopeAddress($0) }
    }

    private static func formatEnvelopeAddress(_ address: EmailAddressListElement) -> String {
        switch address {
            case .singleAddress(let emailAddress):
                let name: String = {
                    guard let buf = emailAddress.personName else { return "" }
                    let raw = buf.stringValue
                    guard !raw.isEmpty else { return "" }
                    let decoded = raw.decodeMIMEHeader()
                    return decoded.isEmpty ? raw : decoded
                }()
                let mailbox = emailAddress.mailbox.map { $0.stringValue } ?? ""
                let host = emailAddress.host.map { $0.stringValue } ?? ""
                if !name.isEmpty {
                    return "\"\(name)\" <\(mailbox)@\(host)>"
                } else {
                    return "\(mailbox)@\(host)"
                }
            case .group(let group):
                let groupName = group.groupName.stringValue.decodeMIMEHeader()
                let members = group.children.map { formatEnvelopeAddress($0) }.joined(separator: ", ")
                return "\(groupName): \(members);"
        }
    }

    /// Parse an RFC 5322 date from the IMAP envelope into a Date.
    /// Uses the same format list as FetchMessageInfoHandler.
    private static func parseEnvelopeDate(_ date: InternetMessageDate?) -> Date? {
        guard let date else { return nil }
        let dateString = String(date)
        let cleanDateString = dateString.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yy HH:mm:ss Z"
        ]

        for format in formats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: cleanDateString) {
                return parsed
            }
        }
        return nil
    }
}
