import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Search Commands

public extension IMAPServer {
    /**
     Searches for messages matching the given criteria.

     This method performs a search in the selected mailbox using the provided criteria.
     Common search criteria include:
     - Text content (in subject, body, etc.)
     - Date ranges (before, on, since)
     - Flags (seen, answered, flagged, etc.)
     - Size ranges

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
     - identifierSet: Optional set of message identifiers to search within. If nil, searches all messages.
     - criteria: The search criteria to apply. Multiple criteria are combined with AND logic.
     - Returns: A set of message identifiers matching all the search criteria
     - Throws:
     - `IMAPError.searchFailed` if the search operation fails
     - `IMAPError.connectionFailed` if not connected
     - Note: Logs search operations at debug level with criteria count and results count
     */
    @available(
        *,
        deprecated,
        message: "Use extendedSearch(...) for structured results or search(..., sortCriteria:) for ordered results."
    )
    func search<T: MessageIdentifier>(
        identifierSet: MessageIdentifierSet<T>? = nil,
        criteria: [SearchCriteria],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) async throws -> MessageIdentifierSet<T> {
        if criteria.contains(where: \.requiresWithin), !capabilities.contains(.within) {
            throw IMAPError.commandNotSupported(
                "WITHIN extension not supported by server (required for OLDER/YOUNGER search)"
            )
        }
        let command = SearchCommand(
            identifierSet: identifierSet,
            criteria: criteria,
            calendar: calendar
        )
        return try await executeCommand(command)
    }

    /// Search the selected mailbox and preserve server sort order.
    func search<T: MessageIdentifier>(
        identifierSet: MessageIdentifierSet<T>? = nil,
        criteria: [SearchCriteria],
        sortCriteria: [SortCriterion],
        sortCharset: String = "UTF-8",
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) async throws -> [T] {
        let result = try await extendedSearch(
            identifierSet: identifierSet,
            criteria: criteria,
            sortCriteria: sortCriteria,
            sortCharset: sortCharset,
            calendar: calendar
        )

        if let ordered = result.ordered {
            return ordered
        }

        if let partial = result.partial {
            return partial.results.toArray()
        }

        return result.all?.toArray() ?? []
    }

    /**
     Search the selected mailbox and return structured ESEARCH results (RFC 4731).

     Uses the ESEARCH extension when the server advertises it, and falls back
     to a plain SEARCH response otherwise.  The returned ``ExtendedSearchResult``
     always contains at minimum the `count` and `all` fields when matches exist.

     The generic type T determines the identifier type:
     - Use `SequenceNumber` for temporary message numbers that may change
     - Use `UID` for permanent message identifiers that remain stable

     - Parameters:
       - identifierSet: Optional set of message identifiers to search within. If nil, searches all messages.
       - criteria: The search criteria to apply. Multiple criteria are combined with AND logic.
       - calendar: The calendar used for date-to-day conversions.
       - partialRange: Optional window for paged results (PARTIAL, RFC 5267). When provided and ESEARCH
         is available, `PARTIAL` is requested instead of `ALL`, and results appear in
         ``ExtendedSearchResult/partial`` rather than ``ExtendedSearchResult/all``. Ignored when the
         server does not advertise ESEARCH.
     - Returns: An ``ExtendedSearchResult`` containing COUNT, MIN, MAX and either ALL or PARTIAL when available.
     - Throws:
       - `IMAPError.commandFailed` if the search operation fails
       - `IMAPError.connectionFailed` if not connected
     */
    func extendedSearch<T: MessageIdentifier>(
        identifierSet: MessageIdentifierSet<T>? = nil,
        criteria: [SearchCriteria],
        sortCriteria: [SortCriterion] = [],
        sortCharset: String = "UTF-8",
        calendar: Calendar = Calendar(identifier: .gregorian),
        partialRange: PartialRange? = nil
    ) async throws -> ExtendedSearchResult<T> {
        if criteria.contains(where: \.requiresWithin), !capabilities.contains(.within) {
            throw IMAPError.commandNotSupported(
                "WITHIN extension not supported by server (required for OLDER/YOUNGER search)"
            )
        }
        let useSort = capabilities.supportsSort(criteria: sortCriteria)
        if !sortCriteria.isEmpty, !useSort {
            if sortCriteria.contains(where: \.requiresDisplaySortCapability) {
                throw IMAPError.commandNotSupported("DISPLAY sort requires SORT=DISPLAY capability")
            }
            throw IMAPError.commandNotSupported("SORT command not supported by server")
        }
        let useEsearch = capabilities.contains(.extendedSearch) && (!useSort || partialRange != nil)
        let command = ExtendedSearchCommand<T>(
            identifierSet: identifierSet,
            criteria: criteria,
            sortCriteria: sortCriteria,
            sortCharset: sortCharset,
            calendar: calendar,
            useSort: useSort,
            useEsearch: useEsearch,
            partialRange: partialRange
        )
        return try await executeCommand(command)
    }
}
