import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

struct PipelinedFetchRoutingError: Error, CustomStringConvertible, Sendable {
    let description: String
}

/// A registered command awaiting its untagged data and tagged completion.
struct PipelinedPendingCommand {
    let tag: String
    let handler: any PipelinedHandler
    let uid: UID?
    let expectedSection: SectionSpecifier?
    var finishedUntagged: Bool
}

/// The untagged FETCH group currently arriving (one `.start` … `.finish` span).
enum PipelinedUntaggedGroup {
    case idle
    /// Held until streamed body data proves the group belongs to a command.
    case pending(held: [FetchResponse], uid: UID?)
    /// A group may deliver several requested sections before it finishes.
    case bound(currentTag: String, touchedTags: Set<String>, uid: UID?)
    /// Unrequested body data is swallowed through `.finish`.
    case dropping
}

enum PipelinedBindingDecision {
    case match(Int)
    case unsolicited
    case routingViolation(PipelinedFetchRoutingError)
}
