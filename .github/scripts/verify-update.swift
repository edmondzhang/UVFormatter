import CryptoKit
import Foundation

let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let publicKeyData = ProcessInfo.processInfo.environment["SPARKLE_PUBLIC_KEY"].flatMap({ Data(base64Encoded: $0) }),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    throw CocoaError(.fileReadCorruptFile)
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
guard publicKey.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Sparkle update signature does not match the configured public key.\n".utf8))
    exit(1)
}
