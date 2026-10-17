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
    /// `SEARCH RETURN (...)` needs ESEARCH (RFC 4731); `SORT RETURN (...)` needs ESORT (RFC 5267)
    /// instead, and either may be advertised without the other. The `PARTIAL` return option is a separate
    /// capability: RFC 9394 advertises it as `PARTIAL`, while RFC 5267 servers advertise
    /// `CONTEXT=SEARCH`; a sorted search needs `CONTEXT=SORT`, as standalone `PARTIAL` does not
    /// cover SORT. Gmail and iCloud advertise
    /// ESEARCH with none of these and reject a command containing it, so the window is dropped
    /// and `ALL` requested instead. Callers then page client-side from
    /// ``ExtendedSearchResult/all`` (or ``ExtendedSearchResult/ordered`` for a sorted search,
    /// which falls back to a plain `SORT`).
    func extendedSearchPlan(
        useSort: Bool,
        partialRange: PartialRange?
    ) -> (useEsearch: Bool, partialRange: PartialRange?) {
        // Standalone PARTIAL (RFC 9394) extends SEARCH only; a sorted window needs CONTEXT=SORT (RFC 5267).
        let supportsPartial = useSort
            ? self.contains(.context(.sort))
            : (self.contains(.partial) || self.contains(.context(.search)))
        // The RETURN form also carries COUNT/MIN/MAX, which need ESEARCH for SEARCH and ESORT for
        // SORT. A server without it gets a plain SEARCH/SORT, which always works.
        let returnForm = self.contains(useSort ? .esort : .extendedSearch)
        let supportedRange = returnForm && supportsPartial ? partialRange : nil
        let useEsearch = returnForm && (!useSort || supportedRange != nil)
        return (useEsearch, supportedRange)
    }
}
