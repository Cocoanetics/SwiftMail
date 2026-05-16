import Foundation

public extension IMAPNamedConnection {
    /// Search within the selected mailbox.
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

    /// Search within the selected mailbox and preserve server sort order.
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

    /// Search within the selected mailbox, returning structured ESEARCH results (RFC 4731).
    ///
    /// Uses ESEARCH when the server supports it; falls back to a plain SEARCH otherwise.
    /// Pass `partialRange` to request paged results (PARTIAL, RFC 5267) — when set and ESEARCH is
    /// available, `PARTIAL` is used instead of `ALL` and results appear in
    /// ``ExtendedSearchResult/partial``.
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
