// MoveHandler.swift
// Handler for IMAP MOVE command

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// Handler for IMAP MOVE command.
///
/// Extracts the `COPYUID` response code from the tagged OK when the server includes one
/// (RFC 6851 §3.3). Returns `nil` when the server omits `COPYUID`.
final class MoveHandler: BaseIMAPCommandHandler<CopyUID?>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = CopyUID?

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)

        do {
            succeedWithResult(try extractCopyUID(from: response))
        } catch {
            failWithError(error)
        }
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed("Move failed: \(String(describing: response.state))"))
    }
}

private extension MoveHandler {
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
