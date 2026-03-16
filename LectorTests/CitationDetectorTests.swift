import XCTest
@testable import Lector

// MARK: - CitationDetector Unit Tests
//
// Tests for CitationDetector's pure-function helpers.
// Focuses on recently modified logic: extractYear (letter-suffix years),
// extractSurnameFirstNameFirst (first-name-first bibliography format),
// and the supporting isNewEntryStart / extractSurname helpers.

final class CitationDetectorTests: XCTestCase {

    // MARK: - extractYear

    func testExtractYearParens() {
        // Standard author-year inline: (YYYY)
        XCTAssertEqual(CitationDetector.extractYear(from: "Sargent (1991) argues..."), "1991")
        XCTAssertEqual(CitationDetector.extractYear(from: "see Smith (2020) for details"), "2020")
    }

    func testExtractYearSpacePeriod() {
        // AEA style: "Author 1980."
        XCTAssertEqual(CitationDetector.extractYear(from: "Sims, C. 1980. Title."), "1980")
        XCTAssertEqual(CitationDetector.extractYear(from: "Patterson 2015."), "2015")
    }

    func testExtractYearLetterSuffix() {
        // AEA style with disambiguation letter: "Author 1980a."
        XCTAssertEqual(CitationDetector.extractYear(from: "Sims, Christopher A. 1980a. Comment."), "1980")
        XCTAssertEqual(CitationDetector.extractYear(from: "Ramey, Valerie A. 2009a. Paper title."), "2009")
        XCTAssertEqual(CitationDetector.extractYear(from: "Romer, Christina D. 1994b. Article."), "1994")
    }

    func testExtractYearPeriodPeriod() {
        // AEA style: ". YYYY."
        XCTAssertEqual(CitationDetector.extractYear(from: "Del Negro, Marco, et al. 2015. Title."), "2015")
        XCTAssertEqual(CitationDetector.extractYear(from: "Brown, J. S. 2018. Paper."), "2018")
    }

    func testExtractYearPeriodLetterSuffix() {
        // AEA style with letter suffix after period: ". 1980a."
        XCTAssertEqual(CitationDetector.extractYear(from: "Sargent, T. J. 1991a. Paper."), "1991")
        XCTAssertEqual(CitationDetector.extractYear(from: "Ramey. 2011a. The Military Spending Multiplier."), "2011")
    }

    func testExtractYearJournalCommaFormat() {
        // Journal format: ", YYYY, vol"
        XCTAssertEqual(CitationDetector.extractYear(from: "Economics, 2019, 5(3): 100–120"), "2019")
        XCTAssertEqual(CitationDetector.extractYear(from: "Review, 2004, 94(2): 55–80"), "2004")
    }

    func testExtractYearFallback() {
        // Last-resort: any 4-digit 19xx/20xx year
        XCTAssertEqual(CitationDetector.extractYear(from: "Working paper 2020"), "2020")
        XCTAssertEqual(CitationDetector.extractYear(from: "Unpublished manuscript 1999"), "1999")
    }

    func testExtractYearFallbackLetterSuffix() {
        // Fallback pattern uses (?!\d) not \b, so "1980a" should match "1980"
        XCTAssertEqual(CitationDetector.extractYear(from: "referenced as 1980a in later work"), "1980")
        XCTAssertEqual(CitationDetector.extractYear(from: "see 2011b for further discussion"), "2011")
    }

    func testExtractYearNilForNoYear() {
        XCTAssertNil(CitationDetector.extractYear(from: "No year here at all"))
        XCTAssertNil(CitationDetector.extractYear(from: ""))
        XCTAssertNil(CitationDetector.extractYear(from: "1800"))   // too old
        XCTAssertNil(CitationDetector.extractYear(from: "2100"))   // too far future
    }

    // MARK: - isNewEntryStart

    func testIsNewEntryStartUppercase() {
        XCTAssertTrue(CitationDetector.isNewEntryStart("Acemoglu, Daron. 2023."))
        XCTAssertTrue(CitationDetector.isNewEntryStart("Sargent, T. 1991. Paper."))
        XCTAssertTrue(CitationDetector.isNewEntryStart("Daron Acemoglu and Simon Johnson. Title."))
    }

    func testIsNewEntryStartKnownLowerPrefix() {
        XCTAssertTrue(CitationDetector.isNewEntryStart("van der Berg, Hans. 2010."))
        XCTAssertTrue(CitationDetector.isNewEntryStart("de Melo, Luiz. 2008."))
    }

    func testIsNewEntryStartRejectsDashPrefix() {
        XCTAssertFalse(CitationDetector.isNewEntryStart("–––. 2003. Another paper."))
        XCTAssertFalse(CitationDetector.isNewEntryStart("---. Follow-up."))
        XCTAssertFalse(CitationDetector.isNewEntryStart(", and Susan Smith."))
    }

    func testIsNewEntryStartRejectsEmpty() {
        XCTAssertFalse(CitationDetector.isNewEntryStart(""))
    }

    // MARK: - extractSurname (inverted format)

    func testExtractSurnameAEA() {
        XCTAssertEqual(CitationDetector.extractSurname(from: "Acemoglu, Daron. 2023. Title."), "Acemoglu")
        XCTAssertEqual(CitationDetector.extractSurname(from: "Sargent, Thomas J. 1991. Paper."), "Sargent")
        XCTAssertEqual(CitationDetector.extractSurname(from: "Del Negro, Marco, and Frank Schorfheide. 2013."), "Del Negro")
    }

    func testExtractSurnameRejectsFirstNameFirst() {
        // "Daron Acemoglu" — 2 tokens, both uppercase → co-author pattern rejection
        XCTAssertNil(CitationDetector.extractSurname(from: "Daron Acemoglu and Simon Johnson. Power."))
    }

    func testExtractSurnameRejectsNoComma() {
        XCTAssertNil(CitationDetector.extractSurname(from: "Daron Acemoglu 2023"))
    }

    func testExtractSurnameRejectsStopword() {
        XCTAssertNil(CitationDetector.extractSurname(from: "The effects of monetary policy, 2019"))
        XCTAssertNil(CitationDetector.extractSurname(from: "Bureau of Labor Statistics, 2025"))
    }

    func testExtractSurnameRejectsDigits() {
        XCTAssertNil(CitationDetector.extractSurname(from: "Vol. 5, No. 2 (2019)"))
    }

    // MARK: - extractSurnameFirstNameFirst (new in PR #19)

    func testExtractSurnameFirstNameFirstBasic() {
        // "FirstName LastName and ..."
        XCTAssertEqual(
            CitationDetector.extractSurnameFirstNameFirst(from: "Daron Acemoglu and Simon Johnson. Title. 2023."),
            "Acemoglu"
        )
    }

    func testExtractSurnameFirstNameFirstCommaVariant() {
        // "FirstName LastName, OtherFirst OtherLast"
        XCTAssertEqual(
            CitationDetector.extractSurnameFirstNameFirst(from: "Daron Acemoglu, Simon Johnson, and Pascual Restrepo. Paper."),
            "Acemoglu"
        )
    }

    func testExtractSurnameFirstNameFirstPeriodVariant() {
        // "FirstName LastName. Title" — period-space ends name
        XCTAssertEqual(
            CitationDetector.extractSurnameFirstNameFirst(from: "Robert Hall. Why Does the Economy Fall to Pieces. 2019."),
            "Hall"
        )
    }

    func testExtractSurnameFirstNameFirstParenVariant() {
        // "FirstName LastName (YYYY)" — paren ends name
        XCTAssertEqual(
            CitationDetector.extractSurnameFirstNameFirst(from: "Robert Lucas (1988). On the Mechanics of Development."),
            "Lucas"
        )
    }

    func testExtractSurnameFirstNameFirstRejectsInverted() {
        // Single token before first separator ("Acemoglu") → count < 2 → nil
        XCTAssertNil(CitationDetector.extractSurnameFirstNameFirst(from: "Acemoglu, Daron. 2023. Title."))
    }

    func testExtractSurnameFirstNameFirstRejectsInstitutional() {
        // "bureau" is in notSurnames → rejects
        XCTAssertNil(CitationDetector.extractSurnameFirstNameFirst(from: "Bureau of Labor Statistics. 2025. Report."))
    }

    func testExtractSurnameFirstNameFirstRejectsTooManyTokens() {
        // More than 5 tokens before separator → body-text guard kicks in
        XCTAssertNil(CitationDetector.extractSurnameFirstNameFirst(from: "This paper extends the work of Sims and Zha 1999 by adding"))
    }

    func testExtractSurnameFirstNameFirstRejectsLowercaseFirstName() {
        // First token must be uppercase
        XCTAssertNil(CitationDetector.extractSurnameFirstNameFirst(from: "de Melo and Johnson. Paper. 2010."))
    }

    func testExtractSurnameFirstNameFirstRejectsStopwordSurname() {
        // Last token in name segment is a stopword
        XCTAssertNil(CitationDetector.extractSurnameFirstNameFirst(from: "John and Mary Study. 2020."))
    }

    // MARK: - Integration: indexReferences handles first-name-first format

    func testIndexReferencesHandlesFirstNameFirstFormat() {
        // Create a minimal PDF with a reference in first-name-first format.
        // We test via CitationDetector's public API: after indexing a PDF
        // that has "Daron Acemoglu and Simon Johnson." entries, the catalog
        // should contain "Acemoglu <year>" keys.
        //
        // Since we can't easily create a real PDFDocument in a unit test,
        // we verify the helper functions that feed into indexReferences.
        let line = "Daron Acemoglu and Simon Johnson. Power and Progress. PublicAffairs, 2023."
        XCTAssertTrue(CitationDetector.isNewEntryStart(line))
        XCTAssertNil(CitationDetector.extractSurname(from: line))   // inverted format fails
        XCTAssertEqual(CitationDetector.extractSurnameFirstNameFirst(from: line), "Acemoglu")
        XCTAssertEqual(CitationDetector.extractYear(from: line), "2023")
    }

    // MARK: - Integration: extractYear handles Ramey paper letter-suffix entries

    func testExtractYearHandlesRameyStyleEntries() {
        let rameyEntry = "Romer, Christina D., and David H. Romer. 2004a. \"A New Measure of Monetary Shocks.\" American Economic Review, 94 (4): 1055–1084."
        XCTAssertEqual(CitationDetector.extractYear(from: rameyEntry), "2004")

        let simsEntry = "Sims, Christopher A. 1980a. \"Macroeconomics and Reality.\" Econometrica, 48 (1): 1–48."
        XCTAssertEqual(CitationDetector.extractYear(from: simsEntry), "1980")

        let rameyEntry2 = "Ramey, Valerie A. 2016a. \"Macroeconomic Shocks and Their Propagation.\" Handbook of Macroeconomics."
        XCTAssertEqual(CitationDetector.extractYear(from: rameyEntry2), "2016")
    }
}
