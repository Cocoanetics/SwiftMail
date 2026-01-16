import Foundation
import NIOIMAP
import NIOIMAPCore
import NIO

/// Command that fetches quota information for a quota root.
struct GetQuotaCommand: IMAPTaggedCommand {
    typealias ResultType = Quota
    typealias HandlerType = QuotaHandler

    /// The quota root to query, e.g. "" or "INBOX".
    let quotaRoot: String

    init(quotaRoot: String) {
        self.quotaRoot = quotaRoot
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let root = QuotaRoot(quotaRoot)
        return TaggedCommand(tag: tag, command: .getQuota(root))
    }
}

/// Command that fetches quota information using GETQUOTAROOT.
/// Some servers (e.g. iCloud) don't support GETQUOTA directly but respond to
/// GETQUOTAROOT followed by a QUOTA response.
struct GetQuotaRootCommand: IMAPTaggedCommand {
    typealias ResultType = Quota
    typealias HandlerType = QuotaHandler

    /// The mailbox name to query. If nil, INBOX is used.
    let mailboxName: String?

    init(mailboxName: String? = nil) {
        self.mailboxName = mailboxName
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        let mailbox: MailboxName
        if let name = mailboxName {
            mailbox = MailboxName(ByteBuffer(string: name))
        } else {
            mailbox = .inbox
        }
        return TaggedCommand(tag: tag, command: .getQuotaRoot(mailbox))
    }
}
