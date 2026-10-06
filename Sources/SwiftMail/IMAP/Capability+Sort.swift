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
        // The RETURN form also carries COUNT/MIN/MAX, which need ESEARCH itself. A server without it
        // gets a plain SEARCH/SORT, which always works.
        let esearch = self.contains(.extendedSearch)
        let supportedRange = esearch && supportsPartial ? partialRange : nil
        let useEsearch = esearch && (!useSort || supportedRange != nil)
        return (useEsearch, supportedRange)
    }
}
