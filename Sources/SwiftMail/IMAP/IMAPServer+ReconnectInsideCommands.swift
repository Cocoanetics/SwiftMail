import Foundation

extension IMAPServer {
    /// Turns the reconnect inside commands on or off, for the primary connection and
    /// every named connection, including ones created later. It is on by default.
    ///
    /// With it on, a command that finds its connection gone opens a new one and logs in
    /// again before it runs. With it off, that command throws
    /// ``IMAPError/connectionFailed(_:)`` instead and opens no connection; the session
    /// it was running in, with its selected mailbox, has ended. Reconnect on purpose
    /// with ``connect()`` and log in again. Turn it off when a command must never run
    /// in a session the caller did not open, such as a MOVE whose COPYUID the caller
    /// records. Dedicated IDLE sessions keep their own re-dial and are not affected.
    public func setReconnectsInsideCommands(_ enabled: Bool) {
        reconnectsInsideCommands = enabled
        primaryConnection.reconnectsInsideCommands = enabled
        for named in namedConnections.values {
            named.connection.reconnectsInsideCommands = enabled
        }
    }

    /// Hands a connection this server owns the current switch. A named connection gets
    /// it when it is made and again when it is registered: the switch may change during
    /// the awaits in between, while the connection is not yet where the setter looks.
    func applyReconnectsInsideCommands(to connection: IMAPConnection) {
        connection.reconnectsInsideCommands = reconnectsInsideCommands
    }
}
