import NIOIMAPCore

/// Collects selection metadata without owning command or connection state.
struct MailboxSelectionAccumulator: Sendable {
    var selection = Mailbox.Selection()

    mutating func apply(_ code: ResponseTextCode) {
        switch code {
            case .unseen(let firstUnseen):
                selection.firstUnseen = Int(firstUnseen)
            case .uidValidity(let validity):
                selection.uidValidity = UIDValidity(nio: validity)
            case .uidNext(let next):
                selection.uidNext = UID(UInt32(next))
            case .permanentFlags(let flags):
                selection.permanentFlags = flags.map(Self.convertFlag)
            case .readOnly:
                selection.isReadOnly = true
            case .readWrite:
                selection.isReadOnly = false
            case .highestModificationSequence(let value):
                selection.highestModSequence = value
            case .noModificationSequence:
                selection.highestModSequence = nil
            case .closed:
                selection = Mailbox.Selection()
            default:
                break
        }
    }

    mutating func apply(_ mailboxData: MailboxData) {
        switch mailboxData {
            case .exists(let count):
                selection.messageCount = Int(count)
            case .recent(let count):
                selection.recentCount = Int(count)
            case .flags(let flags):
                selection.availableFlags = flags.map(Flag.init(nio:))
            default:
                break
        }
    }

    mutating func applyLiveDeletions(_ uids: NIOIMAPCore.UIDSet) {
        let deletedCount = uids.ranges.reduce(into: 0) { count, range in
            count += range.count
        }
        selection.messageCount -= min(selection.messageCount, deletedCount)
    }

    private static func convertFlag(_ flag: PermanentFlag) -> Flag {
        switch flag {
            case .flag(let coreFlag):
                return Flag(nio: coreFlag)
            case .wildcard:
                return .custom("wildcard")
        }
    }
}
