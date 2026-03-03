import Foundation
import CryptoKit

enum Checksum {
    /// SHA-256 hex digest of the file at the given URL.
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
