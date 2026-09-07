// FetchPartHandler.swift
// A specialized handler for IMAP fetch part operations

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

enum PartialFetchIdentifier: Sendable {
    case uid(UInt32)
    case sequenceNumber(UInt32)
    case latestUID
    case latestSequenceNumber
}

struct PartialFetchRequest: Sendable {
    let identifier: PartialFetchIdentifier
    let section: SectionSpecifier
    let offset: Int
    let count: Int
}

/// Handler for full and validated partial IMAP FETCH PART commands.
final class FetchPartHandler: BaseIMAPCommandHandler<Data>, IMAPCommandHandler, @unchecked Sendable {
    private enum IdentityMatch {
        case pending
        case matches
        case unrelated
    }

    private let partialRequest: PartialFetchRequest?
    private var partData = Data()
    private var didFinishPart = false

    // Partial-response state. A UID may follow the literal, so validation is
    // finalized only when the current FETCH group finishes.
    private var currentSequence: UInt32?
    private var currentUID: UInt32?
    private var currentIncludesExpectedUID = false
    private var currentData = Data()
    private var currentDeclaredCount: Int?
    private var currentBodyCount = 0
    private var currentError: PartialFetchError?
    private var collectingBody = false
    private var matchedCount = 0
    private var sawBodyGroup = false
    private var sawMatchingGroup = false
    private var validationError: PartialFetchError?

    override init(commandTag: String, promise: EventLoopPromise<Data>) {
        self.partialRequest = nil
        super.init(commandTag: commandTag, promise: promise)
    }

    init(
        commandTag: String,
        promise: EventLoopPromise<Data>,
        partialRequest: PartialFetchRequest
    ) {
        self.partialRequest = partialRequest
        super.init(commandTag: commandTag, promise: promise)
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)
        guard partialRequest != nil else {
            succeedWithResult(lock.withLock { partData })
            return
        }
        let result: Result<Data, PartialFetchError> = lock.withLock {
            if let validationError { return .failure(validationError) }
            guard matchedCount == 1 else {
                if sawMatchingGroup || sawBodyGroup {
                    return .failure(.invalidResponse("missing or ambiguous requested body"))
                }
                return .failure(.messageNotFound)
            }
            return .success(partData)
        }
        switch result {
            case .success(let data): succeedWithResult(data)
            case .failure(let error): failWithError(error)
        }
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        if partialRequest != nil, case .bad = response.state {
            failWithError(PartialFetchError.serverRejected)
        } else {
            failWithError(IMAPError.fetchFailed(String(describing: response.state)))
        }
    }

    override func processResponse(_ response: Response) -> Bool {
        guard case .fetch(let fetchResponse) = response else {
            return super.processResponse(response)
        }
        if partialRequest != nil {
            return lock.withLock {
                processPartialFetchResponse(fetchResponse)
                return isCompleted
            }
        } else {
            _ = super.processResponse(response)
            processFullFetchResponse(fetchResponse)
        }
        return false
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        guard partialRequest != nil else { return super.handleUntaggedResponse(response) }
        // Keep only connection-termination responses. Retaining streaming FETCH
        // events in the base history would defeat the requested byte bound.
        if case .untagged(.conditionalState(.bye)) = response {
            return super.handleUntaggedResponse(response)
        }
        if case .fatal = response { return super.handleUntaggedResponse(response) }
        return false
    }

    private func processFullFetchResponse(_ response: FetchResponse) {
        guard !didFinishPart else { return }
        switch response {
            case .start:
                lock.withLock { partData.removeAll(keepingCapacity: true) }
            case .streamingBytes(let data):
                lock.withLock { partData.append(contentsOf: data.readableBytesView) }
            case .finish:
                didFinishPart = true
            default:
                break
        }
    }

    private func processPartialFetchResponse(_ response: FetchResponse) {
        guard let request = partialRequest else { return }
        switch response {
            case .start(let sequence):
                resetCurrentGroup()
                currentSequence = sequence.rawValue
            case .startUID(let uid):
                resetCurrentGroup()
                recordUID(uid.rawValue, request: request)
            case .simpleAttribute(let attribute):
                processPartialAttribute(attribute, request: request)
            case .streamingBegin(let kind, let count):
                beginBody(kind: kind, declaredCount: count, request: request)
            case .streamingBytes(let bytes):
                appendPartialBytes(bytes, request: request)
            case .streamingEnd:
                collectingBody = false
            case .finish:
                finishCurrentGroup(request: request)
                resetCurrentGroup()
        }
    }

    private func processPartialAttribute(_ attribute: MessageAttribute, request: PartialFetchRequest) {
        switch attribute {
            case .uid(let uid):
                recordUID(uid.rawValue, request: request)
            case .nilBody(let kind):
                if beginBody(kind: kind, declaredCount: 0, request: request) {
                    currentError = .invalidResponse("requested body section was NIL")
                }
            default:
                break
        }
    }

    private func recordUID(_ uid: UInt32, request: PartialFetchRequest) {
        if case .uid(let expected) = request.identifier, uid == expected {
            currentIncludesExpectedUID = true
        }
        guard let currentUID else {
            self.currentUID = uid
            return
        }
        if currentUID != uid {
            currentError = .invalidResponse("conflicting UID attributes")
        }
    }

    private func appendPartialBytes(_ bytes: ByteBuffer, request: PartialFetchRequest) {
        guard collectingBody else { return }
        guard bytes.readableBytes <= request.count - currentData.count else {
            rejectResponse("literal exceeded requested count", request: request)
            return
        }
        currentData.append(contentsOf: bytes.readableBytesView)
    }

    @discardableResult
    private func beginBody(
        kind: StreamingKind,
        declaredCount: Int,
        request: PartialFetchRequest
    ) -> Bool {
        guard identityMatch(request.identifier) != .unrelated else { return false }
        currentBodyCount += 1
        guard currentBodyCount == 1 else {
            rejectResponse("multiple body literals", request: request)
            return true
        }
        guard case .body(let section, let offset) = kind,
              section == request.section,
              offset == request.offset else {
            rejectResponse("section or partial origin did not match request", request: request)
            return true
        }
        guard declaredCount <= request.count else {
            rejectResponse("literal exceeded requested count", request: request)
            return true
        }
        currentDeclaredCount = declaredCount
        collectingBody = true
        return true
    }

    private func rejectResponse(_ reason: String, request: PartialFetchRequest) {
        let error = PartialFetchError.invalidResponse(reason)
        currentError = error
        collectingBody = false
        if identityMatch(request.identifier) == .matches {
            failWithError(error)
        }
    }

    private func finishCurrentGroup(request: PartialFetchRequest) {
        guard identifierMatches(request.identifier) else { return }
        sawMatchingGroup = true
        if let currentError, currentBodyCount == 0 {
            validationError = currentError
        }
        guard currentBodyCount > 0 else { return }
        sawBodyGroup = true
        matchedCount += 1
        guard matchedCount == 1 else {
            validationError = .invalidResponse("multiple matching FETCH responses")
            return
        }
        if currentError == nil, currentDeclaredCount != currentData.count {
            currentError = .invalidResponse("literal length did not match declaration")
        }
        partData = currentData
        validationError = currentError
    }

    private func identifierMatches(_ expected: PartialFetchIdentifier) -> Bool {
        identityMatch(expected) == .matches
    }

    private func identityMatch(_ expected: PartialFetchIdentifier) -> IdentityMatch {
        switch expected {
            case .uid(let uid):
                guard currentUID != nil else { return .pending }
                return currentIncludesExpectedUID || currentUID == uid ? .matches : .unrelated
            case .sequenceNumber(let sequence):
                guard let currentSequence else { return .pending }
                return currentSequence == sequence ? .matches : .unrelated
            case .latestUID:
                return currentUID == nil ? .pending : .matches
            case .latestSequenceNumber:
                return currentSequence == nil ? .pending : .matches
        }
    }

    private func resetCurrentGroup() {
        currentSequence = nil
        currentUID = nil
        currentIncludesExpectedUID = false
        currentData.removeAll(keepingCapacity: true)
        currentDeclaredCount = nil
        currentBodyCount = 0
        currentError = nil
        collectingBody = false
    }
}
