import Foundation
import NIOIMAPCore

extension IMAPServer.Authentication {
    /// The same steps as `authenticate(on:)` for a caller that already holds the
    /// connection's command queue: the transparent re-authentication a connection runs
    /// after reopening its transport inside a command or an IDLE start.
    func authenticateBody(on connection: IMAPConnection) async throws {
        switch method {
            case .login(let username, let password):
                try await connection.loginBody(username: username, password: password)
            case .plain(let username, let password):
                try await connection.authenticatePlainBody(username: username, password: password)
            case .xoauth2(let email, let accessTokenProvider):
                let accessToken = try await accessTokenProvider()
                try await connection.authenticateXOAUTH2Body(email: email, accessToken: accessToken)
        }
        guard let identification else { return }
        try await Self.identifyBody(connection, with: identification)
    }

    /// `identify(_:with:)` for a caller holding the command queue: the same tolerance for
    /// a server that refuses ID, the same propagation of a failure that recycled the connection.
    static func identifyBody(_ connection: IMAPConnection, with identification: Identification) async throws {
        guard connection.capabilitiesSnapshot.contains(.id) else { return }
        do {
            _ = try await connection.idBody(identification)
        } catch let error as CancellationError {
            throw error
        } catch {
            guard connection.isConnected, connection.isAuthenticated else {
                throw error
            }
        }
    }
}

extension IMAPServer {
    /// Teaches a connection this server owns how to recover its session when its
    /// command path or IDLE start has to reopen the transport. Without it the first
    /// command after a peer reset went out on the fresh socket before any AUTHENTICATE
    /// (Gmail answers `BAD Unknown command`), whatever a caller had checked a moment
    /// earlier.
    func installReauthentication(on connection: IMAPConnection) {
        guard let authentication else {
            connection.reauthenticateAfterReconnect = nil
            return
        }
        connection.reauthenticateAfterReconnect = { connection in
            try await authentication.authenticateBody(on: connection)
        }
    }

    /// Runs whenever `authentication` changes: the primary and every live named and
    /// IDLE connection learn the current credentials.
    func installReauthenticationOnOwnedConnections() {
        installReauthentication(on: primaryConnection)
        for named in namedConnections.values {
            installReauthentication(on: named.connection)
        }
        for idle in idleConnections.values {
            installReauthentication(on: idle.connection)
        }
    }
}
