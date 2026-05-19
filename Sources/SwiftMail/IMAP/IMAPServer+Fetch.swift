import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Message Fetch Commands

extension IMAPServer {
    /**
     Fetches the structure of a message.

     The message structure includes information about MIME parts, attachments,
     and the overall organization of the message content.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
     - identifier: The identifier of the message to fetch
     - Returns: The message's body parts
     - Throws: `IMAPError.fetchFailed` if the fetch operation fails
     - Note: Logs structure fetch at debug level
     */
    public func fetchStructure<T: MessageIdentifier>(_ identifier: T) async throws -> [MessagePart] {
        let command = FetchStructureCommand(identifier: identifier)
        return try await executeCommand(command)
    }

    /**
     Fetches a specific part of a message.

     Use this method to retrieve specific MIME parts of a message, such as
     the text body, HTML content, or attachments.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
     - section: The part number to fetch (e.g., "1", "1.1", "2")
     - identifier: The identifier of the message
     - Returns: The content of the requested message part
     - Throws: `IMAPError.fetchFailed` if the fetch operation fails
     - Note: Logs part fetch at debug level with part number
     */
    public func fetchPart<T: MessageIdentifier>(section: Section, of identifier: T) async throws -> Data {
        let command = FetchMessagePartCommand(identifier: identifier, section: section)
        return try await executeCommand(command)
    }

    /**
     Fetch multiple body parts in a pipelined burst (RFC 3501 §5.5).

     Sends all FETCH BODY[section] commands without awaiting individual responses.
     The server processes them in order; responses are matched by tag.
     Significantly faster than sequential `fetchPart` calls (~3-5x for body fetching).

     - Parameter parts: Array of (uid, section) pairs to fetch.
     - Returns: Dictionary mapping UID to array of (section, data) results.
     - Throws: If the connection is unavailable.
     */
    public func fetchPartsPipelined(
        parts: [(uid: UID, section: Section)]
    ) async throws -> [UID: [(section: Section, data: Data)]] {
        if let authentication, !primaryConnection.isAuthenticated {
            logger.info("Primary connection not authenticated; re-authenticating before pipelined fetch")
            try await authentication.authenticate(on: primaryConnection)
        }
        let results = try await primaryConnection.executePipelinedFetchParts(requests: parts)
        var grouped: [UID: [(section: Section, data: Data)]] = [:]
        for result in results {
            grouped[result.uid, default: []].append((section: result.section, data: result.data))
        }
        return grouped
    }

    /**
     Fetches the complete raw RFC822 message (headers + body) without setting the \Seen flag.

     - Parameter identifier: The identifier of the message
     - Returns: The complete raw message data
     - Throws: `IMAPError.fetchFailed` if the fetch operation fails
     */
    public func fetchRawMessage<T: MessageIdentifier>(identifier: T) async throws -> Data {
        let command = FetchRawMessageCommand(identifier: identifier)
        return try await executeCommand(command)
    }

    /**
     Fetch all message parts and their data for a message
     - Parameter identifier: The message identifier (UID or sequence number)
     - Returns: An array of message parts with their data populated
     - Throws: IMAPError if any fetch operation fails
     */
    public func fetchAllMessageParts<T: MessageIdentifier>(identifier: T) async throws -> [MessagePart] {

        var parts = try await fetchStructure(identifier)

        for (index, part) in parts.enumerated() {
            parts[index].data = try await self.fetchPart(section: part.section, of: identifier)
        }

        return parts
    }

    /**
     Fetches and decodes the data for a specific message part.

     This method will:
     1. Use the message's UID if available, falling back to sequence number if not
     2. Fetch the raw data for the specified part
     3. Automatically decode the data based on the part's content encoding

     - Parameters:
     - header: The message header containing the part
     - part: The message part to fetch, containing section and encoding information
     - Returns: The decoded data for the message part
     - Throws:
     - `IMAPError.fetchFailed` if the fetch operation fails
     - Decoding errors if the part's encoding cannot be processed
     */
    public func fetchAndDecodeMessagePartData(messageInfo: MessageInfo, part: MessagePart) async throws -> Data {
        // Use the UID from the header if available (non-zero), otherwise fall back to sequence number
        if let uid = messageInfo.uid {
            // Use UID for fetching
            return try await fetchPart(section: part.section, of: uid).decoded(for: part)
        } else {
            // Fall back to sequence number
            let sequenceNumber = messageInfo.sequenceNumber
            return try await fetchPart(section: part.section, of: sequenceNumber).decoded(for: part)
        }
    }

    /**
     Fetch a complete email with all parts from an email header

     - Parameter header: The email header to fetch the complete email for
     - Returns: A complete Email object with all parts
     - Throws: An error if the fetch operation fails
     - Note: This method will use UID if available in the header, falling back to sequence number if not
     */
    public func fetchMessage(from header: MessageInfo) async throws -> Message {
        // Use the UID from the header if available (non-zero), otherwise fall back to sequence number
        if let uid = header.uid {
            // Use UID for fetching
            let parts = try await fetchAllMessageParts(identifier: uid)
            return Message(header: header, parts: parts)
        } else {
            // Fall back to sequence number
            let sequenceNumber = header.sequenceNumber
            let parts = try await fetchAllMessageParts(identifier: sequenceNumber)
            return Message(header: header, parts: parts)
        }
    }

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
        let singleSet = MessageIdentifierSet<T>(identifier)
        let command = FetchMessageInfoCommand(
            identifierSet: singleSet, options: options, headerFields: headerFields
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
        let command = FetchMessageInfoCommand(
            identifierSet: identifierSet, options: options, headerFields: headerFields
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
        try await fetchMessageInfosBulk(using: UIDSet(uidRange), options: options, headerFields: headerFields)
    }

    /// Fetch message infos for a UID range in a **single UID FETCH**.
    public func fetchMessageInfos(
        uidRange: ClosedRange<UID>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange), options: options, headerFields: headerFields)
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    public func fetchMessageInfos(
        sequenceRange: PartialRangeFrom<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: SequenceNumberSet(sequenceRange), options: options, headerFields: headerFields
        )
    }

    /// Fetch message infos for a sequence number range in a single FETCH.
    public func fetchMessageInfos(
        sequenceRange: ClosedRange<SequenceNumber>,
        options: FetchMessageInfoOptions = .default,
        headerFields: [String]? = nil
    ) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(
            using: SequenceNumberSet(sequenceRange), options: options, headerFields: headerFields
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

    /// Fetch complete messages with all parts using a message identifier set as a stream
    ///
    /// This method returns an `AsyncThrowingStream` that yields complete `Message` objects one at a time.
    /// Large identifier sets are automatically split into chunks of `defaultFetchChunkSize`
    /// for the header fetch phase. Message bodies are then fetched individually.
    /// The sequence supports cancellation, allowing the caller to stop fetching early
    /// without waiting for all messages to be downloaded.
    ///
    /// - Parameter identifierSet: The set of message identifiers to fetch
    /// - Returns: An `AsyncThrowingStream` yielding `Message` instances with all parts
    public nonisolated func fetchMessages<T: MessageIdentifier>(
        using identifierSet: MessageIdentifierSet<T>
    ) -> AsyncThrowingStream<Message, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !identifierSet.isEmpty else {
                        throw IMAPError.emptyIdentifierSet
                    }

                    let chunks = identifierSet.chunked(size: defaultFetchChunkSize)

                    for chunk in chunks {
                        try Task.checkCancellation()
                        let command = FetchMessageInfoCommand(identifierSet: chunk)
                        let headers = try await executeCommand(command)

                        for header in headers {
                            try Task.checkCancellation()
                            let email = try await fetchMessage(from: header)
                            continuation.yield(email)
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
