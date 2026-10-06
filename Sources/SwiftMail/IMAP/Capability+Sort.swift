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
    /// `RETURN (...)` needs ESEARCH (RFC 4731). The `PARTIAL` return option (RFC 9394) is a
    /// separate capability: Gmail and iCloud advertise ESEARCH without it and reject a command
    /// containing it, so the window is dropped and `ALL` requested instead. Callers then page
    /// client-side from ``ExtendedSearchResult/all``.
    func extendedSearchPlan(
        useSort: Bool,
        partialRange: PartialRange?
    ) -> (useEsearch: Bool, partialRange: PartialRange?) {
        let supportedRange = self.contains(.partial) ? partialRange : nil
        let useEsearch = self.contains(.extendedSearch) && (!useSort || supportedRange != nil)
        return (useEsearch, supportedRange)
    }
}
