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
        // Initialize with empty array
        self = []

        switch structure {
        case .singlepart(let part):
            // Determine the part number as Section type for IMAP
            let section = Section(sectionPath.isEmpty ? [1] : sectionPath)

            // Extract content type and other metadata
            var contentType = ""

            switch part.kind {
                case .basic(let mediaType):
                    contentType = "\(String(mediaType.topLevel))/\(String(mediaType.sub))"
                case .text(let text):
                    contentType = "text/\(String(text.mediaSubtype))"
                case .message(let message):
                    contentType = "message/\(String(message.message))"
            }

            // Add charset parameter if present
            if let charset = part.fields.parameters.first(where: { $0.key.lowercased() == "charset" })?.value {
                contentType += "; charset=\(charset)"
            }

            // Extract disposition and filename if available
            var disposition: String? = nil
            var filename: String? = nil
            let encoding: String? = part.fields.encoding?.debugDescription

            // Check Content-Type parameters for filename or name first
            for (key, value) in part.fields.parameters {
                let lowerKey = key.lowercased()
                if (lowerKey == "filename" || lowerKey == "name"), !value.isEmpty {
                    filename = value
                    break
                }
            }

            // Then check Content-Disposition (which overrides Content-Type filename if present)
            if let ext = part.extension, let dispAndLang = ext.dispositionAndLanguage {
                if let disp = dispAndLang.disposition {
                    // Extract just the disposition kind (attachment, inline, etc.)
                    disposition = String(disp.kind.rawValue)

                    for (key, value) in disp.parameters {
                        if key.lowercased() == "filename" && !value.isEmpty {
                            filename = value
                            break
                        }
                    }
                }
            }

            // Fallback: If still no filename and we have a content ID, use it.
            // Skip for message/rfc822 — those get filename from envelope subject instead.
            let isMessageKind: Bool = {
                if case .message = part.kind { return true }
                return false
            }()
            if !isMessageKind, filename == nil, let contentId = part.fields.id {
                let idString = String(contentId)
                if !idString.isEmpty {
                    // Remove angle brackets if present (common in Content-ID)
                    let cleanId = idString.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    if !cleanId.isEmpty {
                        // Use the content ID directly as the filename
                        filename = cleanId
                    }
                }
            }

            // Default filename for text/calendar parts (Outlook often omits filename)
            if filename == nil, contentType.lowercased().hasPrefix("text/calendar") {
                filename = "invite.ics"
            }

            // Decode any MIME-encoded filename
            if let name = filename {
                let decoded = name.decodeMIMEHeader()
                if !decoded.isEmpty {
                    filename = decoded
                }
            }

            // Set content ID if available
            let contentId: String? = part.fields.id.map {
                let str = String($0)
                return str.isEmpty ? nil : str
            } ?? nil

            // For message/rfc822: extract envelope headers, derive filename from subject
            var embeddedHeaders: EmbeddedMessageHeaders? = nil
            if case .message(let message) = part.kind {
                let envelope = message.envelope
                let subject: String? = {
                    guard let buf = envelope.subject else { return nil }
                    let raw = buf.stringValue
                    guard !raw.isEmpty else { return nil }
                    let decoded = raw.decodeMIMEHeader()
                    return decoded.isEmpty ? raw : decoded
                }()
                let from = Self.formatEnvelopeAddresses(envelope.from)
                let to = Self.formatEnvelopeAddresses(envelope.to)
                let cc = envelope.cc.isEmpty ? nil : Self.formatEnvelopeAddresses(envelope.cc)
                let date = envelope.date.map { String($0) }
                embeddedHeaders = EmbeddedMessageHeaders(subject: subject, from: from, to: to, cc: cc, date: date)

                // Use envelope subject as filename (matching TB behavior), fall back to "message.eml"
                if filename == nil {
                    if let subject, !subject.isEmpty {
                        // Sanitize subject for filename: remove characters invalid in filenames
                        let invalidChars = try? NSRegularExpression(pattern: "[/\\\\:*?\"<>|]")
                        let range = NSRange(subject.startIndex..., in: subject)
                        let sanitized = (invalidChars?.stringByReplacingMatches(in: subject, range: range, withTemplate: "-") ?? subject)
                            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        filename = sanitized.isEmpty ? "message.eml" : "\(sanitized).eml"
                    } else {
                        filename = "message.eml"
                    }
                }
            }

            // Create a message part with empty data
            let messagePart = MessagePart(
                section: section,
                contentType: contentType,
                disposition: disposition,
                encoding: encoding?.isEmpty == true ? nil : encoding,
                filename: filename,
                contentId: contentId,
                data: nil,
                embeddedHeaders: embeddedHeaders
            )

            // Append to our result
            self.append(messagePart)

            // For message/rfc822, recurse into the nested body structure to extract
            // inner parts (text/html, text/plain, nested attachments).
            // Section numbering per RFC 3501: parts within a message/rfc822 at section N
            // are addressed as N.1, N.2, etc. — regardless of whether the nested body
            // is multipart or singlepart (singlepart content is part 1).
            if case .message(let message) = part.kind {
                let parentPath = sectionPath.isEmpty ? [1] : sectionPath
                switch message.body {
                case .multipart:
                    // Multipart children: parent.1, parent.2, etc. — handled by multipart case
                    let nestedParts = Array<MessagePart>(message.body, sectionPath: parentPath)
                    self.append(contentsOf: nestedParts)
                case .singlepart:
                    // Single-part content is at parent.1 per RFC 3501
                    let nestedParts = Array<MessagePart>(message.body, sectionPath: parentPath + [1])
                    self.append(contentsOf: nestedParts)
                }
            }

        case .multipart(let multipart):
            // For multipart messages, process each child part and collect results
            for (index, childPart) in multipart.parts.enumerated() {
                // Create a new section path array by appending the current index + 1
                let childSectionPath = sectionPath.isEmpty ? [index + 1] : sectionPath + [index + 1]

                // Recursively process child parts
                let childParts = Array<MessagePart>(childPart, sectionPath: childSectionPath)

                // Append all child parts to our result
                self.append(contentsOf: childParts)
            }
        }
    }

    // MARK: - Envelope Helpers

    /// Format an array of IMAP envelope addresses into a display string.
    private static func formatEnvelopeAddresses(_ addresses: [EmailAddressListElement]) -> String? {
        guard !addresses.isEmpty else { return nil }
        return addresses.map { formatEnvelopeAddress($0) }.joined(separator: ", ")
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
}
