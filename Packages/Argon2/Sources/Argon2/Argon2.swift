import Foundation
import CArgon2

/// Swift facade over libargon2's `argon2id_hash_raw`. Argon2id is the
/// hybrid variant — combines argon2i's side-channel resistance with
/// argon2d's GPU resistance — and is the only variant todarchy uses.
///
/// We only expose what the app actually needs: derive a 32-byte key
/// from a (passphrase, salt, params) tuple. No encoded-hash mode, no
/// password verification — those are for storing-and-checking-passwords
/// flows, which is not what we do (we *use* the derived key directly
/// to AEAD-seal the share-keys map).
public enum Argon2 {
    /// Argon2id work-factor parameters. Higher = slower = more
    /// resistant to brute-force, with diminishing returns past the
    /// app's tolerance for setup latency on the slowest target device.
    public struct Params: Equatable, Sendable {
        /// Number of passes over the memory matrix.
        public let timeCost: UInt32
        /// Memory matrix size in KiB.
        public let memoryCostKiB: UInt32
        /// Lanes; runs sequentially because libargon2 is compiled
        /// with ARGON2_NO_THREADS, so values > 1 cost time but don't
        /// parallelize. Keep at 1.
        public let parallelism: UInt32

        public init(timeCost: UInt32, memoryCostKiB: UInt32, parallelism: UInt32) {
            self.timeCost = timeCost
            self.memoryCostKiB = memoryCostKiB
            self.parallelism = parallelism
        }

        /// Default parameters for todarchy's passphrase derivation.
        /// Tuned to take roughly 200–400 ms on an A15 / M-series; if
        /// the slowest supported device (iPhone XR-class) needs more
        /// budget, we lower memory. RFC 9106 recommends
        /// `t=1, m=2^21 (2 GiB)` for interactive — we use less memory
        /// because that's too much on iOS, and bump iterations to
        /// compensate.
        public static let interactive = Params(
            timeCost: 3,
            memoryCostKiB: 64 * 1024,   // 64 MiB
            parallelism: 1
        )
    }

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case derivationFailed(code: Int32, message: String)

        public var errorDescription: String? {
            switch self {
            case let .derivationFailed(code, message):
                return "Argon2 derivation failed (\(code)): \(message)"
            }
        }
    }

    /// Derive `keyLength` bytes from `passphrase` and `salt` using
    /// Argon2id with the given parameters. Throws if libargon2 returns
    /// a non-zero status (typically only on parameter-out-of-range —
    /// salt < 8 bytes, time/memory zero, etc.).
    public static func deriveKey(
        passphrase: String,
        salt: Data,
        params: Params = .interactive,
        keyLength: Int = 32
    ) throws -> Data {
        let passphraseBytes = Array(passphrase.utf8)
        var output = [UInt8](repeating: 0, count: keyLength)

        let status: Int32 = passphraseBytes.withUnsafeBufferPointer { pwdBuf in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                output.withUnsafeMutableBufferPointer { outBuf in
                    argon2id_hash_raw(
                        params.timeCost,
                        params.memoryCostKiB,
                        params.parallelism,
                        pwdBuf.baseAddress,
                        pwdBuf.count,
                        saltBytes.baseAddress,
                        saltBytes.count,
                        outBuf.baseAddress,
                        outBuf.count
                    )
                }
            }
        }

        guard status == ARGON2_OK.rawValue else {
            let message = String(cString: argon2_error_message(status))
            throw Error.derivationFailed(code: status, message: message)
        }
        return Data(output)
    }
}
