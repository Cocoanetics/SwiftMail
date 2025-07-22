import Foundation
import NIOIMAP
import NIOIMAPCore

/// Command that fetches quota information for a quota root.
struct GetQuotaCommand: IMAPCommand {
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
