import Foundation
import NIO
import NIOIMAPCore
import NIOIMAP

/// Pipeline resources belong to one socket, including when recovery stays in the
/// same generation. Never reuse a handler or buffer on a replacement socket.
final class TransportContext: @unchecked Sendable {
    let generation: ConnectionGeneration
    let id = UUID()
    let channel: Channel
    let responseBuffer: UntaggedResponseBuffer
    let duplexLogger: IMAPLogger
    var capabilities: Set<Capability> = []
    var namespaces: NamespaceResponse?
    var authenticated = false
    var idleHandler: IdleHandler?
    var idleTerminationInProgress = false

    init(
        generation: ConnectionGeneration,
        channel: Channel,
        responseBuffer: UntaggedResponseBuffer,
        duplexLogger: IMAPLogger
    ) {
        self.generation = generation
        self.channel = channel
        self.responseBuffer = responseBuffer
        self.duplexLogger = duplexLogger
    }
}

final class BootstrapAttempt: @unchecked Sendable {
    let id = UUID()
    let token: OperationToken
    let tcp: IMAPTerminal<Channel>
    let greeting: IMAPTerminal<[Capability]>
    // Access only under the connection lifetime gate.
    var candidates: [TransportContext] = []

    init(token: OperationToken, gate: IMAPLifetimeGate) {
        self.token = token
        tcp = IMAPTerminal(gate: gate)
        greeting = IMAPTerminal(gate: gate)
    }
}

enum IMAPOperationScope {
    @TaskLocal static var tokens: [ObjectIdentifier: OperationToken] = [:]
}

enum IMAPWriteScope {
    @TaskLocal static var validate: @Sendable () throws -> Void = {}
}

extension IMAPConnection {
    var operationToken: OperationToken? { IMAPOperationScope.tokens[ObjectIdentifier(lifetime)] }

    /// The detached owner may remain suspended in foreign code after abort. Its
    /// caller waits on the registered cell, so fresh queue work can start at once.
    func withOperation<T>(forCleanup: Bool = false, _ body: @escaping () async throws -> T) async throws -> T {
        if let token = operationToken {
            try lifetime.validate(token)
            if forCleanup { return try await commandQueue.runForCleanup(token: token, body) }
            return try await commandQueue.run(token: token, body)
        }
        let (token, terminal) = lifetime.registerOperation(of: T.self)
        var authority = IMAPOperationScope.tokens
        authority[ObjectIdentifier(lifetime)] = token
        let ownerFinished = operationOwnerFinishedForTesting
        let owner = Task {
            defer { ownerFinished?() }
            do {
                let result = try await IMAPOperationScope.$tokens.withValue(authority) {
                    if forCleanup { return try await commandQueue.runForCleanup(token: token, body) }
                    return try await commandQueue.run(token: token, body)
                }
                terminal.complete(.success(result))
            } catch {
                terminal.complete(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await terminal.value()
        } onCancel: {
            owner.cancel()
        }
    }

    func validateOperation() throws {
        if let token = operationToken {
            try lifetime.validate(token)
        } else {
            try lifetime.validateAdmission()
        }
    }

    func lifecycleCheckpoint(_ stage: String, context: TransportContext? = nil) async throws {
        await lifecycleCheckpointForTesting?(stage)
        try validateOperation()
        if let context { try validateTransport(context) }
    }

    func validateTransport(_ context: TransportContext) throws {
        try validateTransport(context, token: operationToken)
    }

    func validateTransport(_ context: TransportContext, token: OperationToken?) throws {
        try lifetime.gate.withLock { try validateTransportLocked(context, token: token) }
    }

    func validateTransportLocked(_ context: TransportContext, token: OperationToken?) throws {
        try lifetime.validateGenerationLocked(context.generation)
        if let token { try lifetime.validateLocked(token) }
        guard transport === context else { throw IMAPError.connectionFailed("Transport was replaced") }
    }

    func commit<T>(on context: TransportContext, _ body: () -> T) throws -> T {
        try lifetime.gate.withLock {
            try validateTransportLocked(context, token: operationToken)
            return body()
        }
    }

    func capturedTransport() throws -> TransportContext {
        try lifetime.gate.withLock {
            if let token = operationToken { try lifetime.validateLocked(token) }
            guard let transport else { throw IMAPError.connectionFailed("Channel not initialized") }
            try validateTransportLocked(transport, token: operationToken)
            return transport
        }
    }

    /// Synchronous admission latch and detach; no queue, DONE or LOGOUT.
    func abortNow() {
        lifetime.invalidate {
            let contexts = (self.transport.map { [$0] } ?? [])
                + self.bootstrapAttempts.values.flatMap { $0.candidates }
                + Array(self.closingTransports.values)
            var actions = self.bootstrapAttempts.values.flatMap {
                ($0.tcp.settleLocked(.failure(IMAPAbortReason.connectionAborted)) ?? [])
                    + ($0.greeting.settleLocked(.failure(IMAPAbortReason.connectionAborted)) ?? [])
            }
            self.transport = nil
            self.bootstrapAttempts.removeAll()
            self.closingTransports.removeAll()
            self.sessionWasLost = false
            self.authenticatingGeneration = nil
            self.stagingCapabilities = []
            self.stagingBuffer = UntaggedResponseBuffer()
            self.stagingLogger = self.makeDuplexLogger()
            actions += contexts.map { context in { context.channel.close(promise: nil) } }
            return actions
        }
    }

    func bindHandler<T, Handler: IMAPCommandHandler>(
        _ handler: Handler, promise: EventLoopPromise<T>, context: TransportContext
    ) -> IMAPTerminal<T> where Handler.ResultType == T {
        let (_, terminal) = lifetime.registerOperation(of: T.self, parent: operationToken)
        if let base = handler as? BaseIMAPCommandHandler<T> {
            base.settlement = { terminal.complete($0) }
        }
        terminal.observe { promise.completeWith($0) }
        promise.futureResult.whenComplete { terminal.complete($0) }
        return terminal
    }

    func installHandler<T, Handler: IMAPCommandHandler>(
        _ handler: Handler, terminal: IMAPTerminal<T>, context: TransportContext
    ) async throws where Handler.ResultType == T {
        let token = operationToken
        let fence = IMAPTransportWriteGuard { [self] in try validateTransport(context, token: token) }
        let installed: EventLoopFuture<Void> = context.channel.pipeline.addHandlers(
            [handler, fence], position: .before(context.responseBuffer))
        terminal.attachHandlerCleanup(after: installed) {
            context.channel.pipeline.removeHandler(handler, promise: nil)
            context.channel.pipeline.removeHandler(fence, promise: nil)
            context.responseBuffer.hasActiveHandler = false
        }
        try await installed.get()
        try validateTransport(context)
        context.responseBuffer.hasActiveHandler = true
    }
}

/// Runs on the captured event loop at the actual outbound write, including SASL
/// continuations and writes queued by commands after payload preparation.
private final class IMAPTransportWriteGuard: ChannelOutboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias OutboundIn = IMAPClientHandler.OutboundIn
    let validate: () throws -> Void

    init(validate: @escaping () throws -> Void) { self.validate = validate }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        do {
            try validate()
            context.write(data, promise: promise)
        } catch {
            promise?.fail(error)
        }
    }
}
