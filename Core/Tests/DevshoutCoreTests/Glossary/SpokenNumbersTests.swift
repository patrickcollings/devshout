import Testing
@testable import DevshoutCore

@Suite struct SpokenNumbersTests {
    @Test(arguments: [
        ("1234", "1234"),
        ("12 34", "1234"),
        ("1 2 3 4", "1234"),
        ("one two three four", "1234"),
        ("One Two Three Four", "1234"),
        ("twelve thirty four", "1234"),
        ("twelve thirty-four", "1234"),
        ("forty two", "42"),
        ("twenty", "20"),
        ("oh seven", "07"),
        ("nought one", "01"),
        ("double three four", "334"),
        ("triple seven", "777"),
        ("one hundred", "100"),
        ("one hundred and five", "105"),
        ("one hundred twenty three", "123"),
        ("nineteen hundred", "1900"),
        ("two thousand", "2000"),
        ("two thousand and twelve", "2012"),
        ("three thousand four hundred and fifty six", "3456"),
        ("12 thirty four", "1234"),
    ])
    func reads(spoken: String, digits: String) {
        let parsed = SpokenNumbers.parse(spoken)
        #expect(parsed?.digits == digits)
        #expect(parsed?.end == spoken.endIndex)
    }

    @Test(arguments: [
        ("1234 two days ago", "1234", "1234"),
        ("12 oh no", "12", "12"),
        ("twelve and thirteen", "12", "twelve"),
        ("one hundred and", "100", "one hundred"),
        ("five thousand and", "5000", "five thousand"),
    ])
    func stopsAtTheEndOfTheNumber(spoken: String, digits: String, consumed: String) {
        let parsed = SpokenNumbers.parse(spoken)
        #expect(parsed?.digits == digits)
        if let parsed { #expect(String(spoken[..<parsed.end]) == consumed) }
    }

    @Test func loneUnitWords() {
        #expect(SpokenNumbers.parse("one")?.digits == "1")
        #expect(SpokenNumbers.parse("one is", allowLoneUnitWord: false) == nil)
        #expect(SpokenNumbers.parse("zero", allowLoneUnitWord: false) == nil)
        #expect(SpokenNumbers.parse("one two", allowLoneUnitWord: false)?.digits == "12")
        #expect(SpokenNumbers.parse("eleven", allowLoneUnitWord: false)?.digits == "11")
        #expect(SpokenNumbers.parse("7", allowLoneUnitWord: false)?.digits == "7")
    }

    @Test(arguments: ["", "and five", "hundred", "oh", "double", "seventh", "testing"])
    func notANumber(spoken: String) {
        #expect(SpokenNumbers.parse(spoken) == nil)
    }
}
