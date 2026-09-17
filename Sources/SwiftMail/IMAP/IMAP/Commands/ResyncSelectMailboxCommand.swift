import NIO
import NIOIMAP
import NIOIMAPCore

/// Selects a mailbox with the RFC 7162 QRESYNC checkpoint parameters.
struct ResyncSelectMailboxCommand: IMAPTaggedCommand {
    typealias ResultType = Mailbox.ResyncSelection
    typealias HandlerType = ResyncSelectHandler

    let mailboxName: String
    let uidValidity: SwiftMail.UIDValidity
    let modificationSequence: ModificationSequenceValue
    let timeoutSeconds: Int = 30

    func validate() throws {
        guard !mailboxName.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name cannot be empty")
        }
        guard uidValidity.value > 0 else {
            throw IMAPError.invalidArgument("UIDVALIDITY must be nonzero")
        }

        let rawModificationSequence = UInt64(modificationSequence)
        guard rawModificationSequence > 0,
              ModificationSequenceValue(exactly: rawModificationSequence) != nil else {
            throw IMAPError.invalidArgument("Modification sequence must be in 1...Int64.max")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let parameter = QResyncParameter(
            uidValidity: uidValidity.toNIO(),
            modificationSequenceValue: modificationSequence,
            knownUIDs: nil,
            sequenceMatchData: nil
        )
        return TaggedCommand(
            tag: tag,
            command: .select(MailboxName(ByteBuffer(string: mailboxName)), [.qresync(parameter)])
        )
    }
}
