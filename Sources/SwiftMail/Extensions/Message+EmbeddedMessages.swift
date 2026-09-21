// Message+EmbeddedMessages.swift
// Reassemble `message/rfc822` parts into Messages of their own.

import Foundation

public extension Message {

    /// The messages carried as `message/rfc822` parts, each with its own parts
    /// renumbered as if it had been parsed on its own.
    ///
    /// Parts are stored flat with dotted section numbers, so an embedded
    /// message's body lives at `4.1` while the message itself is `4`. This
    /// regroups them: the returned message's own body is back at `1`, so the
    /// same code that reads a top-level message reads a forwarded one, at any
    /// depth — a message nested two levels deep is reached through the
    /// `embeddedMessages` of the one that contains it.
    ///
    /// Empty for a message with nothing embedded, which is the common case.
    var embeddedMessages: [Message] {
        // `ownParts`, not `parts`: a message forwarded inside a forwarded
        // message is that message's child, not this one's. Scanning the flat
        // array would return it here *and* again from its real parent, so a
        // caller that recurses would visit it twice.
        ownParts.compactMap { part -> Message? in
            guard let info = part.embeddedMessageInfo else { return nil }
            let prefix = part.section.components

            let nested = parts.compactMap { candidate -> MessagePart? in
                let components = candidate.section.components
                // Strictly below this part, not the part itself.
                guard components.count > prefix.count,
                      Array(components.prefix(prefix.count)) == prefix else { return nil }

                return MessagePart(
                    section: Section(Array(components.dropFirst(prefix.count))),
                    contentType: candidate.contentType,
                    disposition: candidate.disposition,
                    encoding: candidate.encoding,
                    filename: candidate.filename,
                    contentId: candidate.contentId,
                    size: candidate.size,
                    data: candidate.data,
                    embeddedMessageInfo: candidate.embeddedMessageInfo
                )
            }

            var header = info
            header.parts = nested
            return Message(header: header, parts: nested)
        }
    }
}
