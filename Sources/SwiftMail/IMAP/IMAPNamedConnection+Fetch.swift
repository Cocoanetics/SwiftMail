import Foundation

extension IMAPNamedConnection {
    /// Fetch message structure for a single message identifier.
    public func fetchStructure<T: MessageIdentifier>(_ identifier: T) async throws -> [MessagePart] {
        let command = FetchStructureCommand(identifier: identifier)
        return try await executeCommand(command)
    }

    /// Fetch a specific body section for a message.
    public func fetchPart<T: MessageIdentifier>(section: Section, of identifier: T) async throws -> Data {
        let command = FetchMessagePartCommand(identifier: identifier, section: section)
        return try await executeCommand(command)
    }

    /// Fetch multiple body parts in a pipelined burst (RFC 3501 §5.5).
    /// Sends all FETCH commands without awaiting individual responses.
    /// Significantly faster than sequential fetchPart calls (~3-5x for body fetching).
    /// - Parameter parts: Array of (uid, section) pairs to fetch.
    /// - Returns: Dictionary mapping UID to array of (section, data) results.
    public func fetchPartsPipelined(
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
    public func fetchRawMessage<T: MessageIdentifier>(identifier: T) async throws -> Data {
        let command = FetchRawMessageCommand(identifier: identifier)
        return try await executeCommand(command)
    }

    /// Fetch message metadata for one identifier.
    /// - Parameters:
    ///   - identifier: The message identifier to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields to request via `BODY.PEEK[HEADER.FIELDS (...)]`.
    public func fetchMessageInfo<T: MessageIdentifier>(
        for identifier: T,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> MessageInfo? {
        let set = MessageIdentifierSet<T>(identifier)
        let command = FetchMessageInfoCommand(
            identifierSet: set, options: options, headerFields: headerFields
        )
        return try await executeCommand(command).first
    }

    /// Fetch message metadata in a single FETCH/UID FETCH command.
    /// - Parameters:
    ///   - identifierSet: The identifiers to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields. See `FetchMessageInfoOptions.newsletterHeaderFields`.
    public func fetchMessageInfosBulk<T: MessageIdentifier>(
        using identifierSet: MessageIdentifierSet<T>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        let command = FetchMessageInfoCommand(
            identifierSet: identifierSet, options: options, headerFields: headerFields
        )
        return try await executeCommand(command)
    }

    /// Fetch message metadata for a UID range in a single command.
    public func fetchMessageInfos(
        uidRange: PartialRangeFrom<UID>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange), options: options, headerFields: headerFields)
    }

    /// Fetch message metadata for a UID range in a single command.
    public func fetchMessageInfos(
        uidRange: ClosedRange<UID>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange), options: options, headerFields: headerFields)
    }

    /// Fetch message metadata for a sequence-number range in a single command.
    public func fetchMessageInfos(
        sequenceRange: PartialRangeFrom<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: SequenceNumberSet(sequenceRange), options: options, headerFields: headerFields
        )
    }

    /// Fetch message metadata for a sequence-number range in a single command.
    public func fetchMessageInfos(
        sequenceRange: ClosedRange<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: SequenceNumberSet(sequenceRange), options: options, headerFields: headerFields
        )
    }

    /// Stream message metadata for a set of identifiers, auto-chunking large sets.
    ///
    /// Chunk size defaults to `options.suggestedChunkSize` — lighter per-message payloads
    /// (e.g. `.uidFlagsOnly`, `.slim`) take larger chunks so the same total fetch needs
    /// fewer round trips. Pass `chunkSize` to override.
    ///
    /// - Parameters:
    ///   - identifierSet: The identifiers to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields.
    ///   - chunkSize: Override for the auto-derived chunk size.
    /// - Returns: An `AsyncThrowingStream` yielding `MessageInfo` one at a time.
    public nonisolated func fetchMessageInfos<T: MessageIdentifier>(
        using identifierSet: MessageIdentifierSet<T>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        chunkSize: Int? = nil
    ) -> AsyncThrowingStream<MessageInfo, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !identifierSet.isEmpty else {
                        throw IMAPError.emptyIdentifierSet
                    }

                    let chunks = identifierSet.chunked(size: chunkSize ?? options.suggestedChunkSize)

                    for chunk in chunks {
                        try Task.checkCancellation()
                        let command = FetchMessageInfoCommand(
                            identifierSet: chunk, options: options, headerFields: headerFields
                        )
                        let result = try await executeCommand(command)
                        for header in result {
                            continuation.yield(header)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
