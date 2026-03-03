import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// Handler for IMAP ESEARCH commands (RFC 4731).
///
/// Collects either an `* ESEARCH …` response (when the server supports ESEARCH)
/// or a plain `* SEARCH …` response (fallback), and converts both into an
/// ``ExtendedSearchResult``.
///
/// The generic parameter T specifies the MessageIdentifier type (UID or SequenceNumber).
final class ExtendedSearchHandler<T: MessageIdentifier>: BaseIMAPCommandHandler<ExtendedSearchResult<T>>, IMAPCommandHandler, @unchecked Sendable {
    typealias ResultType = ExtendedSearchResult<T>
    typealias InboundIn = Response
    typealias InboundOut = Never

    // Accumulated results from a plain SEARCH response (fallback path).
    private var fallbackIdentifiers: [T] = []

    // Results accumulated from an ESEARCH response.
    private var esearchCount: Int?
    private var esearchMin: T?
    private var esearchMax: T?
    private var esearchAll: MessageIdentifierSet<T>?
    private var receivedEsearch = false

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)

        // Check for untagged BAD/NO
        if case let .untagged(untagged) = response,
           case let .conditionalState(status) = untagged {
            switch status {
            case .bad(let responseText):
                failWithError(IMAPError.commandFailed("Extended search failed: BAD \(responseText.text)"))
                return true
            case .no(let responseText):
                failWithError(IMAPError.commandFailed("Extended search failed: NO \(responseText.text)"))
                return true
            default:
                break
            }
        }

        // ESEARCH response (RFC 4731)
        if case let .untagged(untagged) = response,
           case let .mailboxData(mailboxData) = untagged,
           case let .extendedSearch(esearchResponse) = mailboxData {
            receivedEsearch = true

            for datum in esearchResponse.returnData {
                switch datum {
                case .min(let nioId):
                    esearchMin = T(UInt32(nioId))
                case .max(let nioId):
                    esearchMax = T(UInt32(nioId))
                case .all(let lastCommandSet):
                    if case .set(let nioSet) = lastCommandSet {
                        esearchAll = convertNIOSet(nioSet.set)
                    }
                case .count(let c):
                    esearchCount = c
                default:
                    break
                }
            }
        }

        // Plain SEARCH response (fallback when ESEARCH is not used)
        if case let .untagged(untagged) = response,
           case let .mailboxData(mailboxData) = untagged,
           case let .search(ids, _) = mailboxData {
            let converted = ids.map { T(UInt32($0)) }
            fallbackIdentifiers.append(contentsOf: converted)
        }

        return handled
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)

        let result: ExtendedSearchResult<T>

        if receivedEsearch {
            result = ExtendedSearchResult<T>(
                count: esearchCount,
                min: esearchMin,
                max: esearchMax,
                all: esearchAll
            )
        } else {
            // Fallback: synthesise from plain SEARCH results
            var identifierSet = MessageIdentifierSet<T>()
            for id in fallbackIdentifiers {
                identifierSet.insert(id)
            }
            let count = fallbackIdentifiers.count
            result = ExtendedSearchResult<T>(
                count: count,
                min: fallbackIdentifiers.min(),
                max: fallbackIdentifiers.max(),
                all: identifierSet.isEmpty ? nil : identifierSet
            )
        }

        succeedWithResult(result)
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        switch response.state {
        case .bad(let responseText):
            failWithError(IMAPError.commandFailed("Extended search failed: BAD \(responseText.text)"))
        case .no(let responseText):
            failWithError(IMAPError.commandFailed("Extended search failed: NO \(responseText.text)"))
        default:
            failWithError(IMAPError.commandFailed("Extended search failed: \(String(describing: response.state))"))
        }
    }

    // MARK: - Private helpers

    /// Convert a NIOIMAPCore ``MessageIdentifierSet<UnknownMessageIdentifier>`` to a SwiftMail ``MessageIdentifierSet<T>``.
    private func convertNIOSet(_ source: NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.UnknownMessageIdentifier>) -> MessageIdentifierSet<T> {
        var result = MessageIdentifierSet<T>()
        for nioRange in source.ranges {
            let lower = T(UInt32(nioRange.range.lowerBound))
            let upper = T(UInt32(nioRange.range.upperBound))
            result.insert(range: lower...upper)
        }
        return result
    }
}
