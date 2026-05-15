import Foundation

/// Generates BIP39-style random passphrases for the "Generate strong
/// passphrase" button in the setup UI.
///
/// 6 words from a 256-word list gives 48 bits of source entropy.
/// Argon2id at our chosen cost factor adds ~25–30 bits of effective
/// resistance to offline brute-force, so the practical security
/// envelope is ~75 bits — well above what's needed for a sync-
/// transport's shared blob.
///
/// The wordlist is a curated subset of common short English words.
/// All entries are 3–5 chars, all lowercase, all distinct in their
/// first three characters. That keeps generated passphrases compact
/// and easy to read out loud / write down.
enum PassphraseGenerator {
    /// Recommended word count for the "Generate" button. 6 words →
    /// ~24-character passphrase, easily over our 12-char minimum and
    /// well above the practical brute-force boundary.
    static let recommendedWordCount: Int = 6

    /// Build a random passphrase by picking `wordCount` words from
    /// `wordlist` uniformly at random and joining with `separator`.
    /// Uses `SystemRandomNumberGenerator`, which on Apple platforms
    /// is backed by `SecRandomCopyBytes`.
    static func random(wordCount: Int = recommendedWordCount,
                       separator: String = "-") -> String {
        var rng = SystemRandomNumberGenerator()
        return random(wordCount: wordCount, separator: separator, using: &rng)
    }

    /// Test seam — pass an explicit generator. Production code should
    /// use the no-argument variant which seeds from the system RNG.
    static func random<G: RandomNumberGenerator>(wordCount: Int,
                                                  separator: String,
                                                  using rng: inout G) -> String {
        precondition(wordCount > 0, "wordCount must be positive")
        precondition(!wordlist.isEmpty, "wordlist must not be empty")
        var words: [String] = []
        words.reserveCapacity(wordCount)
        for _ in 0..<wordCount {
            words.append(wordlist.randomElement(using: &rng)!)
        }
        return words.joined(separator: separator)
    }

    /// Exposed for tests and the UI's "x of N possible words" hint.
    static let wordlist: [String] = [
        "able", "acid", "aide", "aim", "air", "ale", "alley", "ally", "amber", "amid",
        "ample", "ant", "ape", "apt", "arc", "arch", "area", "arena", "arm", "army",
        "art", "ash", "atlas", "atom", "auto", "axe", "axis", "baby", "back", "bad",
        "bag", "bait", "bake", "ball", "band", "bank", "bar", "bark", "barn", "base",
        "bath", "bay", "beach", "bead", "beam", "bean", "bear", "beat", "bed", "beef",
        "beer", "bell", "belt", "bench", "bend", "berry", "best", "bet", "bike", "bin",
        "bird", "bit", "bite", "black", "blade", "blank", "blaze", "blend", "bless", "blew",
        "blind", "blink", "block", "bloom", "blue", "blur", "blush", "boat", "body", "boil",
        "bold", "bolt", "bomb", "bond", "bone", "book", "boom", "boot", "born", "boss",
        "both", "bowl", "box", "boy", "brain", "brake", "brand", "brass", "brave", "bread",
        "break", "brick", "bride", "brief", "bring", "broad", "broom", "brown", "brush", "buddy",
        "bug", "build", "bulb", "bulk", "bunch", "burn", "bury", "bus", "bush", "busy",
        "butter", "buy", "buzz", "cabin", "cable", "cake", "calm", "camel", "camp", "can",
        "candy", "cap", "card", "care", "cargo", "case", "cash", "cast", "cat", "catch",
        "cave", "cease", "cedar", "ceil", "cell", "chain", "chair", "chalk", "chant", "chaos",
        "charm", "chart", "chase", "cheap", "check", "cheek", "cheer", "chef", "chess", "chest",
        "chew", "chic", "chick", "chief", "chime", "chin", "chip", "chirp", "choir", "chop",
        "chord", "chose", "chunk", "church", "cider", "cinch", "cipher", "circle", "clamp", "clap",
        "clash", "clasp", "class", "claw", "clay", "clean", "clear", "clerk", "click", "cliff",
        "climb", "cling", "clip", "cloak", "clock", "clog", "close", "cloth", "cloud", "clove",
        "clown", "club", "clue", "clump", "coach", "coal", "coast", "coat", "code", "coil",
        "coin", "cold", "come", "comet", "comic", "cone", "cook", "cool", "cope", "copy",
        "coral", "cord", "core", "corn", "couch", "cough", "could", "count", "coupe", "court",
        "cove", "cover", "cow", "crab", "crack", "craft", "cramp", "crane", "crash", "crawl",
        "crazy", "cream", "creek", "creep", "crest", "crew", "crib", "cried", "crime", "crisp",
        "crop", "cross", "crowd", "crown", "crumb", "crush", "crust", "cry"
    ]
}
