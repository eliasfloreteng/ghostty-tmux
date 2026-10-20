// Print the Sparkle public EdDSA key (SUPublicEDKey) that belongs to a
// private key, so a build can never ship a public key that does not match
// the key its updates are signed with.
//
// Usage: printf '%s' "$SPARKLE_PRIVATE_KEY" | swift dist/macos/sparkle-public-key.swift
//
// The private key is read from standard input in the format
// `generate_keys -x` exports: the base64 of the 32-byte ed25519 seed.
// Keys made before Sparkle 2.0 used another format; re-export or replace
// those.

import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: input), seed.count == 32 else {
    FileHandle.standardError.write(Data("error: expected the base64 of a 32-byte ed25519 seed, as `generate_keys -x` exports\n".utf8))
    exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
