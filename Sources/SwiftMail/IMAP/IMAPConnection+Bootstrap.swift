import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOSSL

extension IMAPConnection {
    func connectBody() async throws {
        try validateOperation()
        clearInvalidChannel()
        if channel?.isActive == true {
            logger.debug("\(connectionContext) connect requested while channel is already active")
            return
        }
        if let connectOverrideForTesting {
            try await connectOverrideForTesting()
            try validateOperation()
            return
        }

        let tlsTransportMode = try Self.resolveTLSTransportMode(port: port, transportSecurity: transportSecurity)
        guard let token = operationToken else {
            return try await withOperation { [self] in try await connectBody() }
        }
        let attempt = BootstrapAttempt(token: token, gate: lifetime.gate)
        try lifetime.gate.withLock {
            try lifetime.validateLocked(token)
            bootstrapAttempts[attempt.id] = attempt
        }
        defer { _ = lifetime.gate.withLock { bootstrapAttempts.removeValue(forKey: attempt.id) } }
        startBootstrap(attempt, mode: tlsTransportMode)
        do {
            try await completeBootstrap(attempt, mode: tlsTransportMode)
        } catch {
            attempt.greeting.complete(.failure(error))
            let candidates = lifetime.gate.withLock { attempt.candidates }
            for context in candidates { await closeTransport(context) }
            throw error
        }
    }

    private func startBootstrap(_ attempt: BootstrapAttempt, mode: TLSTransportMode) {
        let initializer: @Sendable (Channel) -> EventLoopFuture<Void> = { [self] channel in
            initializeChannel(channel, mode: mode, attempt: attempt)
        }
        let tcp: EventLoopFuture<Channel>
        if let bootstrapOverrideForTesting {
            tcp = bootstrapOverrideForTesting(initializer)
        } else {
            tcp = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                .channelInitializer(initializer)
                .connect(host: host, port: port)
        }
        tcp.whenComplete { result in
            switch result {
                case .success(let channel):
                    if !attempt.tcp.complete(.success(channel)) { channel.close(promise: nil) }
                case .failure(let error):
                    attempt.greeting.complete(.failure(error))
                    attempt.tcp.complete(.failure(error))
            }
        }
    }

    private func completeBootstrap(_ attempt: BootstrapAttempt, mode: TLSTransportMode) async throws {
        let token = attempt.token
        let channel = try await attempt.tcp.value()
        try await lifecycleCheckpoint("tcp")
        let context = try lifetime.gate.withLock {
            try lifetime.validateLocked(token)
            guard let context = attempt.candidates.first(where: { $0.channel === channel }) else {
                throw IMAPError.connectionFailed("Bootstrap returned an unregistered channel")
            }
            transport = context
            return context
        }
        try await lifecycleCheckpoint("published", context: context)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(5)) {
            _ = attempt.greeting.complete(.failure(IMAPError.timeout))
        }
        attempt.greeting.attachTimer(timeout, on: channel.eventLoop)
        let greetingCapabilities = try await attempt.greeting.value()
        try await lifecycleCheckpoint("greeting", context: context)
        try await refreshCapabilities(using: greetingCapabilities, useCommandBody: true)
        try await lifecycleCheckpoint("discovery", context: context)
        try await applyPostGreetingTLSPolicy(tlsTransportMode: mode, capabilities: Array(capabilitiesSnapshot))
        try validateTransport(context)
    }

    private func initializeChannel(
        _ channel: Channel, mode: TLSTransportMode, attempt: BootstrapAttempt
    ) -> EventLoopFuture<Void> {
        let context = TransportContext(generation: attempt.token.generation, channel: channel,
                                       responseBuffer: UntaggedResponseBuffer(), duplexLogger: makeDuplexLogger())
        do {
            try lifetime.gate.withLock {
                try lifetime.validateLocked(attempt.token)
                guard bootstrapAttempts[attempt.id] === attempt else { throw IMAPAbortReason.connectionAborted }
                attempt.candidates.append(context)
            }
        } catch {
            attempt.greeting.complete(.failure(error))
            channel.close(promise: nil)
            return channel.eventLoop.makeFailedFuture(error)
        }
        let greetingPromise = attempt.greeting.future(on: channel.eventLoop)
        let handlerPromise = channel.eventLoop.makePromise(of: [Capability].self)
        greetingPromise.cascade(to: handlerPromise)
        let greetingHandler = IMAPGreetingHandler(commandTag: "", promise: handlerPromise)
        greetingHandler.settlement = { attempt.greeting.complete($0) }
        do {
            try channelInitializationForTesting?(channel)
            if case .implicitTLS = mode {
                let sslHandler = try Self.makeTLSHandler(
                    for: channel,
                    host: host,
                    certificateVerificationPolicy: certificateVerificationPolicy,
                    minimumTLSVersion: minimumTLSVersion
                )
                try channel.pipeline.syncOperations.addHandler(sslHandler)
            }

            try channel.pipeline.syncOperations.addHandlers(initialHandlers(context, greeting: greetingHandler))
            let installed = channel.eventLoop.makeSucceededFuture(())
            attempt.greeting.attachHandlerCleanup(after: installed) {
                channel.pipeline.removeHandler(greetingHandler, promise: nil)
            }
            return installed
        } catch {
            attempt.greeting.complete(.failure(error))
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    private func initialHandlers(_ context: TransportContext, greeting: IMAPGreetingHandler) -> [ChannelHandler] {
        let parserOptions = parserLimits.makeParserOptions(bufferLimit: responseBufferLimit)
        return [
            IMAPClientHandler(parserOptions: parserOptions, maximumBufferSize: responseBufferLimit),
            // Bound the complete FETCH response directly behind the decoder.
            IMAPResponseLimitGuard(bodySizeLimit: parserLimits.bodySizeLimit, logger: logger,
                                   connectionContext: connectionContext),
            context.duplexLogger, greeting, context.responseBuffer
        ]
    }

}
