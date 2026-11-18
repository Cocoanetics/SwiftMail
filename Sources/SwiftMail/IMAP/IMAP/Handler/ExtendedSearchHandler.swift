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
    // Whether a plain `* SEARCH` or `* SORT` answer arrived (fallback path).
    private var receivedFallbackAnswer = false

    /// The ESEARCH return options the command sent; empty for a plain SEARCH or SORT.
    ///
    /// RFC 4731 §3.1: a requested COUNT "MUST always be included in the ESEARCH response", and
    /// MIN, MAX and ALL are left out only when nothing matched. RFC 9394 §3.1 returns a requested
    /// PARTIAL always, with NIL for an empty window.
    /// `nil` when the handler was built without its command, so nothing is known to check.
    var requestedOptions: [SearchReturnOption]?
    /// Whether the command was a SORT; `nil` when the handler was built without its command.
    var expectsSort: Bool?

    override func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        guard case .untagged(let untagged) = response else { return handled }

        if case .conditionalState(let status) = untagged, failOnNegativeStatus(status) {
            return true
        }
        if case .mailboxData(let mailboxData) = untagged {
            ingest(mailboxData)
        }
        return handled
    }

    /// Surface BAD/NO into the result promise and stop further processing.
    /// - Returns: `true` if the response was a fatal status (caller should
    ///   short-circuit), `false` otherwise.
    private func failOnNegativeStatus(_ status: UntaggedStatus) -> Bool {
        switch status {
            case .bad(let text):
                failWithError(
                    IMAPError.searchRejected(operation: "Extended search", status: "BAD", responseText: text)
                )
                return true
            case .no(let text):
                failWithError(
                    IMAPError.searchRejected(operation: "Extended search", status: "NO", responseText: text)
                )
                return true
            default:
                return false
        }
    }

    /// Route untagged mailbox data into ESEARCH state or the SEARCH/SORT
    /// fallback buffers.
    private func ingest(_ mailboxData: MailboxData) {
        switch mailboxData {
            case .extendedSearch(let response):
                // An ESEARCH correlated to another command's tag is not this command's answer
                // (RFC 4731 §3.1, RFC 9051 §7.3.4).
                guard response.answers(commandTag: commandTag, identifiers: T.self) else { return }
                receivedEsearch = true
                for datum in response.returnData {
                    ingest(datum)
                }
            case .search(let ids, _), .sort(let ids, _):
                guard acceptsLegacyAnswer(mailboxData, expectsSort: expectsSort) else { return }
                receivedFallbackAnswer = true
                let converted = ids.map { T(UInt32($0)) }
                fallbackIdentifiers.append(contentsOf: converted)
                fallbackOrderedIdentifiers.append(contentsOf: converted)
            default:
                break
        }
    }

    /// Apply one ESEARCH return datum (`MIN`, `MAX`, `ALL`, `COUNT`, `PARTIAL`) to
    /// the accumulated result.
    private func ingest(_ datum: SearchReturnData) {
        switch datum {
            case .min(let nioId):
                esearchMin = T(UInt32(nioId))
            case .max(let nioId):
                esearchMax = T(UInt32(nioId))
            case .all(let lastCommandSet):
                if case .set(let nioSet) = lastCommandSet {
                    esearchAll = MessageIdentifierSet<T>(unknownIdentifiers: nioSet.set)
                }
            case .count(let count):
                esearchCount = count
            case .partial(let range, let nioSet):
                let ids = MessageIdentifierSet<T>(unknownIdentifiers: nioSet)
                esearchPartial = ExtendedSearchResult<T>.PartialResult(range: range, results: ids)
            default:
                break
        }
    }

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)

        if let missing = missingAnswer() {
            failWithError(IMAPError.commandFailed("Extended search failed: \(missing)"))
            return
        }

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
            case .bad(let responseText):
                failWithError(
                    IMAPError.searchRejected(operation: "Extended search", status: "BAD", responseText: responseText)
                )
            case .no(let responseText):
                failWithError(
                    IMAPError.searchRejected(operation: "Extended search", status: "NO", responseText: responseText)
                )
            default:
                failWithError(IMAPError.commandFailed("Extended search failed: \(String(describing: response.state))"))
        }
    }

    // MARK: - Private helpers

    /// Describe what the protocol required but the server left out before its tagged OK, or
    /// `nil` when the answer is complete. A real empty answer stays complete: `* SEARCH` with no
    /// numbers (RFC 3501 §7.2.5), or an ESEARCH with no ALL and `COUNT 0` (RFC 4731 §3.1).
    private func missingAnswer() -> String? {
        if receivedEsearch {
            guard let requested = requestedOptions else { return nil }
            if requested.contains(.count) && esearchCount == nil {
                return "ESEARCH omitted the requested COUNT (RFC 4731 §3.1)"
            }
            if requested.contains(where: \.isPartial) && esearchPartial == nil {
                return "ESEARCH omitted the requested PARTIAL (RFC 9394 §3.1)"
            }
            // A plain SEARCH answered with ESEARCH asked for ALL by default (RFC 9051 §6.4.4).
            let wantsAll = requested.contains(.all) || requested.isEmpty
            // COUNT above zero, MIN or MAX each show that something matched.
            guard (esearchCount ?? 0) > 0 || esearchMin != nil || esearchMax != nil else { return nil }
            let omitted = [
                requested.contains(.min) && esearchMin == nil ? "MIN" : nil,
                requested.contains(.max) && esearchMax == nil ? "MAX" : nil,
                wantsAll && esearchAll == nil ? "ALL" : nil
            ].compactMap { $0 }
            guard omitted.isEmpty else {
                return "ESEARCH reported matches but omitted the requested "
                    + omitted.joined(separator: ", ") + " (RFC 4731 §3.1, RFC 9051 §6.4.4)"
            }
            return nil
        }
        if receivedFallbackAnswer {
            return nil
        }
        return "Search completed with OK but no untagged SEARCH or ESEARCH response "
            + "(RFC 3501 §6.4.4, RFC 4731 §3.1, RFC 9051 §6.4.4)"
    }

}

extension SearchReturnOption {
    var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }
}

extension ExtendedSearchResponse {
    /// Whether this ESEARCH answers the command with `commandTag` that searches for `T`: its TAG
    /// correlator, when present, names that command (RFC 4731 §3.1, RFC 9051 §7.3.4), and it
    /// carries the UID indicator exactly when the command was a UID command. An answer without
    /// the indicator holds sequence numbers, which must never be read as UIDs.
    func answers<T: MessageIdentifier>(commandTag: String?, identifiers _: T.Type) -> Bool {
        guard (kind == .uid) == (T.self == UID.self) else { return false }
        guard let tag = correlator?.tag, let commandTag else { return true }
        return tag == commandTag
    }
}

/// Which untagged answer family a SEARCH or SORT command accepts: `* SORT` answers only SORT and
/// `* SEARCH` answers only SEARCH (RFC 5256 §4, RFC 3501 §7.2.5). `nil` accepts both, for a
/// handler built without its command.
func acceptsLegacyAnswer(_ data: MailboxData, expectsSort: Bool?) -> Bool {
    switch data {
        case .search: return expectsSort != true
        case .sort: return expectsSort != false
        default: return false
    }
}

extension MessageIdentifierSet {
    /// Convert a NIOIMAPCore set of untyped identifiers from a search response.
    init(unknownIdentifiers source: NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.UnknownMessageIdentifier>) {
        self.init()
        insert(unknownIdentifiers: source)
    }

    /// Add a NIOIMAPCore set of untyped identifiers range by range, without expanding it.
    mutating func insert(
        unknownIdentifiers source: NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.UnknownMessageIdentifier>
    ) {
        for nioRange in source.ranges {
            let lower = Identifier(UInt32(nioRange.range.lowerBound))
            let upper = Identifier(UInt32(nioRange.range.upperBound))
            insert(range: lower...upper)
        }
    }
}
