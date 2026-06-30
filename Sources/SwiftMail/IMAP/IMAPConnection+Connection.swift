import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

extension IMAPConnection {
    func connectBody() async throws {
        clearInvalidChannel()
        if channel?.isActive == true {
            logger.debug("\(connectionContext) connect requested while channel is already active")
            return
        }

        // Any buffered state belongs to a previous transport and must not leak.
        responseBuffer.reset()
        idleHandler = nil
        idleTerminationInProgress = false

        let tlsTransportMode = try Self.resolveTLSTransportMode(port: port, transportSecurity: transportSecurity)
        let greetingPromise = group.next().makePromise(of: [Capability].self)
        let greetingHandler = IMAPGreetingHandler(commandTag: "", promise: greetingPromise)

        let bootstrap = makeConnectionBootstrap(initialTLSMode: tlsTransportMode, greetingHandler: greetingHandler)
        let channel = try await openChannel(bootstrap: bootstrap, greetingPromise: greetingPromise)

        self.channel = channel
        self.isSessionAuthenticated = false
        self.namespaces = nil

        logger.info("\(connectionContext) Connected; response buffer limit \(responseBufferLimit) bytes")

        let greetingCapabilities = try await waitForGreeting(
            channel: channel,
            greetingPromise: greetingPromise,
            greetingHandler: greetingHandler
        )
        try await refreshCapabilities(using: greetingCapabilities)
        try await applyPostGreetingTLSPolicy(tlsTransportMode: tlsTransportMode, capabilities: Array(capabilities))
    }

    private func makeConnectionBootstrap(
        initialTLSMode: TLSTransportMode,
        greetingHandler: IMAPGreetingHandler
    ) -> ClientBootstrap {
        let host = self.host
        let certificateVerificationPolicy = self.certificateVerificationPolicy
        let duplexLogger = self.duplexLogger
        let responseBuffer = self.responseBuffer
        let responseBufferLimit = self.responseBufferLimit

        return ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                do {
                    let parserOptions = ResponseParser.Options(
                        bufferLimit: responseBufferLimit,
                        messageAttributeLimit: .max,
                        bodySizeLimit: .max,
                        literalSizeLimit: IMAPDefaults.literalSizeLimit
                    )

                    if case .implicitTLS = initialTLSMode {
                        let sslHandler = try Self.makeTLSHandler(
                            for: channel,
                            host: host,
                            certificateVerificationPolicy: certificateVerificationPolicy
                        )
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }

                    try channel.pipeline.syncOperations.addHandlers([
                        IMAPClientHandler(parserOptions: parserOptions),
                        duplexLogger,
                        greetingHandler,
                        responseBuffer
                    ])

                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
    }

    private func openChannel(
        bootstrap: ClientBootstrap,
        greetingPromise: EventLoopPromise<[Capability]>
    ) async throws -> Channel {
        do {
            return try await bootstrap.connect(host: host, port: port).get()
        } catch {
            // Fail the greeting promise before rethrowing — prevents NIO "leaking promise"
            // fatal error when TCP connection fails (e.g. no internet).
            greetingPromise.fail(error)
            throw error
        }
    }

    private func waitForGreeting(
        channel: Channel,
        greetingPromise: EventLoopPromise<[Capability]>,
        greetingHandler: IMAPGreetingHandler
    ) async throws -> [Capability] {
        let timeoutTask = group.next().scheduleTask(in: .seconds(5)) {
            greetingPromise.fail(IMAPError.timeout)
        }

        do {
            let greetingCapabilities = try await greetingPromise.futureResult.get()
            timeoutTask.cancel()
            try? await channel.pipeline.removeHandler(greetingHandler).get()
            return greetingCapabilities
        } catch {
            timeoutTask.cancel()
            try? await channel.pipeline.removeHandler(greetingHandler).get()
            throw error
        }
    }

    func doneBody(timeoutSeconds: TimeInterval = 15) async throws {
        guard let handler = idleHandler else {
            logger.debug("\(connectionContext) No active IDLE session, skipping DONE command")
            return
        }

        if try await handleAmbiguousIdleCompletion(handler: handler) {
            return
        }

        guard let channel = try await resolveActiveChannelForDone() else {
            return
        }

        guard !idleTerminationInProgress else {
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
            return
        }

        idleTerminationInProgress = true

        defer {
            idleTerminationInProgress = false
            idleHandler = nil
            responseBuffer.hasActiveHandler = false
        }

        try await performIdleDone(handler: handler, channel: channel, timeoutSeconds: timeoutSeconds)
    }

    private func handleAmbiguousIdleCompletion(handler: IdleHandler) async throws -> Bool {
        guard handler.isCompleted else { return false }
        let warning = "\(connectionContext) IDLE already completed before DONE; "
            + "forcing reconnect due to ambiguous IDLE completion state"
        logger.warning("\(warning)")
        idleHandler = nil
        responseBuffer.hasActiveHandler = false
        try? await disconnectBody()
        throw IMAPError.connectionFailed(
            "Ambiguous IDLE completion detected before DONE; connection recycled to resynchronize IMAP state"
        )
    }

    private func resolveActiveChannelForDone() async throws -> Channel? {
        guard let channel = self.channel, channel.isActive else {
            let terminationReasons = responseBuffer.consumeBufferedConnectionTerminationReasons()
            if !terminationReasons.isEmpty {
                let reason = terminationReasons.joined(separator: " | ")
                logger.info("\(connectionContext) Skipping DONE because server already closed connection: \(reason)")
                idleHandler = nil
                responseBuffer.hasActiveHandler = false
                return nil
            }

            logger.warning("\(connectionContext) Cannot send DONE because channel is not active")
            idleHandler = nil
            responseBuffer.hasActiveHandler = false
            throw IMAPError.connectionFailed("Channel is not active")
        }
        return channel
    }

    private func performIdleDone(
        handler: IdleHandler,
        channel: Channel,
        timeoutSeconds: TimeInterval
    ) async throws {
        do {
            try await waitForIdleStartIfNeeded(handler, timeoutSeconds: min(timeoutSeconds, 5))
            _ = try await waitForFutureWithTimeout(
                channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.idleDone)),
                timeoutSeconds: timeoutSeconds
            )
            try await waitForIdleHandlerCompletion(handler, timeoutSeconds: timeoutSeconds)
        } catch {
            duplexLogger.flushInboundBuffer()

            if error is CancellationError {
                logger.warning("\(connectionContext) IDLE termination was cancelled; recycling connection")
                try? await disconnectBody()
                throw error
            }

            if handler.isCompleted {
                try await requireTaggedIdleCompletion(handler)
                throw error
            }

            logErrorDiagnostics(error: error, operation: "DONE")

            if let imapError = error as? IMAPError, case .timeout = imapError {
                logger.warning("\(connectionContext) Timed out waiting for IDLE termination after DONE")
            } else {
                logger.warning("\(connectionContext) Failed to terminate IDLE after DONE: \(error)")
            }

            try? await disconnectBody()
            throw error
        }

        try await requireTaggedIdleCompletion(handler)
        duplexLogger.flushInboundBuffer()
    }

    private func requireTaggedIdleCompletion(_ handler: IdleHandler) async throws {
        guard handler.completedWithTaggedResponse else {
            let reason = handler.completionReason?.rawValue ?? "unknown"
            let warning = "\(connectionContext) IDLE completed without tagged completion "
                + "during DONE (reason=\(reason)); recycling connection"
            logger.warning("\(warning)")
            try? await disconnectBody()
            throw IMAPError.connectionFailed(
                "IDLE completed without tagged completion during DONE; connection recycled"
            )
        }
    }

    func disconnectBody() async throws {
        guard let channel = self.channel else {
            logger.warning("\(connectionContext) Attempted to disconnect when channel was already nil")
            isSessionAuthenticated = false
            capabilities = []
            namespaces = nil
            responseBuffer.reset()
            idleHandler = nil
            idleTerminationInProgress = false
            return
        }

        do {
            try await channel.close().get()
        } catch {
            logger.debug("\(connectionContext) Channel close during disconnect reported: \(error)")
        }
        self.channel = nil
        self.isSessionAuthenticated = false
        self.capabilities = []
        self.namespaces = nil
        self.idleHandler = nil
        self.idleTerminationInProgress = false
        self.responseBuffer.reset()
    }

    func clearInvalidChannel() {
        if let channel = self.channel, !channel.isActive {
            logger.info("\(connectionContext) Channel is no longer active, clearing channel reference")
            self.channel = nil
            self.isSessionAuthenticated = false
            self.idleHandler = nil
            self.idleTerminationInProgress = false
            self.responseBuffer.reset()
        }
    }

    func recycleConnectionIfBufferedTerminationIfNeeded(operation: String) async throws {
        guard responseBuffer.hasBufferedConnectionTermination else { return }
        let reasons = responseBuffer.consumeBufferedConnectionTerminationReasons()
        let reasonSummary = reasons.isEmpty ? "<unknown>" : reasons.joined(separator: " | ")
        let warning = "\(connectionContext) Buffered BYE/fatal detected before \(operation). "
            + "Recycling connection. reasons=\(reasonSummary)"
        logger.warning("\(warning)")
        try await disconnectBody()
    }

    func shouldRecycleConnection(for error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let imapError = error as? IMAPError {
            switch imapError {
                case .connectionFailed, .timeout:
                    return true
                default:
                    break
            }
        }

        // Raw NIO transport failure (e.g. writeAndFlush on a closed channel). The substring
        // check below misses most ChannelError cases — `String(describing:)` returns just the
        // case name (`alreadyClosed`, `ioOnClosedChannel`, `connectPending`, `inputClosed`,
        // `outputClosed`), none of which match the literals we look for. Without this guard
        // the dead channel stays in `self.channel` and the next command hits the same socket.
        if error is ChannelError {
            return true
        }

        return errorDescriptionIndicatesRecycle(error)
    }

    private func errorDescriptionIndicatesRecycle(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("decodererror")
            || description.contains("parsererror")
            || description.contains("channel is not active")
            || description.contains("connection reset by peer")
            || description.contains("broken pipe")
            || description.contains("eof")
            || description.contains("invalid state")
    }

    func logErrorDiagnostics(error: Error, operation: String) {
        let active = channel?.isActive ?? false
        let diagnostics = """
        \(connectionContext) \(operation) failed: \(error); \
        channelActive=\(active) authenticated=\(isSessionAuthenticated) \
        idleHandlerActive=\(idleHandler != nil) idleTerminationInProgress=\(idleTerminationInProgress) \
        bufferedResponses=\(responseBuffer.bufferedCount) \
        bufferedTermination=\(responseBuffer.hasBufferedConnectionTermination)
        """
        logger.error("\(diagnostics)")
    }
}
