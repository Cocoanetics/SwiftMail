import Foundation
@preconcurrency import NIOIMAPCore

/// A user-controlled, reusable IMAP connection managed by ``IMAPServer``.
///
/// Instances are obtained via ``IMAPServer/connection(named:)``.
/// The server handles lifecycle bootstrap/authentication and teardown; callers decide
/// which mailbox and commands run on each named connection.
public actor IMAPNamedConnection {
    public let name: String

    private let connection: IMAPConnection
    private let authenticateOnConnection: @Sendable (IMAPConnection) async throws -> Void

    /// The timestamp of the last successfully completed command on this connection.
    /// Useful for implementing staleness checks in ephemeral connection patterns.
    public private(set) var lastActivity: Date?

    init(
        name: String,
        connection: IMAPConnection,
        authenticateOnConnection: @escaping @Sendable (IMAPConnection) async throws -> Void
    ) {
        self.name = name
        self.connection = connection
        self.authenticateOnConnection = authenticateOnConnection
    }

    /// Whether the underlying transport channel is currently active.
    public var isConnected: Bool {
        connection.isConnected
    }

    /// Whether this connection currently has an authenticated IMAP session.
    public var isAuthenticated: Bool {
        connection.isAuthenticated
    }

    /// Connect (or reconnect) the underlying transport and ensure authentication.
    public func connect() async throws {
        try await connection.connect()
        try await ensureAuthenticated()
    }

    /// Disconnect this named connection.
    public func disconnect() async throws {
        try await connection.disconnect()
    }

    /// Fetch server capabilities.
    @discardableResult
    public func fetchCapabilities() async throws -> [Capability] {
        let result = try await connection.fetchCapabilities()
        lastActivity = Date()
        return result
    }

    /// Select a mailbox for subsequent commands.
    @discardableResult
    public func select(mailbox mailboxName: String) async throws -> Mailbox.Selection {
        // Authenticate first so namespacesSnapshot is populated (or repopulated
        // after a reconnect) before we resolve the mailbox path.
        try await ensureAuthenticated()
        let command = SelectMailboxCommand(mailboxName: resolveMailboxPath(mailboxName))
        return try await executeCommand(command)
    }

    /// Compatibility alias for selecting a mailbox.
    @discardableResult
    public func selectMailbox(_ mailboxName: String) async throws -> Mailbox.Selection {
        try await select(mailbox: mailboxName)
    }

    /// Close the currently selected mailbox (expunges `\Deleted` messages).
    public func closeMailbox() async throws {
        let command = CloseCommand()
        try await executeCommand(command)
    }

    /// Unselect the currently selected mailbox without expunging.
    public func unselectMailbox() async throws {
        if !capabilities.contains(.unselect) {
            throw IMAPError.commandNotSupported("UNSELECT command not supported by server")
        }

        let command = UnselectCommand()
        try await executeCommand(command)
    }

    /// Start IDLE and receive server events.
    public func idle() async throws -> AsyncStream<IMAPServerEvent> {
        try await ensureAuthenticated()
        let stream = try await connection.idle()
        lastActivity = Date()
        return stream
    }

    /// Terminate an active IDLE command with DONE.
    public func done() async throws {
        try await connection.done()
        lastActivity = Date()
    }

    /// Send NOOP and collect unsolicited events.
    public func noop() async throws -> [IMAPServerEvent] {
        try await ensureAuthenticated()
        let events = try await connection.noop()
        lastActivity = Date()
        return events
    }

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

    /// Fetch a full raw RFC822 message.
    public func fetchRawMessage<T: MessageIdentifier>(identifier: T) async throws -> Data {
        let command = FetchRawMessageCommand(identifier: identifier)
        return try await executeCommand(command)
    }

    /// Fetch message metadata for one identifier.
    public func fetchMessageInfo<T: MessageIdentifier>(for identifier: T) async throws -> MessageInfo? {
        let set = MessageIdentifierSet<T>(identifier)
        let command = FetchMessageInfoCommand(identifierSet: set)
        return try await executeCommand(command).first
    }

    /// Fetch message metadata in a single FETCH/UID FETCH command.
    public func fetchMessageInfosBulk<T: MessageIdentifier>(using identifierSet: MessageIdentifierSet<T>) async throws -> [MessageInfo] {
        let command = FetchMessageInfoCommand(identifierSet: identifierSet)
        return try await executeCommand(command)
    }

    /// Fetch message metadata for a UID range in a single command.
    public func fetchMessageInfos(uidRange: PartialRangeFrom<UID>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange))
    }

    /// Fetch message metadata for a UID range in a single command.
    public func fetchMessageInfos(uidRange: ClosedRange<UID>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: UIDSet(uidRange))
    }

    /// Fetch message metadata for a sequence-number range in a single command.
    public func fetchMessageInfos(sequenceRange: PartialRangeFrom<SequenceNumber>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: SequenceNumberSet(sequenceRange))
    }

    /// Fetch message metadata for a sequence-number range in a single command.
    public func fetchMessageInfos(sequenceRange: ClosedRange<SequenceNumber>) async throws -> [MessageInfo] {
        try await fetchMessageInfosBulk(using: SequenceNumberSet(sequenceRange))
    }

    /// Search within the selected mailbox.
    public func search<T: MessageIdentifier>(
        identifierSet: MessageIdentifierSet<T>? = nil,
        criteria: [SearchCriteria]
    ) async throws -> MessageIdentifierSet<T> {
        let command = SearchCommand(identifierSet: identifierSet, criteria: criteria)
        return try await executeCommand(command)
    }

    /// Search within the selected mailbox, returning structured ESEARCH results (RFC 4731).
    ///
    /// Uses ESEARCH when the server supports it; falls back to a plain SEARCH otherwise.
    /// Pass `partialRange` to request paged results (PARTIAL, RFC 5267) — when set and ESEARCH is
    /// available, `PARTIAL` is used instead of `ALL` and results appear in
    /// ``ExtendedSearchResult/partial``.
    public func extendedSearch<T: MessageIdentifier>(
        identifierSet: MessageIdentifierSet<T>? = nil,
        criteria: [SearchCriteria],
        calendar: Calendar = Calendar(identifier: .gregorian),
        partialRange: PartialRange? = nil
    ) async throws -> ExtendedSearchResult<T> {
        let useEsearch = capabilities.contains(.extendedSearch)
        let command = ExtendedSearchCommand<T>(identifierSet: identifierSet, criteria: criteria, calendar: calendar, useEsearch: useEsearch, partialRange: partialRange)
        return try await executeCommand(command)
    }

    /// Copy messages to another mailbox.
    public func copy<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
        let command = CopyCommand(identifierSet: identifierSet, destinationMailbox: resolveMailboxPath(destinationMailbox))
        try await executeCommand(command)
    }

    /// Update flags for messages.
    public func store<T: MessageIdentifier>(
        flags: [Flag],
        on identifierSet: MessageIdentifierSet<T>,
        operation: StoreData.StoreType
    ) async throws {
        let data = StoreData.flags(flags, operation)
        let command = StoreCommand(identifierSet: identifierSet, data: data)
        try await executeCommand(command)
    }

    /// Expunge messages marked with `\Deleted`.
    public func expunge() async throws {
        let command = ExpungeCommand()
        try await executeCommand(command)
    }

    /// Expunge specific messages marked with `\Deleted` using UIDPLUS.
    public func expunge(messages identifierSet: UIDSet) async throws {
        guard supportsUIDPlus else {
            throw IMAPError.commandNotSupported("UID EXPUNGE command not supported by server")
        }

        let command = UIDExpungeCommand(identifierSet: identifierSet)
        try await executeCommand(command)
    }

    /// Move messages to another mailbox (uses MOVE if supported, otherwise COPY+STORE+EXPUNGE).
    public func move<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
        if capabilities.contains(.move) && (T.self != UID.self || capabilities.contains(.uidPlus)) {
            try await executeMove(messages: identifierSet, to: destinationMailbox)
        } else {
            try await copy(messages: identifierSet, to: destinationMailbox)
            try await store(flags: [.deleted], on: identifierSet, operation: .add)
            try await expungeMoveFallback(messages: identifierSet)
        }
    }

    /// Move a single message to another mailbox.
    public func move<T: MessageIdentifier>(message identifier: T, to destinationMailbox: String) async throws {
        let set = MessageIdentifierSet<T>(identifier)
        try await move(messages: set, to: destinationMailbox)
    }

    /// Retrieve mailbox status without selecting the mailbox.
    public func mailboxStatus(_ mailboxName: String) async throws -> Mailbox.Status {
        var attributes: [NIOIMAPCore.MailboxAttribute] = [
            .messageCount,
            .recentCount,
            .unseenCount
        ]

        if capabilities.contains(.uidPlus) {
            attributes.append(.uidNext)
            attributes.append(.uidValidity)
        }
        if capabilities.contains(.condStore) {
            attributes.append(.highestModificationSequence)
        }
        if capabilities.contains(.objectID) {
            attributes.append(.mailboxID)
        }
        if capabilities.contains(.status(.size)) {
            attributes.append(.size)
        }
        if capabilities.contains(.mailboxSpecificAppendLimit) {
            attributes.append(.appendLimit)
        }

        let command = StatusCommand(mailboxName: resolveMailboxPath(mailboxName), attributes: attributes)
        let status: NIOIMAPCore.MailboxStatus = try await executeCommand(command)
        return Mailbox.Status(nio: status)
    }

    /// List mailboxes.
    public func listMailboxes(wildcard: String = "*") async throws -> [Mailbox.Info] {
        if let namespaces = connection.namespacesSnapshot {
            let patterns = namespaces.listingPatterns(for: wildcard)
            var allMailboxes: [Mailbox.Info] = []
            var seenNames: Set<String> = []

            for pattern in patterns {
                let command = ListCommand(wildcard: pattern)
                let listed = try await executeCommand(command)
                for mailbox in listed where seenNames.insert(mailbox.name).inserted {
                    allMailboxes.append(mailbox)
                }
            }

            if !allMailboxes.isEmpty {
                return allMailboxes
            }
        }

        let command = ListCommand(wildcard: wildcard)
        return try await executeCommand(command)
    }

    /// Fetch server namespace information.
    public func fetchNamespaces() async throws -> NamespaceResponse {
        try await ensureAuthenticated()
        return try await connection.fetchNamespaces()
    }

    // MARK: - Private Helpers

    private var capabilities: Set<NIOIMAPCore.Capability> {
        connection.capabilitiesSnapshot
    }

    /// Whether the server advertised UIDPLUS for this connection.
    public var supportsUIDPlus: Bool {
        capabilities.contains(.uidPlus)
    }

    private func ensureAuthenticated() async throws {
        if !connection.isAuthenticated {
            try await authenticateOnConnection(connection)
        }
    }

    @discardableResult
    private func executeCommand<CommandType: IMAPCommand>(_ command: CommandType) async throws -> CommandType.ResultType {
        try await ensureAuthenticated()
        let result = try await connection.executeCommand(command)
        lastActivity = Date()
        return result
    }

    private func executeMove<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>, to destinationMailbox: String) async throws {
        let command = MoveCommand(identifierSet: identifierSet, destinationMailbox: resolveMailboxPath(destinationMailbox))
        try await executeCommand(command)
    }

    private func expungeMoveFallback<T: MessageIdentifier>(messages identifierSet: MessageIdentifierSet<T>) async throws {
        if T.self == UID.self && capabilities.contains(.uidPlus) {
            let uidSet = UIDSet(identifierSet.toArray().map { UID($0.value) })
            try await expunge(messages: uidSet)
        } else {
            try await expunge()
        }
    }

    private func resolveMailboxPath(_ mailboxName: String) -> String {
        guard let namespaces = connection.namespacesSnapshot else {
            return mailboxName
        }
        return namespaces.resolveMailboxPath(mailboxName)
    }
}
