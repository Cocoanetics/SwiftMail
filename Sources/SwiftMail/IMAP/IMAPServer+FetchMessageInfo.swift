import Foundation

// MARK: - Message Metadata Fetch Commands

extension IMAPServer {
    /// Fetch message info for a single identifier.
    /// - Parameters:
    ///   - identifier: The message identifier to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields to request via `BODY.PEEK[HEADER.FIELDS (...)]`.
    /// - Returns: The message info if available
    public func fetchMessageInfo<T: MessageIdentifier>(
        for identifier: T,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> MessageInfo? {
        try await fetchMessageInfo(
            for: identifier, options: options, headerFields: headerFields, limits: .unlimited
        )
    }

    /// Fetch message info for a single identifier.
    /// - Parameters:
    ///   - identifier: The message identifier to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields to request via `BODY.PEEK[HEADER.FIELDS (...)]`.
    ///   - limits: Receive limits for this call.
    /// - Returns: The message info if available
    ///
    /// `limits` bound the replies and streamed-section bytes this call may receive; see
    /// ``FetchReceiveLimits``. Past a limit the call throws ``FetchReceiveLimitExceededError``,
    /// returns nothing it received, and closes the connection it used.
    public func fetchMessageInfo<T: MessageIdentifier>(
        for identifier: T,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        limits: FetchReceiveLimits
    ) async throws -> MessageInfo? {
        let command = FetchMessageInfoCommand(
            identifierSet: MessageIdentifierSet<T>(identifier), options: options, headerFields: headerFields,
            budget: try FetchReceiveBudget.make(for: limits)
        )
        return try await executeCommand(command).first
    }

    /// Fetch message infos for an identifier set in a **single IMAP FETCH**.
    /// This is important for UID ranges like `123:*` which must not be expanded into individual UIDs.
    /// - Parameters:
    ///   - identifierSet: The identifiers to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields. See `FetchMessageInfoOptions.newsletterHeaderFields`.
    public func fetchMessageInfosBulk<T: MessageIdentifier>(
        using identifierSet: MessageIdentifierSet<T>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: identifierSet, options: options, headerFields: headerFields, limits: .unlimited
        )
    }

    /// Fetch message infos for an identifier set in a **single IMAP FETCH**.
    /// This is important for UID ranges like `123:*` which must not be expanded into individual UIDs.
    /// - Parameters:
    ///   - identifierSet: The identifiers to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields. See `FetchMessageInfoOptions.newsletterHeaderFields`.
    ///   - limits: Receive limits for this call.
    ///
    /// `limits` bound the replies and streamed-section bytes this call may receive; see
    /// ``FetchReceiveLimits``. Past a limit the call throws ``FetchReceiveLimitExceededError``,
    /// returns nothing it received, and closes the connection it used.
    public func fetchMessageInfosBulk<T: MessageIdentifier>(
        using identifierSet: MessageIdentifierSet<T>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        limits: FetchReceiveLimits
    ) async throws -> [MessageInfo] {
        let command = FetchMessageInfoCommand(
            identifierSet: identifierSet, options: options, headerFields: headerFields,
            budget: try FetchReceiveBudget.make(for: limits)
        )
        return try await executeCommand(command)
    }

    // MARK: - Convenience overloads for ranges

    /// Fetch message infos for a UID range in a **single UID FETCH** (e.g. `11971:*`).
    public func fetchMessageInfos(
        uidRange: PartialRangeFrom<UID>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfos(
            uidRange: uidRange, options: options, headerFields: headerFields, limits: .unlimited
        )
    }

    /// Fetch message infos for a UID range in a **single UID FETCH** (e.g. `11971:*`).
    ///
    /// `limits` bound the replies and streamed-section bytes this call may receive; see
    /// ``FetchReceiveLimits``. Past a limit the call throws ``FetchReceiveLimitExceededError``,
    /// returns nothing it received, and closes the connection it used.
    public func fetchMessageInfos(
        uidRange: PartialRangeFrom<UID>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        limits: FetchReceiveLimits
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: UIDSet(uidRange), options: options, headerFields: headerFields, limits: limits
        )
    }

    /// Fetch message infos for a UID range in a **single UID FETCH**.
    public func fetchMessageInfos(
        uidRange: ClosedRange<UID>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfos(
            uidRange: uidRange, options: options, headerFields: headerFields, limits: .unlimited
        )
    }

    /// Fetch message infos for a UID range in a **single UID FETCH**.
    ///
    /// `limits` bound the replies and streamed-section bytes this call may receive; see
    /// ``FetchReceiveLimits``. Past a limit the call throws ``FetchReceiveLimitExceededError``,
    /// returns nothing it received, and closes the connection it used.
    public func fetchMessageInfos(
        uidRange: ClosedRange<UID>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        limits: FetchReceiveLimits
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: UIDSet(uidRange), options: options, headerFields: headerFields, limits: limits
        )
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    public func fetchMessageInfos(
        sequenceRange: PartialRangeFrom<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfos(
            sequenceRange: sequenceRange, options: options, headerFields: headerFields, limits: .unlimited
        )
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    ///
    /// `limits` bound the replies and streamed-section bytes this call may receive; see
    /// ``FetchReceiveLimits``. Past a limit the call throws ``FetchReceiveLimitExceededError``,
    /// returns nothing it received, and closes the connection it used.
    public func fetchMessageInfos(
        sequenceRange: PartialRangeFrom<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        limits: FetchReceiveLimits
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: SequenceNumberSet(sequenceRange), options: options, headerFields: headerFields, limits: limits
        )
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    public func fetchMessageInfos(
        sequenceRange: ClosedRange<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfos(
            sequenceRange: sequenceRange, options: options, headerFields: headerFields, limits: .unlimited
        )
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    ///
    /// `limits` bound the replies and streamed-section bytes this call may receive; see
    /// ``FetchReceiveLimits``. Past a limit the call throws ``FetchReceiveLimitExceededError``,
    /// returns nothing it received, and closes the connection it used.
    public func fetchMessageInfos(
        sequenceRange: ClosedRange<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        limits: FetchReceiveLimits
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: SequenceNumberSet(sequenceRange), options: options, headerFields: headerFields, limits: limits
        )
    }

    /// Stream message metadata for a set of identifiers.
    ///
    /// Large identifier sets are automatically split into chunks so that no single IMAP
    /// FETCH command is too large. Chunk size defaults to a value derived from `options`
    /// (smaller per-message payload → larger chunks); pass `chunkSize` to override.
    /// Results are yielded one at a time as they arrive.
    ///
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to fetch.
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
        fetchMessageInfos(
            using: identifierSet, options: options, headerFields: headerFields, chunkSize: chunkSize,
            limits: .unlimited
        )
    }

    /// Stream message metadata for a set of identifiers.
    ///
    /// Large identifier sets are automatically split into chunks so that no single IMAP
    /// FETCH command is too large. Chunk size defaults to a value derived from `options`
    /// (smaller per-message payload → larger chunks); pass `chunkSize` to override.
    /// Results are yielded one at a time as they arrive.
    ///
    /// - Parameters:
    ///   - identifierSet: The set of message identifiers to fetch.
    ///   - options: Which attributes to request. Defaults to `.default`.
    ///   - headerFields: Optional named header fields.
    ///   - chunkSize: Override for the auto-derived chunk size.
    ///   - limits: Receive limits for this call.
    /// - Returns: An `AsyncThrowingStream` yielding `MessageInfo` one at a time.
    ///
    /// `limits` bound the replies and streamed-section bytes the whole stream may receive,
    /// across all of its chunks; see ``FetchReceiveLimits``. Past a limit the stream finishes
    /// with ``FetchReceiveLimitExceededError`` after the messages of earlier chunks, sends no
    /// further chunk, and closes the connection it used.
    public nonisolated func fetchMessageInfos<T: MessageIdentifier>(
        using identifierSet: MessageIdentifierSet<T>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil,
        chunkSize: Int? = nil,
        limits: FetchReceiveLimits
    ) -> AsyncThrowingStream<MessageInfo, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !identifierSet.isEmpty else {
                        throw IMAPError.emptyIdentifierSet
                    }

                    let budget = try FetchReceiveBudget.make(for: limits)
                    let chunks = identifierSet.chunked(size: chunkSize ?? options.suggestedChunkSize)

                    for chunk in chunks {
                        try Task.checkCancellation()
                        let command = FetchMessageInfoCommand(
                            identifierSet: chunk, options: options, headerFields: headerFields, budget: budget
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
