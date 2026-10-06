import NIOIMAPCore

extension Set where Element == NIOIMAPCore.Capability {
    func supportsSort(criteria: [SortCriterion]) -> Bool {
        guard !criteria.isEmpty else { return false }

        if criteria.contains(where: \.requiresDisplaySortCapability) {
            return self.contains(.sort(.display))
        }

        return self.contains(.sort(nil)) || self.contains(.sort(.display))
    }

    /// Decides how an extended search is phrased for this server.
    ///
    /// `RETURN (...)` needs ESEARCH (RFC 4731). The `PARTIAL` return option is a separate
    /// capability: RFC 9394 advertises it as `PARTIAL`, while RFC 5267 servers advertise
    /// `CONTEXT=SEARCH` (or `CONTEXT=SORT` for a sorted search). Gmail and iCloud advertise
    /// ESEARCH with none of these and reject a command containing it, so the window is dropped
    /// and `ALL` requested instead. Callers then page client-side from
    /// ``ExtendedSearchResult/all`` (or ``ExtendedSearchResult/ordered`` for a sorted search,
    /// which falls back to a plain `SORT`).
    func extendedSearchPlan(
        useSort: Bool,
        partialRange: PartialRange?
    ) -> (useEsearch: Bool, partialRange: PartialRange?) {
        let context: Capability = useSort ? .context(.sort) : .context(.search)
        let supportsPartial = self.contains(.partial) || self.contains(context)
        let supportedRange = supportsPartial ? partialRange : nil
        // PARTIAL / CONTEXT servers speak ESEARCH by definition, so a supported window is enough;
        // a sorted search without one stays a plain SORT, whose order is kept in `ordered`.
        let useEsearch = supportedRange != nil || (self.contains(.extendedSearch) && !useSort)
        return (useEsearch, supportedRange)
    }
}
