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
            let mechanism = AuthenticationMechanism("PLAIN")
            let channel = try await prepareAuthenticationChannel(
                operation: "PLAIN authenticate", advertising: .authenticate(mechanism), name: "PLAIN"
            )
            let tag = generateCommandTag()

            let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
            let credentialBuffer = makePlainCredentialBuffer(username: username, password: password)
            let (initialResponse, expectsChallenge) = resolveSASLIR(credentials: credentialBuffer)

            let handler = PlainAuthenticationHandler(
                commandTag: tag,
                promise: handlerPromise,
                credentials: credentialBuffer,
                expectsChallenge: expectsChallenge
            )

            let capabilities = try await runPlainAuthentication(
                PlainAuthenticationRun(
                    channel: channel,
                    tag: tag,
                    mechanism: mechanism,
                    initialResponse: initialResponse,
                    handler: handler,
                    handlerPromise: handlerPromise
                )
            )
            return (channel, capabilities)
        }
    }

    private struct PlainAuthenticationRun {
        let channel: Channel
        let tag: String
        let mechanism: AuthenticationMechanism
        let initialResponse: InitialResponse?
        let handler: PlainAuthenticationHandler
        let handlerPromise: EventLoopPromise<[Capability]>
    }

    private func runPlainAuthentication(_ run: PlainAuthenticationRun) async throws -> [Capability] {
        let channel = run.channel
        let tag = run.tag
        let mechanism = run.mechanism
        let initialResponse = run.initialResponse
        let handler = run.handler
        let handlerPromise = run.handlerPromise
        var scheduledTask: Scheduled<Void>?

        do {
            try await channel.pipeline.addHandler(handler, position: .before(responseBuffer)).get()
            responseBuffer.hasActiveHandler = true

            scheduledTask = schedulePlainAuthTimeout(channel: channel, promise: handlerPromise)
            try await sendAuthenticateCommand(
                channel: channel,
                tag: tag,
                mechanism: mechanism,
                initialResponse: initialResponse
            )
            let postAuthCapabilities = try await handlerPromise.futureResult.get()

            scheduledTask?.cancel()
            responseBuffer.hasActiveHandler = false

            duplexLogger.flushInboundBuffer()
            return postAuthCapabilities
        } catch {
            scheduledTask?.cancel()
            responseBuffer.hasActiveHandler = false

            // Ensure the promise is resolved to prevent NIO "leaking promise" fatal error
            handlerPromise.fail(error)

            duplexLogger.flushInboundBuffer()
            if !handler.isCompleted {
                try? await channel.pipeline.removeHandler(handler)
            }
            logErrorDiagnostics(error: error, operation: "PLAIN authenticate [\(tag)]")
            if shouldRecycleConnection(for: error) {
                try? await disconnectBody()
            }
            throw error
        }
    }

    private func schedulePlainAuthTimeout(
        channel: Channel,
        promise: EventLoopPromise<[Capability]>
    ) -> Scheduled<Void> {
        let authenticationTimeoutSeconds = 10
        let logger = self.logger
        return channel.eventLoop.scheduleTask(in: .seconds(Int64(authenticationTimeoutSeconds))) {
            logger.warning("PLAIN authentication timed out after \(authenticationTimeoutSeconds) seconds")
            promise.fail(IMAPError.timeout)
        }
    }

    private func sendAuthenticateCommand(
        channel: Channel,
        tag: String,
        mechanism: AuthenticationMechanism,
        initialResponse: InitialResponse?
    ) async throws {
        let command = TaggedCommand(
            tag: tag,
            command: .authenticate(mechanism: mechanism, initialResponse: initialResponse)
        )
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command))
        try await channel.writeAndFlush(wrapped)
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
        var channel = try await prepareAuthenticationChannel(operation: operation)
        var refreshes = 0
        while capabilities.isEmpty {
            guard refreshes < 2 else {
                throw IMAPError.connectionFailed("\(operation): capability snapshot stayed empty across reconnects")
            }
            refreshes += 1
            if let override = capabilityRefreshOverrideForTesting {
                try await override()
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
        try await waitForIdleCompletionIfNeeded()
        try await recycleConnectionIfBufferedTerminationIfNeeded(operation: operation)

        clearInvalidChannel()

        if self.channel == nil {
            logger.info("\(connectionContext) Channel is nil, re-establishing connection before authentication")
            try await connectBody()
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
            let mechanism = AuthenticationMechanism("XOAUTH2")
            let channel = try await prepareAuthenticationChannel(
                operation: "XOAUTH2 authenticate", advertising: .authenticate(mechanism), name: "XOAUTH2"
            )
            let tag = generateCommandTag()

            let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
            let credentialBuffer = makeXOAUTH2InitialResponseBuffer(email: email, accessToken: accessToken)
            let (initialResponse, expectsChallenge) = resolveSASLIR(
                credentials: credentialBuffer,
                maxInlineBytes: 1024
            )

            let handler = XOAUTH2AuthenticationHandler(
                commandTag: tag,
                promise: handlerPromise,
                credentials: credentialBuffer,
                expectsChallenge: expectsChallenge,
                logger: logger
            )

            let capabilities = try await runXOAUTH2Authentication(
                XOAUTH2AuthenticationRun(
                    channel: channel,
                    tag: tag,
                    mechanism: mechanism,
                    initialResponse: initialResponse,
                    handler: handler,
                    handlerPromise: handlerPromise
                )
            )
            return (channel, capabilities)
        }
    }

    private struct XOAUTH2AuthenticationRun {
        let channel: Channel
        let tag: String
        let mechanism: AuthenticationMechanism
        let initialResponse: InitialResponse?
        let handler: XOAUTH2AuthenticationHandler
        let handlerPromise: EventLoopPromise<[Capability]>
    }

    private func runXOAUTH2Authentication(_ run: XOAUTH2AuthenticationRun) async throws -> [Capability] {
        let channel = run.channel
        let tag = run.tag
        let mechanism = run.mechanism
        let initialResponse = run.initialResponse
        let handler = run.handler
        let handlerPromise: EventLoopPromise<[Capability]> = run.handlerPromise
        var scheduledTask: Scheduled<Void>?

        do {
            try await channel.pipeline.addHandler(handler, position: .before(responseBuffer)).get()
            responseBuffer.hasActiveHandler = true

            scheduledTask = scheduleXOAUTH2Timeout(channel: channel, promise: handlerPromise)
            try await writeAuthenticateCommandFlushed(
                channel: channel,
                tag: tag,
                mechanism: mechanism,
                initialResponse: initialResponse
            )
            let refreshedCapabilities = try await handlerPromise.futureResult.get()

            scheduledTask?.cancel()
            responseBuffer.hasActiveHandler = false
            await handleConnectionTerminationInResponses(handler.untaggedResponses)
            duplexLogger.flushInboundBuffer()

            return refreshedCapabilities
        } catch {
            await handleXOAUTH2Failure(
                error: error,
                scheduledTask: scheduledTask,
                handler: handler,
                handlerPromise: handlerPromise,
                channel: channel
            )
            throw error
        }
    }

    private func scheduleXOAUTH2Timeout(
        channel: Channel,
        promise: EventLoopPromise<[Capability]>
    ) -> Scheduled<Void> {
        let authenticationTimeoutSeconds = 10
        let logger = self.logger
        // Schedule on the channel event loop to avoid cross-loop promise completion.
        return channel.eventLoop.scheduleTask(in: .seconds(Int64(authenticationTimeoutSeconds))) {
            logger.warning("XOAUTH2 authentication timed out after \(authenticationTimeoutSeconds) seconds")
            promise.fail(IMAPError.timeout)
        }
    }

    private func writeAuthenticateCommandFlushed(
        channel: Channel,
        tag: String,
        mechanism: AuthenticationMechanism,
        initialResponse: InitialResponse?
    ) async throws {
        let command = TaggedCommand(
            tag: tag,
            command: .authenticate(mechanism: mechanism, initialResponse: initialResponse)
        )
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(command))
        try await channel.writeAndFlush(wrapped).get()
    }

    private func handleXOAUTH2Failure(
        error: Error,
        scheduledTask: Scheduled<Void>?,
        handler: XOAUTH2AuthenticationHandler,
        handlerPromise: EventLoopPromise<[Capability]>,
        channel: Channel
    ) async {
        scheduledTask?.cancel()
        responseBuffer.hasActiveHandler = false

        let earlyFailure = !handler.isCompleted
        if earlyFailure {
            logger.debug("XOAUTH2_EARLY_SEND_FAILURE auth write failed before handler completion")
        }

        // Ensure the command promise is always resolved on early auth failures
        // (for example write failure on a closed channel before handler callbacks fire).
        handlerPromise.fail(error)
        await handleConnectionTerminationInResponses(handler.untaggedResponses)
        duplexLogger.flushInboundBuffer()

        logErrorDiagnostics(error: error, operation: "XOAUTH2 authenticate")

        if earlyFailure {
            try? await channel.pipeline.removeHandler(handler)
        }

        if shouldRecycleConnection(for: error) {
            try? await disconnectBody()
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
