import CryptoKit
import Foundation
import GazeFocusCore

/// Authenticated-encryption codec for the persisted model (U13, KTD10).
/// AES-GCM with associated data (AAD) binding the blob to a context string
/// (bundle id + schema version), so a blob can't be swapped between contexts.
/// Pure over an injected key — the Keychain/file glue lives in `EncryptedStore`,
/// which keeps this independently testable.
public enum ModelCodec {
    public enum CodecError: Error { case decryptionFailed }

    /// Seal `state` under `key`, authenticating `context` as AAD.
    public static func seal(_ state: DwellModelState,
                            key: SymmetricKey,
                            context: String) throws -> Data {
        let plaintext = try JSONEncoder().encode(state)
        let aad = Data(context.utf8)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else { throw CodecError.decryptionFailed }
        return combined
    }

    /// Open a sealed blob under `key`, requiring the same `context` AAD. Throws
    /// on tamper, a wrong key, or a context mismatch (GCM authentication failure).
    public static func open(_ data: Data,
                            key: SymmetricKey,
                            context: String) throws -> DwellModelState {
        let aad = Data(context.utf8)
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        return try JSONDecoder().decode(DwellModelState.self, from: plaintext)
    }
}
