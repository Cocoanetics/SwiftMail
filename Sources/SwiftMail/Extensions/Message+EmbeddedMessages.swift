// Message+EmbeddedMessages.swift
// Reassemble `message/rfc822` parts into Messages of their own.

import Foundation

public extension Message {

    /// A message carried as a `message/rfc822` part, together with that part.
    struct EmbeddedMessage: Sendable {
        /// The `message/rfc822` part of the containing message, which carries
        /// its section, filename and disposition.
        public let part: MessagePart

        /// The carried message, its parts renumbered as if it had been parsed
        /// on its own.
        public let message: Message
    }

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
        embeddedMessagesWithParts.map(\.message)
    }

    /// ``embeddedMessages``, each paired with the `message/rfc822` part that
    /// carries it, in the same order.
    ///
    /// The part is what a caller needs to point back at the attachment: its
    /// filename names it, and its section is its number within this message.
    /// At the top level that is the number to fetch it by. A pair reached
    /// through an embedded message is numbered within that renumbered message,
    /// so its fetch section is each enclosing part's section followed by its
    /// own — `2` inside the message at `2` is fetched as `2.2`.
    var embeddedMessagesWithParts: [EmbeddedMessage] {
        // `ownParts`, not `parts`: a message forwarded inside a forwarded
        // message is that message's child, not this one's. Scanning the flat
        // array would return it here *and* again from its real parent, so a
        // caller that recurses would visit it twice.
        ownParts.compactMap { part -> EmbeddedMessage? in
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
            return EmbeddedMessage(part: part, message: Message(header: header, parts: nested))
        }
    }
}
