import Testing
import NIOIMAPCore
@testable import SwiftMail

struct ExtendedSearchPlanTests {
    private let range = PartialRange.first(1...100)

    @Test
    func esearchWithoutPartialDropsTheWindow() {
        // Gmail / iCloud: ESEARCH advertised, PARTIAL not — RETURN (... PARTIAL ...) is a BAD.
        let caps: Set<Capability> = [.extendedSearch]
        let plan = caps.extendedSearchPlan(useSort: false, partialRange: range)
        #expect(plan.useEsearch)
        #expect(plan.partialRange == nil)
    }

    @Test
    func esearchWithPartialKeepsTheWindow() {
        let caps: Set<Capability> = [.extendedSearch, .partial]
        let plan = caps.extendedSearchPlan(useSort: false, partialRange: range)
        #expect(plan.useEsearch)
        #expect(plan.partialRange != nil)
    }

    @Test
    func noEsearchMeansPlainSearch() {
        let plan = Set<Capability>().extendedSearchPlan(useSort: false, partialRange: range)
        #expect(!plan.useEsearch)
        #expect(plan.partialRange == nil)
    }

    @Test
    func sortWithoutPartialFallsBackToPlainSort() {
        let caps: Set<Capability> = [.extendedSearch]
        let plan = caps.extendedSearchPlan(useSort: true, partialRange: range)
        #expect(!plan.useEsearch)
    }

    @Test
    func rfc5267ContextCapabilityKeepsTheWindow() {
        // Older servers signal PARTIAL via CONTEXT=SEARCH / CONTEXT=SORT rather than PARTIAL.
        let search: Set<Capability> = [.extendedSearch, .context(.search)]
        #expect(search.extendedSearchPlan(useSort: false, partialRange: range).partialRange != nil)

        let sort: Set<Capability> = [.extendedSearch, .context(.sort)]
        let sorted = sort.extendedSearchPlan(useSort: true, partialRange: range)
        #expect(sorted.useEsearch)
        #expect(sorted.partialRange != nil)

        // The context must match the command: CONTEXT=SORT does not cover a plain search.
        #expect(sort.extendedSearchPlan(useSort: false, partialRange: range).partialRange == nil)
    }
}
