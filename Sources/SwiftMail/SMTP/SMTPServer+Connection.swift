// SMTPServer+Connection.swift
// Connection lifecycle, TLS/STARTTLS, and disconnect for SMTPServer.

import Foundation
import NIO
import NIOCore
import NIOSSL

extension SMTPServer {
    /**
     Connect to the SMTP server

     This method establishes a connection to the SMTP server and performs initial handshaking:
     1. Creates a TCP connection to the server
     2. Sets up SSL/TLS if using port 465 (SMTPS)
     3. Receives the server's greeting
     4. Fetches server capabilities using EHLO
     5. Upgrades to TLS using STARTTLS if on port 587

     - Throws:
       - `SMTPError.connectionFailed` if the connection cannot be established
       - `SMTPError.tlsFailed` if TLS negotiation fails
       - `NIOSSLError` if SSL/TLS setup fails
     - Note: Logs connection attempts and capability retrieval at info level
     */
    public func connect() async throws {
        logger.debug("Connecting to SMTP server at \(host):\(port)")

        let transportMode = Self.resolveTransportMode(
            port: port,
            transportSecurity: transportSecurity
        )

        let bootstrap = makeClientBootstrap(useImplicitTLS: transportMode == .implicitTLS)

        // Connect to the server
        let channel = try await bootstrap.connect(host: host, port: port).get()

        // Store the channel
        self.channel = channel

        // Wait for the server greeting using our generic handler execution pattern
        let greeting = try await executeHandlerOnly(handlerType: SMTPGreetingHandler.self)

        // Check if the greeting is positive
        guard greeting.code >= 200 && greeting.code < 300 else {
            throw SMTPError.connectionFailed("Server rejected connection: \(greeting.message)")
        }

        // Fetch capabilities using our new method
        let capabilities = try await fetchCapabilities()

        try await applyPostEHLOTLSPolicy(
            transportMode: transportMode,
            capabilities: capabilities
        )

        logger.info("Connected to SMTP server \(self.host):\(self.port)")
    }

    /// Build the NIO `ClientBootstrap` used by ``connect()``, optionally configured for implicit TLS.
    private func makeClientBootstrap(useImplicitTLS: Bool) -> ClientBootstrap {
        let host = self.host
        let certificateVerificationPolicy = self.certificateVerificationPolicy
        let duplexLogger = self.duplexLogger

        return ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                if useImplicitTLS {
                    do {
                        // Create SSL context with proper configuration for secure connection
                        let tlsConfig = MailTLSConfiguration.makeClientConfiguration(
                            certificateVerificationPolicy: certificateVerificationPolicy
                        )

                        let sslContext = try NIOSSLContext(configuration: tlsConfig)
                        let serverHostname = MailTLSConfiguration.serverHostnameForTLSHandler(host: host)
                        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)

                        // Add SSL handler first, then SMTP handlers using syncOperations
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                        try channel.pipeline.syncOperations.addHandlers([
                            ByteToMessageHandler(SMTPLineBasedFrameDecoder()),
                            duplexLogger,
                            SMTPResponseHandler()
                        ])

                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } else {
                    // Just add SMTP handlers without SSL using syncOperations
                    do {
                        try channel.pipeline.syncOperations.addHandlers([
                            ByteToMessageHandler(SMTPLineBasedFrameDecoder()),
                            duplexLogger,
                            SMTPResponseHandler()
                        ])
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }

                    return channel.eventLoop.makeSucceededFuture(())
                }
            }
    }

    func applyPostEHLOTLSPolicy(
        transportMode: SMTPTransportMode,
        capabilities: [String],
        startTLSOverrideForTesting: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        if Self.requiresMissingSTARTTLSError(
            transportMode: transportMode,
            capabilities: capabilities
        ) {
            let errorMessage = "STARTTLS required for \(host):\(port) but was not advertised. "
                + "Cannot continue without encryption."
            logger.error("\(errorMessage)")
            await closeAndClearChannelAfterSTARTTLSPolicyFailure()
            throw SMTPError.tlsFailed("STARTTLS required but not advertised by server")
        }

        if Self.requiresSTARTTLSUpgrade(
            transportMode: transportMode,
            capabilities: capabilities
        ) {
            do {
                if let startTLSOverrideForTesting {
                    try await startTLSOverrideForTesting()
                } else {
                    try await startTLS()
                }
            } catch {
                let failureMessage = "STARTTLS failed for \(host):\(port): \(error.localizedDescription). "
                    + "Cannot continue without encryption."
                logger.error("\(failureMessage)")
                await closeAndClearChannelAfterSTARTTLSPolicyFailure()
                throw SMTPError.tlsFailed("STARTTLS upgrade failed: \(error.localizedDescription)")
            }
        }
    }

    static func resolveTransportMode(
        port: Int,
        transportSecurity: MailTransportSecurity
    ) -> SMTPTransportMode {
        switch transportSecurity {
            case .automatic:
                switch port {
                    case 465:
                        return .implicitTLS
                    case 587:
                        return .startTLSIfAvailable
                    default:
                        return .plainText
                }
            case .implicitTLS:
                return .implicitTLS
            case .startTLS:
                return .startTLSRequired
            case .plainText:
                return .plainText
        }
    }

    static func requiresSTARTTLSUpgrade(
        transportMode: SMTPTransportMode,
        capabilities: [String]
    ) -> Bool {
        switch transportMode {
            case .startTLSIfAvailable, .startTLSRequired:
                return capabilities.contains("STARTTLS")
            case .implicitTLS, .plainText:
                return false
        }
    }

    static func requiresMissingSTARTTLSError(
        transportMode: SMTPTransportMode,
        capabilities: [String]
    ) -> Bool {
        transportMode == .startTLSRequired && !capabilities.contains("STARTTLS")
    }

    var hasChannelForTesting: Bool {
        channel != nil
    }

    var certificateVerificationPolicyForTesting: MailCertificateVerificationPolicy {
        certificateVerificationPolicy
    }

    func replaceChannelForTesting(_ channel: Channel?) {
        self.channel = channel
    }

    func closeAndClearChannelAfterSTARTTLSPolicyFailure() async {
        let channel = self.channel
        self.channel = nil
        self.isTLSEnabled = false
        self.capabilities = []

        guard let channel else {
            return
        }

        do {
            try await channel.close().get()
        } catch {
            logger.debug("Channel close after STARTTLS policy failure reported: \(error)")
        }
    }

    /**
     Disconnect from the SMTP server

     This method performs a clean disconnect from the server by:
     1. Sending the QUIT command
     2. Waiting for the server's response
     3. Closing the connection

     - Throws:
       - `SMTPError.disconnectFailed` if the quit command fails
       - `SMTPError.connectionFailed` if already disconnected
     - Note: Logs disconnection at info level
     */
    public func disconnect() async throws {
        guard let channel = channel else {
            logger.warning("Attempted to disconnect when channel was already nil")
            return
        }

        // Send QUIT as a courtesy — ignore failures since the email is already sent.
        // The channel close below will clean up regardless.
        do {
            let quitCommand = QuitCommand()
            try await executeCommand(quitCommand)
        } catch {
            logger.warning("QUIT command failed (non-fatal): \(error)")
        }

        // Close the channel regardless of QUIT command result
        try? await channel.close().get()
        self.channel = nil

        logger.info("Disconnected from SMTP server")
    }

    /**
     Upgrade the connection to use TLS

     This method upgrades a plain connection to use TLS encryption using the
     STARTTLS command. After successful upgrade, it re-fetches server capabilities
     as they may change.

     - Throws:
       - `SMTPError.tlsFailed` if TLS negotiation fails
       - `SMTPError.commandFailed` if STARTTLS command fails
       - `SMTPError.connectionFailed` if not connected
     - Note: Logs TLS upgrade attempts at info level
     */
    func startTLS() async throws {
        // Send STARTTLS command using the modernized command approach
        let command = StartTLSCommand()
        let success = try await executeCommand(command)

        // Check if STARTTLS was accepted
        guard success else {
            throw SMTPError.tlsFailed("Server rejected STARTTLS")
        }

        guard let channel = channel else {
            throw SMTPError.connectionFailed("Not connected to SMTP server")
        }

        // Create SSL context with proper configuration for secure connection
        let tlsConfig = MailTLSConfiguration.makeClientConfiguration(
            certificateVerificationPolicy: certificateVerificationPolicy
        )

        // Capture the configuration before the closure to avoid concurrency issues
        let finalTlsConfig = tlsConfig
        let host = self.host

        // Add SSL handler to the pipeline using EventLoop submission to ensure correct thread
        try await channel.eventLoop.submit {
            let sslContext = try NIOSSLContext(configuration: finalTlsConfig)
            let serverHostname = MailTLSConfiguration.serverHostnameForTLSHandler(host: host)
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
            try channel.pipeline.syncOperations.addHandler(sslHandler, position: .first)
        }.get()

        // Set TLS flag
        isTLSEnabled = true

        // Send EHLO again after STARTTLS and update capabilities
        let ehloCommand = EHLOCommand(hostname: String.localHostname)
        let rawResponse = try await executeCommand(ehloCommand)

        // Parse capabilities from raw response
        let capabilities = parseCapabilities(from: rawResponse)

        // Store capabilities for later use
        self.capabilities = capabilities
    }
}
