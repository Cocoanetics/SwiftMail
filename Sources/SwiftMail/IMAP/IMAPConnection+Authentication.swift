import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

extension IMAPConnection {
    /// Authenticate using AUTHENTICATE PLAIN (RFC 4616) with optional SASL-IR (RFC 4959).
    ///
    /// When the server advertises `SASL-IR`, the credentials are sent inline with the
    /// AUTHENTICATE command (saving a round trip). Otherwise falls back to the standard
    /// continuation-based exchange. Runs inside the command queue; the queue-taking
    /// entry points live in `IMAPConnection+Reauthentication.swift`.
    func authenticatePlainBody(username: String, password: String) async throws {
        try await authenticateUntilTransportIsStable(operation: "PLAIN authentication") { [self] in
            let mechanism = AuthenticationMechanism.plain
            let channel = try await prepareAuthenticationChannel(
                operation: "PLAIN authenticate", advertising: .authenticate(mechanism), name: "PLAIN"
            )
            let context = try capturedTransport()
            guard context.channel === channel else {
                throw IMAPError.connectionFailed("Authentication transport replaced")
            }
            let tag = generateCommandTag()

            let credentialBuffer = makePlainCredentialBuffer(username: username, password: password)
            let (initialResponse, expectsChallenge) = resolveSASLIR(credentials: credentialBuffer)
            let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
            handlerPromiseCreatedForTesting?()

            let handler = PlainAuthenticationHandler(
                commandTag: tag,
                promise: handlerPromise,
                credentials: credentialBuffer,
                expectsChallenge: expectsChallenge
            )
            let terminal = bindHandler(handler, promise: handlerPromise, context: context)

            let capabilities = try await runPlainAuthentication(
                PlainAuthenticationRun(
                    context: context,
                    channel: channel,
                    tag: tag,
                    mechanism: mechanism,
                    initialResponse: initialResponse,
                    handler: handler,
                    terminal: terminal
                )
            )
            return (channel, capabilities)
        }
    }

    private struct PlainAuthenticationRun {
        let context: TransportContext
        let channel: Channel
        let tag: String
        let mechanism: AuthenticationMechanism
        let initialResponse: InitialResponse?
        let handler: PlainAuthenticationHandler
        let terminal: IMAPTerminal<[Capability]>
    }

    private func runPlainAuthentication(_ run: PlainAuthenticationRun) async throws -> [Capability] {
        let command = TaggedCommand(tag: run.tag,
                                    command: .authenticate(
                                        mechanism: run.mechanism,
                                        initialResponse: run.initialResponse
                                    ))
        return try await runAuthentication(handler: run.handler, terminal: run.terminal,
                                           context: run.context, channel: run.channel, command: command)
    }

    /// Returns the channel to authenticate on, judged against a capability snapshot
    /// taken on that same channel. The check runs after the channel is prepared: a
    /// disconnect clears the snapshot with the channel, and judging the stale empty
    /// set first turned every re-authentication on a dropped connection into "not
    /// advertised by server" without contacting the server. An empty snapshot on a
    /// live channel is refreshed with an explicit CAPABILITY; that refresh runs through
    /// `executeCommandBody`, which may recycle or reconnect the transport, so the
    /// channel is prepared again afterwards and the caller authenticates on the
    /// transport that is live now, never on one the refresh replaced.
    private func prepareAuthenticationChannel(
        operation: String,
        advertising capability: Capability,
        name: String
    ) async throws -> Channel {
        try validateOperation()
        var channel = try await prepareAuthenticationChannel(operation: operation)
        var refreshes = 0
        while capabilities.isEmpty {
            guard refreshes < 2 else {
                throw IMAPError.connectionFailed("\(operation): capability snapshot stayed empty across reconnects")
            }
            refreshes += 1
            if let override = capabilityRefreshOverrideForTesting {
                try await override()
                try validateOperation()
            } else {
                try await refreshCapabilities(using: [], useCommandBody: true)
            }
            channel = try await prepareAuthenticationChannel(operation: operation)
        }
        guard capabilities.contains(capability) else {
            throw IMAPError.unsupportedAuthMechanism("\(name) not advertised by server")
        }
        return channel
    }

    private func prepareAuthenticationChannel(operation: String) async throws -> Channel {
        try validateOperation()
        try await waitForIdleCompletionIfNeeded()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: operation)

        clearInvalidChannel()

        if self.channel == nil {
            try await reopenTransport(before: "authentication")
        }

        guard let channel = self.channel, channel.isActive else {
            throw IMAPError.connectionFailed("Channel not initialized")
        }
        return channel
    }

    // MARK: - SASL-IR Helpers

    /// Resolve whether to use SASL-IR (RFC 4959) for the given credentials.
    ///
    /// Returns the `InitialResponse` to embed in the AUTHENTICATE command (nil = use continuation)
    /// and whether the handler should expect a server challenge before sending credentials.
    ///
    /// - Parameters:
    ///   - credentials: The pre-built credential buffer.
    ///   - maxInlineBytes: Maximum payload size for inline SASL-IR. Payloads exceeding this
    ///     fall back to continuation mode even when SASL-IR is supported (prevents issues with
    ///     servers that impose line-length limits). Pass `nil` for no limit.
    /// - Returns: A tuple of `(initialResponse, expectsChallenge)`.
    func resolveSASLIR(
        credentials: ByteBuffer,
        maxInlineBytes: Int? = nil
    ) -> (initialResponse: InitialResponse?, expectsChallenge: Bool) {
        let supportsSASLIR = capabilities.contains(.saslIR)

        if supportsSASLIR {
            if let limit = maxInlineBytes, credentials.readableBytes > limit {
                let message = "SASL-IR payload size \(credentials.readableBytes) exceeds inline limit "
                    + "\(limit); switching to continuation mode"
                logger.info("\(message)")
                return (nil, true)
            }
            return (InitialResponse(credentials), false)
        }

        return (nil, true)
    }

    /// Build the RFC 4616 PLAIN credential buffer: \0username\0password
    func makePlainCredentialBuffer(username: String, password: String) -> ByteBuffer {
        // PLAIN format: [authzid] NUL authcid NUL passwd
        // authzid is empty (same as authcid)
        var buffer = ByteBufferAllocator().buffer(capacity: username.utf8.count + password.utf8.count + 2)
        buffer.writeInteger(UInt8(0x00))  // empty authzid
        buffer.writeString(username)
        buffer.writeInteger(UInt8(0x00))
        buffer.writeString(password)
        return buffer
    }

    func authenticateXOAUTH2Body(email: String, accessToken: String) async throws {
        try await authenticateUntilTransportIsStable(operation: "XOAUTH2 authentication") { [self] in
            // A valid atom, so the failable initializer cannot return nil.
            let mechanism = AuthenticationMechanism("XOAUTH2")!
            let channel = try await prepareAuthenticationChannel(
                operation: "XOAUTH2 authenticate", advertising: .authenticate(mechanism), name: "XOAUTH2"
            )
            let context = try capturedTransport()
            guard context.channel === channel else {
                throw IMAPError.connectionFailed("Authentication transport replaced")
            }
            let tag = generateCommandTag()

            let credentialBuffer = makeXOAUTH2InitialResponseBuffer(email: email, accessToken: accessToken)
            let (initialResponse, expectsChallenge) = resolveSASLIR(
                credentials: credentialBuffer,
                maxInlineBytes: 1024
            )
            let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
            handlerPromiseCreatedForTesting?()

            let handler = XOAUTH2AuthenticationHandler(
                commandTag: tag,
                promise: handlerPromise,
                credentials: credentialBuffer,
                expectsChallenge: expectsChallenge,
                logger: logger
            )
            let terminal = bindHandler(handler, promise: handlerPromise, context: context)

            let capabilities = try await runXOAUTH2Authentication(
                XOAUTH2AuthenticationRun(
                    context: context,
                    channel: channel,
                    tag: tag,
                    mechanism: mechanism,
                    initialResponse: initialResponse,
                    handler: handler,
                    terminal: terminal
                )
            )
            return (channel, capabilities)
        }
    }

    private struct XOAUTH2AuthenticationRun {
        let context: TransportContext
        let channel: Channel
        let tag: String
        let mechanism: AuthenticationMechanism
        let initialResponse: InitialResponse?
        let handler: XOAUTH2AuthenticationHandler
        let terminal: IMAPTerminal<[Capability]>
    }

    private func runXOAUTH2Authentication(_ run: XOAUTH2AuthenticationRun) async throws -> [Capability] {
        let command = TaggedCommand(tag: run.tag,
                                    command: .authenticate(
                                        mechanism: run.mechanism,
                                        initialResponse: run.initialResponse
                                    ))
        return try await runAuthentication(handler: run.handler, terminal: run.terminal,
                                           context: run.context, channel: run.channel, command: command)
    }

    private func runAuthentication<Handler: IMAPCommandHandler>(
        handler: Handler, terminal: IMAPTerminal<[Capability]>, context: TransportContext,
        channel: Channel, command: TaggedCommand
    ) async throws -> [Capability] where Handler.ResultType == [Capability] {
        do {
            try await installHandler(handler, terminal: terminal, context: context)
            let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command))
            let token = operationToken
            channel.eventLoop.execute { [self] in
                do {
                    try validateTransport(context, token: token)
                    channel.writeAndFlush(wrapped).whenFailure { terminal.complete(.failure($0)) }
                    let timer = channel.eventLoop.scheduleTask(in: .seconds(10)) {
                        _ = terminal.complete(.failure(IMAPError.timeout))
                    }
                    terminal.attachTimer(timer, on: channel.eventLoop)
                } catch { terminal.complete(.failure(error)) }
            }
            let capabilities = try await terminal.value()
            try validateTransport(context)
            await handleConnectionTerminationInResponses(handler.untaggedResponses, context: context)
            context.duplexLogger.flushInboundBuffer()
            return capabilities
        } catch {
            terminal.complete(.failure(error))
            context.duplexLogger.flushInboundBuffer()
            await handleConnectionTerminationInResponses(handler.untaggedResponses, context: context)
            if shouldRecycleConnection(for: error) { await closeTransport(context) }
            throw error
        }
    }

    func makeXOAUTH2InitialResponseBuffer(email: String, accessToken: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: email.utf8.count + accessToken.utf8.count + 32)
        buffer.writeString("user=")
        buffer.writeString(email)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeString("auth=Bearer ")
        buffer.writeString(accessToken)
        buffer.writeInteger(UInt8(0x01))
        buffer.writeInteger(UInt8(0x01))
        return buffer
    }
}
