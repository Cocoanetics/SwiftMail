// MessagePart+MIMEHeaderFilenames.swift
// Restores the backslashes a server's BODYSTRUCTURE dropped from filenames

import Foundation

extension Array where Element == MessagePart {
    /// The parts whose filename is checked against the part's own MIME header.
    ///
    /// Outlook writes Windows paths into filenames without escaping them
    /// (`name="docs\reference\a.md"`). A server that builds BODYSTRUCTURE by
    /// the letter of RFC 2045 resolves each `\x` to `x` — Dovecot does — so
    /// the name arrives as `docsreferencea.md`, and only the part's MIME header
    /// still holds the backslashes. Every named part is a candidate, since
    /// nothing in BODYSTRUCTURE shows that a backslash was lost.
    ///
    /// A message that is a single part has no `1.MIME` of its own to ask for,
    /// so it has no candidates.
    var sectionsForFilenameCheck: [Section] {
        guard !(count == 1 && first?.section == Section([1])) else { return [] }
        return filter { $0.filename?.isEmpty == false }.map(\.section)
    }

    /// The parts with each filename replaced by the one in the part's MIME
    /// header — but only where the header's name is the same name with
    /// backslashes the BODYSTRUCTURE name has lost. Any other difference keeps
    /// the BODYSTRUCTURE name, so the header can put back backslashes and
    /// nothing else.
    func restoringFilenames(fromMIMEHeaders headers: [Section: Data]) -> [MessagePart] {
        map { part in
            guard let current = part.filename,
                  let header = headers[part.section],
                  let restored = Self.filename(inMIMEHeader: header),
                  restored != current,
                  restored.replacingOccurrences(of: "\\", with: "") == current
            else { return part }

            return MessagePart(
                section: part.section,
                contentType: part.contentType,
                disposition: part.disposition,
                encoding: part.encoding,
                filename: restored,
                contentId: part.contentId,
                size: part.size,
                data: part.data,
                embeddedMessageInfo: part.embeddedMessageInfo
            )
        }
    }

    /// The filename a part's MIME header names, read the way an `.eml` part's
    /// is: `filename*`, `filename`, `name*`, `name` across Content-Type and
    /// Content-Disposition, then RFC 2047 decoded.
    private static func filename(inMIMEHeader data: Data) -> String? {
        let headers = EMLParser.parseHeaders(EMLParser.decodeHeaderBlock(data))
        guard let filename = EMLParser.extractFilename(
            from: headers["content-type"] ?? "",
            headers["content-disposition"] ?? ""
        ) else { return nil }
        return EMLParser.decodeRFC2047(filename) ?? filename
    }
}
