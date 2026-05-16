// MessagePart+BodyStructure.swift
// Extension that adds an initializer to Array<MessagePart> from BodyStructure

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

extension [MessagePart] {
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
        // Initialize with empty array
        self = []

        switch structure {
            case let .singlepart(part):
                appendSinglepart(part, sectionPath: sectionPath)

            case let .multipart(multipart):
                // For multipart messages, process each child part and collect results
                for (index, childPart) in multipart.parts.enumerated() {
                    // Create a new section path array by appending the current index + 1
                    let childSectionPath = sectionPath.isEmpty ? [index + 1] : sectionPath + [index + 1]

                    // Recursively process child parts
                    let childParts = [MessagePart](childPart, sectionPath: childSectionPath)

                    // Append all child parts to our result
                    append(contentsOf: childParts)
                }
        }
    }

    /// Build a MessagePart for a singlepart body structure, append it, and recurse into nested message/rfc822 bodies.
    private mutating func appendSinglepart(
        _ part: BodyStructure.Singlepart,
        sectionPath: [Int]
    ) {
        let section = Section(sectionPath.isEmpty ? [1] : sectionPath)

        let contentType = Self.contentType(for: part)
        let encoding: String? = part.fields.encoding?.debugDescription
        var filename = Self.initialFilename(from: part)
        let disposition = Self.disposition(from: part, filename: &filename)

        // Default filename for text/calendar parts (Outlook often omits filename)
        if filename == nil, contentType.lowercased().hasPrefix("text/calendar") {
            filename = "invite.ics"
        }

        // Fallback to Content-ID for non-message kinds.
        let isMessageKind: Bool = {
            if case .message = part.kind { return true }
            return false
        }()
        if !isMessageKind, filename == nil {
            filename = Self.filenameFromContentID(part.fields.id)
        }

        // Decode any MIME-encoded filename
        if let name = filename {
            let decoded = name.decodeMIMEHeader()
            if !decoded.isEmpty {
                filename = decoded
            }
        }

        let contentId = Self.contentID(from: part.fields.id)

        var embeddedMessageInfo: MessageInfo?
        if case let .message(message) = part.kind {
            embeddedMessageInfo = Self.makeEmbeddedMessageInfo(from: message, filename: &filename)
        }

        let messagePart = MessagePart(
            section: section,
            contentType: contentType,
            disposition: disposition,
            encoding: encoding?.isEmpty == true ? nil : encoding,
            filename: filename,
            contentId: contentId,
            data: nil,
            embeddedMessageInfo: embeddedMessageInfo
        )
        append(messagePart)

        // For message/rfc822, recurse into the nested body structure to extract
        // inner parts (text/html, text/plain, nested attachments).
        // Section numbering per RFC 3501: parts within a message/rfc822 at section N
        // are addressed as N.1, N.2, etc. — regardless of whether the nested body
        // is multipart or singlepart (singlepart content is part 1).
        if case let .message(message) = part.kind {
            let parentPath = sectionPath.isEmpty ? [1] : sectionPath
            switch message.body {
                case .multipart:
                    let nestedParts = [MessagePart](message.body, sectionPath: parentPath)
                    append(contentsOf: nestedParts)
                case .singlepart:
                    let nestedParts = [MessagePart](message.body, sectionPath: parentPath + [1])
                    append(contentsOf: nestedParts)
            }
        }
    }

    /// Build the Content-Type string (including charset parameter, if present) for a singlepart.
    private static func contentType(for part: BodyStructure.Singlepart) -> String {
        var contentType = switch part.kind {
            case let .basic(mediaType):
                "\(String(mediaType.topLevel))/\(String(mediaType.sub))"
            case let .text(text):
                "text/\(String(text.mediaSubtype))"
            case let .message(message):
                "message/\(String(message.message))"
        }
        if let charset = part.fields.parameters.first(where: { $0.key.lowercased() == "charset" })?.value {
            contentType += "; charset=\(charset)"
        }
        return contentType
    }

    /// Filename from Content-Type "filename" or "name" parameters, if present and non-empty.
    private static func initialFilename(from part: BodyStructure.Singlepart) -> String? {
        for (key, value) in part.fields.parameters {
            let lowerKey = key.lowercased()
            if lowerKey == "filename" || lowerKey == "name", !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Extract disposition from Content-Disposition, and override `filename` if a disposition filename is present.
    private static func disposition(from part: BodyStructure.Singlepart, filename: inout String?) -> String? {
        guard let ext = part.extension,
              let dispAndLang = ext.dispositionAndLanguage,
              let disp = dispAndLang.disposition else {
            return nil
        }

        let disposition = String(disp.kind.rawValue)
        for (key, value) in disp.parameters where key.lowercased() == "filename" && !value.isEmpty {
            filename = value
            break
        }
        return disposition
    }

    /// Build a filename from the message's Content-ID by stripping any angle brackets.
    private static func filenameFromContentID(_ contentID: String?) -> String? {
        guard let contentID, !contentID.isEmpty else { return nil }
        let cleanId = contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return cleanId.isEmpty ? nil : cleanId
    }

    /// Extract a Content-ID string from a singlepart's fields, or nil when missing/empty.
    private static func contentID(from contentID: String?) -> String? {
        guard let contentID, !contentID.isEmpty else { return nil }
        return contentID
    }

    /// Build embedded MessageInfo from a message/rfc822 envelope and assign a filename if not already set.
    private static func makeEmbeddedMessageInfo(
        from message: BodyStructure.Singlepart.Message,
        filename: inout String?
    ) -> MessageInfo {
        let envelope = message.envelope
        let subject: String? = {
            guard let buf = envelope.subject else { return nil }
            let raw = buf.stringValue
            guard !raw.isEmpty else { return nil }
            let decoded = raw.decodeMIMEHeader()
            return decoded.isEmpty ? raw : decoded
        }()
        let from: String? = {
            guard !envelope.from.isEmpty else { return nil }
            return formatEnvelopeAddress(envelope.from[0])
        }()

        // Use envelope subject as filename, fall back to "message.eml"
        if filename == nil {
            filename = sanitizedEMLFilename(from: subject)
        }

        return MessageInfo(
            sequenceNumber: SequenceNumber(0), // Not available for embedded messages
            subject: subject,
            from: from,
            to: formatEnvelopeAddressesArray(envelope.to),
            cc: formatEnvelopeAddressesArray(envelope.cc),
            date: parseEnvelopeDate(envelope.date)
        )
    }

    /// Sanitize an envelope subject for use as an `.eml` filename. Falls back to "message.eml".
    private static func sanitizedEMLFilename(from subject: String?) -> String {
        guard let subject, !subject.isEmpty else { return "message.eml" }
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
            case let .singleAddress(emailAddress):
                let name: String = {
                    guard let buf = emailAddress.personName else { return "" }
                    let raw = buf.stringValue
                    guard !raw.isEmpty else { return "" }
                    let decoded = raw.decodeMIMEHeader()
                    return decoded.isEmpty ? raw : decoded
                }()
                let mailbox = emailAddress.mailbox.map(\.stringValue) ?? ""
                let host = emailAddress.host.map(\.stringValue) ?? ""
                if !name.isEmpty {
                    return "\"\(name)\" <\(mailbox)@\(host)>"
                } else {
                    return "\(mailbox)@\(host)"
                }
            case let .group(group):
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
