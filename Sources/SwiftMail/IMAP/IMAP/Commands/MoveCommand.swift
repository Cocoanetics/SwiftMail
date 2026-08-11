// MoveCommand.swift
// Commands related to moving messages in IMAP

import Foundation
import NIO
import NIOIMAP

/// Command for moving messages from one mailbox to another
struct MoveCommand<T: MessageIdentifier>: IMAPTaggedCommand {
    typealias ResultType = CopyUID?
    typealias HandlerType = MoveHandler

    /// The set of message identifiers to move
    let identifierSet: MessageIdentifierSet<T>

    /// The destination mailbox name
    let destinationMailbox: String

    /// Validate the command before execution
    func validate() throws {
        guard !identifierSet.isEmpty else {
            throw IMAPError.emptyIdentifierSet
        }
    }

    /// RFC 4315 forbids COPYUID from naming source UIDs outside the UID command's set.
    func validate(copyUID: CopyUID?) throws -> CopyUID? {
        guard let copyUID,
              let reason = copyUID.sourceValidationFailure(for: identifierSet)
        else {
            return copyUID
        }
        throw IMAPError.malformedCopyUIDAfterTaggedOK(reason)
    }

    /// Never expose untrusted partial-failure evidence as a verified mapping.
    func validate(error: IMAPError) -> IMAPError {
        guard case .moveFailedAfterPartialCompletion(let copyUID, let reason) = error,
              let validationFailure = copyUID.sourceValidationFailure(for: identifierSet)
        else {
            return error
        }
        return .moveFailedAfterPossiblePartialCompletion(
            "MOVE returned unverified COPYUID evidence (\(validationFailure)): \(reason)"
        )
    }

    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        let mailbox = MailboxName(ByteBuffer(string: destinationMailbox))

        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidMove(.set(identifierSet.toNIOSet()), mailbox))
        } else {
            return TaggedCommand(tag: tag, command: .move(.set(identifierSet.toNIOSet()), mailbox))
        }
    }
}
