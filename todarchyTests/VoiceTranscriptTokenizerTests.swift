import XCTest

final class VoiceTranscriptTokenizerTests: XCTestCase {
    func testBareTodayBecomesTag() {
        let out = VoiceCaptureSheet.tokenizeVoiceTranscript("submit report today")
        XCTAssertTrue(out.contains("!today"))
    }

    func testBareTomorrowBecomesTag() {
        let out = VoiceCaptureSheet.tokenizeVoiceTranscript("call mom tomorrow")
        XCTAssertTrue(out.contains("!tomorrow"))
    }

    func testThisWeekendMapsToWeek() {
        let out = VoiceCaptureSheet.tokenizeVoiceTranscript("prep slides this weekend")
        XCTAssertTrue(out.contains("!week"))
    }

    func testContextWordBecomesTag() {
        let out = VoiceCaptureSheet.tokenizeVoiceTranscript("call dentist phone")
        XCTAssertTrue(out.contains("@phone"))
    }

    func testWholeWordOnly() {
        // "home depot" must NOT be tokenized to "@home depot".
        let out = VoiceCaptureSheet.tokenizeVoiceTranscript("go to home depot")
        XCTAssertFalse(out.contains("@home"))
    }

    func testCombined() {
        let out = VoiceCaptureSheet.tokenizeVoiceTranscript("call mom phone today")
        XCTAssertTrue(out.contains("@phone"))
        XCTAssertTrue(out.contains("!today"))
    }

    func testCaseInsensitive() {
        let out = VoiceCaptureSheet.tokenizeVoiceTranscript("Pay bills TODAY")
        XCTAssertTrue(out.contains("!today"))
    }

    func testEndToEndParse() {
        // The real pipeline: tokenize, then QuickAddParser.
        let tokenized = VoiceCaptureSheet.tokenizeVoiceTranscript("call mom phone today")
        let parsed = QuickAddParser.parse(tokenized)
        XCTAssertEqual(parsed.ctx, .phone)
        XCTAssertEqual(parsed.due, .today)
        XCTAssertTrue(parsed.title.lowercased().contains("call mom"))
    }
}
