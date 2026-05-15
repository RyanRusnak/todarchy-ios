import XCTest
@testable import todarchy

final class PassphraseGeneratorTests: XCTestCase {

    func testWordlistHasNoDuplicates() {
        let set = Set(PassphraseGenerator.wordlist)
        XCTAssertEqual(set.count, PassphraseGenerator.wordlist.count,
                       "wordlist must contain unique entries")
    }

    /// Every word should be lowercase letters only and 3–6 chars.
    /// Anything else hurts readability or means a typo.
    func testWordlistEntriesAreWellFormed() {
        let allowed = CharacterSet.lowercaseLetters
        for word in PassphraseGenerator.wordlist {
            XCTAssertTrue(word.count >= 3 && word.count <= 6, "bad length: \(word)")
            XCTAssertNil(word.rangeOfCharacter(from: allowed.inverted),
                         "non-lowercase letter in \(word)")
        }
    }

    /// 6 words from a 250+ word list gives at least 48 bits of source
    /// entropy. That's the floor we're committing to in the wordlist
    /// docstring; if the list shrinks below 256 entries we want to
    /// know.
    func testWordlistMeetsEntropyFloor() {
        XCTAssertGreaterThanOrEqual(PassphraseGenerator.wordlist.count, 256,
                                    "wordlist must have at least 256 entries for 6-word 48-bit floor")
    }

    func testRandomProducesRequestedWordCount() {
        let pass = PassphraseGenerator.random(wordCount: 6)
        XCTAssertEqual(pass.split(separator: "-").count, 6)
    }

    func testRandomUsesCustomSeparator() {
        let pass = PassphraseGenerator.random(wordCount: 4, separator: " ")
        XCTAssertEqual(pass.split(separator: " ").count, 4)
        XCTAssertFalse(pass.contains("-"))
    }

    /// Smoke test for randomness: two calls almost certainly produce
    /// different passphrases. (Same-result probability ≈ 1/256^6.)
    func testTwoCallsDifferAlmostSurely() {
        let a = PassphraseGenerator.random()
        let b = PassphraseGenerator.random()
        XCTAssertNotEqual(a, b)
    }

    /// Every word in a generated passphrase must come from the wordlist.
    func testGeneratedWordsAllBelongToWordlist() {
        let pass = PassphraseGenerator.random(wordCount: 6)
        let wordSet = Set(PassphraseGenerator.wordlist)
        for word in pass.split(separator: "-") {
            XCTAssertTrue(wordSet.contains(String(word)), "unknown word: \(word)")
        }
    }

    /// With a seeded RNG the output is reproducible. This is the
    /// property tests rely on when they need deterministic strings.
    func testSeededOutputIsReproducible() {
        var rng1 = DeterministicRNG(seed: 42)
        var rng2 = DeterministicRNG(seed: 42)
        let a = PassphraseGenerator.random(wordCount: 6, separator: "-", using: &rng1)
        let b = PassphraseGenerator.random(wordCount: 6, separator: "-", using: &rng2)
        XCTAssertEqual(a, b)
    }

    /// Different seeds → different output (sanity check on the RNG).
    func testDifferentSeedsDiffer() {
        var rng1 = DeterministicRNG(seed: 1)
        var rng2 = DeterministicRNG(seed: 2)
        let a = PassphraseGenerator.random(wordCount: 6, separator: "-", using: &rng1)
        let b = PassphraseGenerator.random(wordCount: 6, separator: "-", using: &rng2)
        XCTAssertNotEqual(a, b)
    }
}

/// Linear-congruential PRNG for reproducible test output. Not for
/// production use — `SystemRandomNumberGenerator` is what production
/// passphrases come from.
private struct DeterministicRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
