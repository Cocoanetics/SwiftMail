// FetchSlimMessageInfoCommand.swift
// Like FetchMessageInfoCommand but skips BODYSTRUCTURE and the full header section. Requests
// only UID, ENVELOPE, INTERNALDATE, FLAGS, RFC822.SIZE, plus a small set of named header fields
// useful for newsletter / auto-mail detection. Per-message responses are roughly an order of
// magnitude smaller than the standard fetch — important for large mailboxes where the full
// command's response would exceed the 10-second per-command timeout.

import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Header fields fetched alongside ENVELOPE so callers can detect newsletters / auto-mail without
/// pulling the full header section. Tiny per-message cost (~200 bytes), big triage payoff.
private let slimHeaderFields = [
    "List-Unsubscribe",
    "List-Unsubscribe-Post",
    "List-ID",
    "Auto-Submitted",
    "Precedence"
]

/// Command for fetching minimal message metadata: UID, ENVELOPE, INTERNALDATE, FLAGS, RFC822.SIZE,
/// plus a small set of triage-relevant header fields. No BODYSTRUCTURE, no body content.
struct FetchSlimMessageInfoCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = [MessageInfo]
    typealias HandlerType = FetchMessageInfoHandler

    let identifierSet: MessageIdentifierSet<T>

    let timeoutSeconds = 10

    init(identifierSet: MessageIdentifierSet<T>) {
        self.identifierSet = identifierSet
    }

    func validate() throws {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let headerFieldsSection = NIOIMAPCore.SectionSpecifier(
            part: .init([]),
            kind: .headerFields(slimHeaderFields)
        )
        let attributes: [FetchAttribute] = [
            .uid,
            .envelope,
            .internalDate,
            .flags,
            .rfc822Size,
            .bodySection(peek: true, headerFieldsSection, nil)
        ]

        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidFetch(
                .set(identifierSet.toNIOSet()), attributes, []
            ))
        } else {
            return TaggedCommand(tag: tag, command: .fetch(
                .set(identifierSet.toNIOSet()), attributes, []
            ))
        }
    }
}
