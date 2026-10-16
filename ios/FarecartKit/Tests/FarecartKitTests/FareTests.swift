import Foundation
import Testing
@testable import FarecartKit

private let en = Locale(identifier: "en_US")

@Suite("Fare math")
struct FareTests {
    let calculator = FareCalculator(fares: BundledFallbacks.fares)

    @Test("Full fare when no discounts")
    func fullFare() throws {
        let quote = try #require(calculator.quote(mode: .bus, answers: .none))
        #expect(quote.priceCents == 225)
        #expect(quote.discounted == nil)
        #expect(!quote.hasDiscount)
        #expect(quote.priceText(locale: en) == "$2.25")
    }

    @Test("SNAP household gets the Access fare")
    func accessFare() throws {
        let answers = EligibilityAnswers(householdReceivesSNAP: true)
        let bus = try #require(calculator.quote(mode: .bus, answers: answers))
        let train = try #require(calculator.quote(mode: .train, answers: answers))
        #expect(bus.priceCents == 110)
        #expect(bus.fullPriceText(locale: en) == "$2.25")
        #expect(bus.savingsCents == 115)
        #expect(train.priceCents == 125)
        #expect(bus.discounted?.rider == .reducedAccess)
        #expect(bus.alternatives.isEmpty)
    }

    @Test("Student gets $0.75 on both modes")
    func studentFare() throws {
        let answers = EligibilityAnswers(isK12Student: true)
        let quotes = calculator.quotes(answers: answers)
        #expect(quotes.map(\.mode) == [.bus, .train])
        #expect(quotes.allSatisfy { $0.priceCents == 75 })
        #expect(quotes.first?.priceText(locale: en) == "$0.75")
    }

    @Test("Both answers: Access is primary, student offered as cheaper alternative")
    func bothAnswers() throws {
        let answers = EligibilityAnswers(householdReceivesSNAP: true, isK12Student: true)
        let bus = try #require(calculator.quote(mode: .bus, answers: answers))
        #expect(bus.discounted?.rider == .reducedAccess)
        #expect(bus.alternatives.map(\.rider) == [.student])
        #expect(Eligibility.primaryProgramKey(for: answers) == "access")
    }

    @Test("Missing full fare row yields no quote")
    func missingData() {
        let empty = FareCalculator(fares: [])
        #expect(empty.quote(mode: .bus, answers: .none) == nil)
        #expect(empty.quotes(answers: .none).isEmpty)
    }

    @Test("Money formats cents in the requested locale")
    func money() {
        #expect(Money.format(cents: 110, locale: en) == "$1.10")
        #expect(Money.format(cents: 0, locale: en) == "$0.00")
        #expect(Money.format(cents: 1234, locale: en) == "$12.34")
    }

    @Test("Eligibility ordering")
    func eligibility() {
        #expect(Eligibility.eligibleRiders(for: .none).isEmpty)
        #expect(Eligibility.eligibleRiders(for: .init(isK12Student: true)) == [.student])
        #expect(Eligibility.eligibleRiders(for: .init(householdReceivesSNAP: true, isK12Student: true)) == [.reducedAccess, .student])
        #expect(Eligibility.primaryProgramKey(for: .none) == nil)
        #expect(Eligibility.primaryProgramKey(for: .init(isK12Student: true)) == "student")
    }
}
