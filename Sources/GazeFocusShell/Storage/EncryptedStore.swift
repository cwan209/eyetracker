import Foundation
import GazeFocusCore

/// On-disk encrypted model store (U13, R28). Conforms to the core `ModelStore`
/// port. Blob sealed by `ModelCodec` under the `KeychainKey`, written to a
/// per-user Application Support subdirectory excluded from backup. No key
/// rotation — erase-and-relearn is the recovery path. Raw samples are never
/// persisted (only the fitted `DwellModelState`).
public final class EncryptedStore: ModelStore, @unchecked Sendable {
    private let context: String
    private let fileURL: URL

    public init(bundleID: String = "com.gazefocus", schemaVersion: Int = 1) {
        self.context = "\(bundleID)#v\(schemaVersion)"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        self.fileURL = base.appendingPathComponent("model.gfm")
        ensureDirectoryExcludedFromBackup(base)
    }

    public func load() -> DwellModelState? {
        guard let data = try? Data(contentsOf: fileURL),
              let key = try? KeychainKey.loadOrCreate(),
              let state = try? ModelCodec.open(data, key: key, context: context) else {
            return nil   // missing blob, missing key, or tampered → fresh state
        }
        return state
    }

    public func save(_ state: DwellModelState) {
        guard let key = try? KeychainKey.loadOrCreate(),
              let blob = try? ModelCodec.seal(state, key: key, context: context) else { return }
        try? blob.write(to: fileURL, options: .atomic)
    }

    public func erase() {
        try? FileManager.default.removeItem(at: fileURL)
        KeychainKey.remove()
    }

    private func ensureDirectoryExcludedFromBackup(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)
    }
}
