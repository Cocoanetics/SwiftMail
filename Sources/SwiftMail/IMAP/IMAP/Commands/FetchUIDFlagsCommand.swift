// FetchUIDFlagsCommand.swift
// Fetches only (UID FLAGS) per message — the smallest possible payload. Useful for incremental
// sync diffing where the caller only needs the current set of UIDs and their flag state. Tens of
// thousands of messages return in a few hundred KB total.

import Foundation
import NIO
import NIOIMAP

struct FetchUIDFlagsCommand<T: MessageIdentifier>: IMAPTaggedCommand {
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
        let attributes: [FetchAttribute] = [.uid, .flags]
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
