import Foundation
import Testing
@testable import SwiftMail

/// Accepted and rejected shapes of `FetchMessageInfoHandler.parseEnvelopeDate(_:)`, and its
/// cost for a large mailbox (#342).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct EnvelopeDateParsingTests {
    /// Every shape the envelope date parser accepts, with the UTC instant it must produce.
    static let acceptedShapes: [(String, DateComponents)] = [
        ("Wed, 29 Apr 2026 02:14:25 +0000", utc(2026, 4, 29, 2, 14, 25)),       // RFC 5322
        ("Mon, 05 Jan 2026 10:00:00 +0200", utc(2026, 1, 5, 8, 0, 0)),
        ("Mon, 5 Jan 2026 10:00:00 -0130", utc(2026, 1, 5, 11, 30, 0)),         // single-digit day
        ("5 Jan 2026 10:00:00 +0000", utc(2026, 1, 5, 10, 0, 0)),               // no weekday
        ("05 Jan 2026 10:00:00 +0000", utc(2026, 1, 5, 10, 0, 0)),
        // The four-digit-year format is tried first and takes "26" literally; kept as-is.
        ("Mon, 05 Jan 26 10:00:00 +0000", utc(26, 1, 5, 10, 0, 0)),             // two-digit year
        ("Mon, 05 Jan 2026 10:00:00", utc(2026, 1, 5, 10, 0, 0)),               // no timezone
        ("Mon, 5 Jan 2026 10:00:00", utc(2026, 1, 5, 10, 0, 0)),
        ("5 Jan 2026 10:00:00", utc(2026, 1, 5, 10, 0, 0)),
        ("05 Jan 2026 10:00:00", utc(2026, 1, 5, 10, 0, 0)),
        ("mon, 05 jan 2026 10:00:00 +0000", utc(2026, 1, 5, 10, 0, 0)),         // lowercase
        ("29 apr 2026 02:14:25", utc(2026, 4, 29, 2, 14, 25)),
        ("Wed, 31 Jan 2018 15:02:22 EST", utc(2018, 1, 31, 20, 2, 22)),         // named zones
        ("Wed, 31 Jan 2018 15:02:22 pdt", utc(2018, 1, 31, 22, 2, 22)),
        ("Wed, 31 Jan 2018 15:02:22 UT", utc(2018, 1, 31, 15, 2, 22)),
        ("Wed, 29 Apr 2026 02:14:25 +0000 (UTC)", utc(2026, 4, 29, 2, 14, 25)), // comments
        ("Wed, 29 Apr 2026 02:14:25 -0700 (PDT) ", utc(2026, 4, 29, 9, 14, 25)),
        ("Wed, 31 Jan 2018 15:02:22 EST (Eastern)", utc(2018, 1, 31, 20, 2, 22))
    ]

    @Test(arguments: acceptedShapes)
    func acceptsShape(_ input: String, _ expected: DateComponents) {
        let date = Calendar(identifier: .gregorian).date(from: expected)
        #expect(FetchMessageInfoHandler.parseEnvelopeDate(input) == date)
    }

    @Test(arguments: [
        "",
        "not a date",
        "(UTC)",
        "Wed, 99 Apr 2026 02:14:25 +0000",
        "Wed, 30 Feb 2026 02:14:25 +0000",
        "Wed, 29 Foo 2026 02:14:25 +0000",
        "Wed, 29 Apr 2026 25:14:25 +0000",
        "Wed, 29 Apr 2026 02:61:25 +0000",
        "99 apr 2026 02:14:25 (UTC)",
        "Wed, 31 Jan 2018 15:02:22 ZZT"
    ])
    func rejectsInvalidShape(_ input: String) {
        #expect(FetchMessageInfoHandler.parseEnvelopeDate(input) == nil)
    }

    @Test
    func largeBatchDoesNotBuildAFormatterPerDate() {
        // Issue #342: parsing every envelope date of a large mailbox must not build
        // a DateFormatter per message. The bound is relative to doing exactly that
        // (one fresh formatter per date, one parse each), so it holds on fast and
        // slow machines alike. The two are measured in alternating rounds and the
        // fastest round of each is compared, so load from tests running in parallel
        // does not skew one side. The old parser was no faster than the reference;
        // reusing formatters is about three times faster.
        let bases = (0..<2_000).map { index in
            let day = index % 28 + 1
            return "Wed, \(day < 10 ? "0" : "")\(day) Apr 2026 02:14:\(index % 50 + 10) +0000"
        }
        let inputs = bases.enumerated().map { index, base in
            index.isMultiple(of: 2) ? base : base + " (UTC)"
        }

        let clock = ContinuousClock()
        var parsed = 0
        var referenceParsed = 0
        var fastestParse = Duration.seconds(Int64.max)
        var fastestPerCallFormatter = Duration.seconds(Int64.max)

        for _ in 0..<5 {
            let elapsed = clock.measure {
                for input in inputs where FetchMessageInfoHandler.parseEnvelopeDate(input) != nil {
                    parsed += 1
                }
            }
            fastestParse = min(fastestParse, elapsed)

            let perCallFormatter = clock.measure {
                for base in bases {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                    if formatter.date(from: base) != nil {
                        referenceParsed += 1
                    }
                }
            }
            fastestPerCallFormatter = min(fastestPerCallFormatter, perCallFormatter)
        }

        #expect(parsed == inputs.count * 5)
        #expect(referenceParsed == bases.count * 5)
        #expect(
            fastestParse * 3 < fastestPerCallFormatter * 2,
            "parsing 2,000 envelope dates took \(fastestParse); a formatter per date took \(fastestPerCallFormatter)"
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func utc(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> DateComponents {
        DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
    }
}
