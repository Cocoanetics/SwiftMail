// MoveHandler.swift
// Handler for IMAP MOVE command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP MOVE command.
///
/// Retains a valid `COPYUID` from either the untagged `OK` recommended before EXPUNGE
/// responses or the final tagged `OK` (RFC 6851 §§3.3, 4.3). Returns `nil` only when
/// the successful response contains no `COPYUID` evidence.
final class MoveHandler:
    BaseIMAPCommandHandler<CopyUID?>,
    IMAPCommandHandler,
    @unchecked Sendable {
    typealias ResultType = CopyUID?

    private var retainedCopyUID: CopyUID?
    private var malformedCopyUIDReason: String?

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if super.handleUntaggedResponse(response) {
            return true
        }

        guard case .untagged(.conditionalState(.ok(let text))) = response,
              let code = text.code,
              case .uidCopy(let data) = code
        else {
            return false
        }

        recordUntaggedCopyUID(data)
        return false
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)

        var taggedCopyUID: CopyUID?
        var taggedMalformedReason: String?
        do {
            taggedCopyUID = try extractCopyUID(from: response)
        } catch {
            taggedMalformedReason = String(describing: error)
        }

        let resolution = lock.withLock { () -> (copyUID: CopyUID?, malformedReason: String?) in
            if let reason = malformedCopyUIDReason ?? taggedMalformedReason {
                return (nil, reason)
            }
            if let retainedCopyUID, let taggedCopyUID,
               !retainedCopyUID.isEquivalent(to: taggedCopyUID) {
                return (nil, "Conflicting COPYUID mappings in untagged and tagged OK responses")
            }
            return (taggedCopyUID ?? retainedCopyUID, nil)
        }

        if let reason = resolution.malformedReason {
            failWithError(IMAPError.malformedCopyUIDAfterTaggedOK(reason))
        } else {
            succeedWithResult(resolution.copyUID)
        }
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        let reason = String(describing: response.state)
        let partialCopyUID = lock.withLock {
            malformedCopyUIDReason == nil ? retainedCopyUID : nil
        }
        if let partialCopyUID {
            failWithError(
                IMAPError.moveFailedAfterPartialCompletion(
                    copyUID: partialCopyUID,
                    reason: reason
                )
            )
        } else {
            failWithError(IMAPError.moveFailedAfterPossiblePartialCompletion(reason))
        }
    }

}

private extension MoveHandler {
    func recordUntaggedCopyUID(_ data: NIOIMAPCore.ResponseCodeCopy) {
        do {
            let copyUID = try CopyUID(nio: data)
            lock.withLock {
                if let retainedCopyUID, !retainedCopyUID.isEquivalent(to: copyUID) {
                    malformedCopyUIDReason =
                        "Conflicting COPYUID mappings in multiple untagged OK responses"
                } else if retainedCopyUID == nil {
                    retainedCopyUID = copyUID
                }
            }
        } catch {
            lock.withLock {
                if malformedCopyUIDReason == nil {
                    malformedCopyUIDReason = String(describing: error)
                }
            }
        }
    }

    func extractCopyUID(from response: TaggedResponse) throws -> CopyUID? {
        guard case .ok(let text) = response.state,
              let code = text.code,
              case .uidCopy(let data) = code
        else {
            return nil
        }
        return try CopyUID(nio: data)
    }
}
