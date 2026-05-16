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
final class ExtendedSearchHandler<T: MessageIdentifier>:
    BaseIMAPCommandHandler<ExtendedSearchResult<T>>,
    IMAPCommandHandler,
    @unchecked Sendable {
    typealias ResultType = ExtendedSearchResult<T>
    typealias InboundIn = Response
    typealias InboundOut = Never

    // Accumulated results from a plain SEARCH response (fallback path).
    private var fallbackIdentifiers: [T] = []
    private var fallbackOrderedIdentifiers: [T] = []

    // Results accumulated from an ESEARCH response.
    private var esearchCount: Int?
    private var esearchMin: T?
    private var esearchMax: T?
    private var esearchAll: MessageIdentifierSet<T>?
    private var esearchPartial: ExtendedSearchResult<T>.PartialResult?
    private var receivedEsearch = false

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)

        guard case let .untagged(untagged) = response else {
            return handled
        }

        if case let .conditionalState(status) = untagged,
           let failure = checkUntaggedFailure(status) {
            failWithError(failure)
            return true
        }

        if case let .mailboxData(mailboxData) = untagged {
            processMailboxData(mailboxData)
        }

        return handled
    }

    private func checkUntaggedFailure(_ status: UntaggedStatus) -> IMAPError? {
        switch status {
            case let .bad(responseText):
                IMAPError.commandFailed("Extended search failed: BAD \(responseText.text)")
            case let .no(responseText):
                IMAPError.commandFailed("Extended search failed: NO \(responseText.text)")
            default:
                nil
        }
    }

    private func processMailboxData(_ mailboxData: MailboxData) {
        switch mailboxData {
            case let .extendedSearch(esearchResponse):
                // ESEARCH response (RFC 4731)
                receivedEsearch = true
                for datum in esearchResponse.returnData {
                    processESearchDatum(datum)
                }
            case let .search(ids, _):
                // Plain SEARCH response (fallback when ESEARCH is not used)
                appendFallback(ids: ids)
            case let .sort(ids, _):
                appendFallback(ids: ids)
            default:
                break
        }
    }

    private func processESearchDatum(_ datum: SearchReturnData) {
        switch datum {
            case let .min(nioId):
                esearchMin = T(UInt32(nioId))
            case let .max(nioId):
                esearchMax = T(UInt32(nioId))
            case let .all(lastCommandSet):
                if case let .set(nioSet) = lastCommandSet {
                    esearchAll = convertNIOSet(nioSet.set)
                }
            case let .count(count):
                esearchCount = count
            case let .partial(range, nioSet):
                let ids = convertNIOSet(nioSet)
                esearchPartial = ExtendedSearchResult<T>.PartialResult(range: range, results: ids)
            default:
                break
        }
    }

    private func appendFallback(ids: [NIOIMAPCore.UnknownMessageIdentifier]) {
        let converted = ids.map { T(UInt32($0)) }
        fallbackIdentifiers.append(contentsOf: converted)
        fallbackOrderedIdentifiers.append(contentsOf: converted)
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)

        let result: ExtendedSearchResult<T>

        if receivedEsearch {
            result = ExtendedSearchResult<T>(
                count: esearchCount,
                min: esearchMin,
                max: esearchMax,
                all: esearchAll,
                partial: esearchPartial
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
                all: identifierSet.isEmpty ? nil : identifierSet,
                ordered: fallbackOrderedIdentifiers.isEmpty ? nil : fallbackOrderedIdentifiers
            )
        }

        succeedWithResult(result)
    }

    override func handleTaggedErrorResponse(_ response: TaggedResponse) {
        switch response.state {
            case let .bad(responseText):
                failWithError(IMAPError.commandFailed("Extended search failed: BAD \(responseText.text)"))
            case let .no(responseText):
                failWithError(IMAPError.commandFailed("Extended search failed: NO \(responseText.text)"))
            default:
                failWithError(IMAPError.commandFailed("Extended search failed: \(String(describing: response.state))"))
        }
    }

    // MARK: - Private helpers

    /// Convert a NIOIMAPCore ``MessageIdentifierSet<UnknownMessageIdentifier>`` to a SwiftMail
    /// ``MessageIdentifierSet<T>``.
    private func convertNIOSet(
        _ source: NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.UnknownMessageIdentifier>
    ) -> MessageIdentifierSet<T> {
        var result = MessageIdentifierSet<T>()
        for nioRange in source.ranges {
            let lower = T(UInt32(nioRange.range.lowerBound))
            let upper = T(UInt32(nioRange.range.upperBound))
            result.insert(range: lower ... upper)
        }
        return result
    }
}
