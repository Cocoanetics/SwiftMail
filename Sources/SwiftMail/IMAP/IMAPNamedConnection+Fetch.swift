import Foundation

public extension IMAPNamedConnection {
    /// Fetch message structure for a single message identifier.
    func fetchStructure(_ identifier: some MessageIdentifier) async throws -> [MessagePart] {
        let command = FetchStructureCommand(identifier: identifier)
        return try await executeCommand(command)
    }

    /// Fetch a specific body section for a message.
    func fetchPart(section: Section, of identifier: some MessageIdentifier) async throws -> Data {
        let command = FetchMessagePartCommand(identifier: identifier, section: section)
        return try await executeCommand(command)
    }

    /// Fetch multiple body parts in a pipelined burst (RFC 3501 §5.5).
    /// Sends all FETCH commands without awaiting individual responses.
    /// Significantly faster than sequential fetchPart calls (~3-5x for body fetching).
    /// - Parameter parts: Array of (uid, section) pairs to fetch.
    /// - Returns: Dictionary mapping UID to array of (section, data) results.
    func fetchPartsPipelined(
        parts: [(uid: UID, section: Section)]
    ) async throws -> [UID: [(section: Section, data: Data)]] {
        try await ensureAuthenticated()
        let results = try await connection.executePipelinedFetchParts(requests: parts)
        recordActivity()
        var grouped: [UID: [(section: Section, data: Data)]] = [:]
        for result in results {
            grouped[result.uid, default: []].append((section: result.section, data: result.data))
        }
        return grouped
    }

    /// Fetch a full raw RFC822 message.
    func fetchRawMessage(identifier: some MessageIdentifier) async throws -> Data {
        let command = FetchRawMessageCommand(identifier: identifier)
        return try await executeCommand(command)
    }

    /// Fetch message metadata for one identifier.
    func fetchMessageInfo<T: MessageIdentifier>(for identifier: T) async throws -> MessageInfo? {
        let set = MessageIdentifierSet<T>(identifier)
        let command = FetchMessageInfoCommand(identifierSet: set)
        return try await executeCommand(command).first
    }

    /// Fetch message metadata in a single FETCH/UID FETCH command.
    func fetchMessageInfosBulk(
        using identifierSet: MessageIdentifierSet<some MessageIdentifier>
    ) async throws -> [MessageInfo] {
        let command = FetchMessageInfoCommand(identifierSet: identifierSet)
        return try await executeCommand(command)
    }

    /// Fetch message metadata for a UID range in a single command.
    func fetchMessageInfos(uidRange: PartialRangeFrom<UID>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange))
    }

    /// Fetch message metadata for a UID range in a single command.
    func fetchMessageInfos(uidRange: ClosedRange<UID>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange))
    }

    /// Fetch message metadata for a sequence-number range in a single command.
    func fetchMessageInfos(sequenceRange: PartialRangeFrom<SequenceNumber>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: SequenceNumberSet(sequenceRange))
    }

    /// Fetch message metadata for a sequence-number range in a single command.
    func fetchMessageInfos(sequenceRange: ClosedRange<SequenceNumber>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: SequenceNumberSet(sequenceRange))
    }
}
