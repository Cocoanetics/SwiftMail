import Foundation
import NIO
import NIOIMAPCore

/// Handles tagged responses for APPEND operations.
final class AppendHandler: BaseIMAPCommandHandler<AppendResult>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = AppendResult
    typealias InboundIn = Response
    typealias InboundOut = Never

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        // Preserve CLIENTBUG warnings.
        super.handleTaggedOKResponse(response)

        let result = extractAppendResult(from: response)
        succeedWithResult(result)
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.commandFailed(String(describing: response.state)))
    }
}

private extension AppendHandler {
    func extractAppendResult(from response: TaggedResponse) -> AppendResult {
        guard case .ok(let text) = response.state else {
            return AppendResult(uidValidity: nil, uids: [])
        }

        guard let code = text.code else {
            return AppendResult(uidValidity: nil, uids: [])
        }

        switch code {
        case .uidAppend(let data):
            let validity = UIDValidity(nio: data.uidValidity)
            let assigned = data.uids.set.map { UID(nio: $0) }
            return AppendResult(uidValidity: validity, uids: assigned)
        default:
            return AppendResult(uidValidity: nil, uids: [])
        }
    }
}
