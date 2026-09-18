import NIOIMAPCore

extension IMAPServer {
    /// Enables extensions on the current primary connection.
    ///
    /// Call this after authentication and before selecting a mailbox. The returned
    /// capabilities are only those confirmed by this ENABLE command. Enable them
    /// again after the connection is replaced.
    ///
    /// - Throws: ``IMAPError/invalidArgument(_:)`` for an empty request or
    ///   a malformed capability value,
    ///   ``IMAPError/commandNotSupported(_:)`` when ENABLE was not advertised, or
    ///   ``IMAPError/commandFailed(_:)`` when the server rejects the command.
    @discardableResult
    public func enable(_ capabilities: [Capability]) async throws -> [Capability] {
        try await ensurePrimaryConnectionAuthenticated()
        let command = EnableCommand(capabilities: capabilities)
        try command.validate()
        guard primaryConnection.capabilitiesSnapshot.contains(.enable) else {
            throw IMAPError.commandNotSupported("ENABLE command not supported by server")
        }
        return try await primaryConnection.executeCommand(command)
    }
}
