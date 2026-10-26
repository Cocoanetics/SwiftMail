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

     Each part records the multipart bodies that enclose it
     (``MessagePart/enclosingMultiparts``).

     - Parameter structure: The body structure to process
     - Parameter sectionPath: Path representing the section numbering, default is empty
     */
    public init(_ structure: BodyStructure, sectionPath: [Int] = []) {
        self.init(structure, sectionPath: sectionPath, enclosing: [])
    }

    private init(_ structure: BodyStructure, sectionPath: [Int], enclosing: [EnclosingMultipart]) {
        self = []
        switch structure {
            case .singlepart(let part):
                appendSinglepart(part, sectionPath: sectionPath, enclosing: enclosing)
            case .multipart(let multipart):
                appendMultipart(multipart, sectionPath: sectionPath, enclosing: enclosing)
        }
    }

    /// Build the `MessagePart` for one ``BodyStructure.Singlepart`` and append
    /// it, then recurse into the embedded body of any `message/rfc822` part.
    private mutating func appendSinglepart(
        _ part: BodyStructure.Singlepart,
        sectionPath: [Int],
        enclosing: [EnclosingMultipart]
    ) {
        let section = Section(sectionPath.isEmpty ? [1] : sectionPath)
        let contentType = Self.contentType(for: part)
        let encoding = part.fields.encoding?.debugDescription
        let dispositionAndFilename = Self.dispositionAndFilename(for: part, contentType: contentType)
        var filename = dispositionAndFilename.filename
        let disposition = dispositionAndFilename.disposition
        let contentId: String? = part.fields.id.map { String($0) }.flatMap { $0.isEmpty ? nil : $0 }
        // body-fld-octets is mandatory in BODYSTRUCTURE, so every parsed
        // singlepart reports a size; zero is a valid size for an empty part.
        let size = part.fields.octetCount

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
            size: size,
            data: nil,
            embeddedMessageInfo: embeddedMessageInfo,
            enclosingMultiparts: enclosing
        ))

        if case .message(let message) = part.kind {
            appendEmbeddedRFC822(message.body, sectionPath: sectionPath, enclosing: enclosing)
        }
    }

    /// Recursively walk a multipart structure, numbering children per RFC 3501.
    private mutating func appendMultipart(
        _ multipart: BodyStructure.Multipart,
        sectionPath: [Int],
        enclosing: [EnclosingMultipart]
    ) {
        let enclosing = enclosing + [EnclosingMultipart(
            path: sectionPath, subtype: multipart.mediaSubtype.debugDescription)]
        for (index, childPart) in multipart.parts.enumerated() {
            let childSectionPath = sectionPath.isEmpty ? [index + 1] : sectionPath + [index + 1]
            self.append(contentsOf: [MessagePart](childPart, sectionPath: childSectionPath, enclosing: enclosing))
        }
    }

    /// For message/rfc822, append the nested body's parts. Section numbering
    /// per RFC 3501: multipart children get parent.N; a singlepart inner body
    /// is at parent.1.
    private mutating func appendEmbeddedRFC822(
        _ body: BodyStructure,
        sectionPath: [Int],
        enclosing: [EnclosingMultipart]
    ) {
        let parentPath = sectionPath.isEmpty ? [1] : sectionPath
        switch body {
            case .multipart:
                self.append(contentsOf: [MessagePart](body, sectionPath: parentPath, enclosing: enclosing))
            case .singlepart:
                self.append(contentsOf: [MessagePart](body, sectionPath: parentPath + [1], enclosing: enclosing))
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
        // The parameters that say how the text is read: its charset, and the
        // RFC 3676 `format` and `delsp` a `format=flowed` body is decoded by,
        // each in its plain or RFC 2231 extended spelling (`charset*`,
        // `charset*0*`, ...), which `contentTypeParameter(named:)` reads back.
        for name in ["charset", "format", "delsp"] {
            for (key, value) in part.fields.parameters where isSpelling(key.lowercased(), ofParameter: name) {
                contentType += "; \(key.lowercased())=\(parameterValue(value))"
            }
        }
        return contentType
    }

    /// Whether `key` (lowercased) is parameter `name` in its plain spelling or an
    /// RFC 2231 extended one: `name*`, or a continuation `name*N` / `name*N*`.
    private static func isSpelling(_ key: String, ofParameter name: String) -> Bool {
        guard key.hasPrefix(name) else { return false }
        let rest = key.dropFirst(name.count)
        guard let star = rest.first else { return true }
        return star == "*" && rest.dropFirst().allSatisfy { $0 == "*" || ($0.isASCII && $0.isNumber) }
    }

    /// A BODYSTRUCTURE parameter value written back as RFC 2045 writes it: bare
    /// when it is a token, else a quoted-string, so a value holding `;`, `=` or
    /// a space stays the one parameter it was rather than adding another.
    private static func parameterValue(_ value: String) -> String {
        // RFC 2045 §5.1 `tspecials`: the characters a token cannot hold.
        let tspecials = Set("()<>@,;:\\\"/[]?=".unicodeScalars)
        let isToken = !value.isEmpty && value.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value < 0x7F && !tspecials.contains($0)
        }
        if isToken { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
            // Content-Disposition's filename overrides Content-Type's filename/name,
            // in its plain spelling or the RFC 2231 extended one (`filename*=UTF-8''...`,
            // `filename*0*=...`), which non-ASCII names are written in.
            if let extended = extendedParameter("filename", in: disp.parameters.map { ($0.key, $0.value) }) {
                filename = extended
            } else {
                for (key, value) in disp.parameters where key.lowercased() == "filename" && !value.isEmpty {
                    filename = value
                    break
                }
            }
        }

        // Default filename for text/calendar parts (Outlook often omits filename).
        if filename == nil, contentType.lowercased().hasPrefix("text/calendar") {
            filename = "invite.ics"
        }

        // Content-ID fallback for media parts only (images and other non-text
        // content). A text part with a Content-ID, such as the root of a
        // multipart/related body (RFC 2387), is text to read, not a file; a
        // message/rfc822 part is named from its envelope subject.
        let isMediaKind: Bool = {
            if case .basic = part.kind { return true }
            return false
        }()
        if isMediaKind, filename == nil, let contentId = part.fields.id {
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

    /// The decoded value of an RFC 2231 extended parameter (`name*` or the
    /// continuations `name*0*`, `name*1`, ...) among BODYSTRUCTURE parameters, or nil
    /// when the parameter only appears in its plain spelling.
    private static func extendedParameter(_ name: String, in parameters: [(String, String)]) -> String? {
        guard parameters.contains(where: { $0.0.lowercased().hasPrefix(name + "*") }) else { return nil }
        // Write the parameters back as a header value and let the RFC 2231 reader decode them.
        let header = "x; " + parameters.map { "\($0.0)=\(parameterValue($0.1))" }.joined(separator: "; ")
        guard let value = EMLParser.extractExtendedHeaderParam(from: header, named: name),
              !value.isEmpty else { return nil }
        return value
    }

    private static func filenameFromContentTypeParameters(_ part: BodyStructure.Singlepart) -> String? {
        let parameters = part.fields.parameters.map { ($0.key, $0.value) }
        if let extended = extendedParameter("filename", in: parameters) ?? extendedParameter("name", in: parameters) {
            return extended
        }
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
        var info = MessageInfo(
            sequenceNumber: SequenceNumber(0), // Not available for embedded messages
            subject: subject,
            date: Self.parseEnvelopeDate(envelope.date)
        )
        info.fromAddresses = .entries(fromEnvelope: envelope.from)
        info.replyToAddresses = .entries(fromEnvelope: envelope.reply)
        info.toAddresses = .entries(fromEnvelope: envelope.to)
        info.ccAddresses = .entries(fromEnvelope: envelope.cc)
        info.bccAddresses = .entries(fromEnvelope: envelope.bcc)
        return info
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
