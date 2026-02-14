import Foundation

/// Metadata returned by the server after a successful APPEND command.
public struct AppendResult: Codable, Sendable {
    /// The UIDVALIDITY reported by the server, if available.
    public let uidValidity: UIDValidity?

    /// The server-assigned UIDs for the appended messages (empty when the server does not support UIDPLUS).
    public let uids: [UID]

    /// Convenience accessor for the first UID when a single message was appended.
    public var firstUID: UID? {
        uids.first
    }

    /// Initialize a new append result.
    /// - Parameters:
    ///   - uidValidity: UIDVALIDITY reported by the server, if any.
    ///   - uids: The list of assigned UIDs (may be empty).
    public init(uidValidity: UIDValidity?, uids: [UID]) {
        self.uidValidity = uidValidity
        self.uids = uids
    }
}
