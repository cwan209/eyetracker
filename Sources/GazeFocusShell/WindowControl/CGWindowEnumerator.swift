import CoreGraphics
import GazeFocusCore

/// Enumerates on-screen windows from `CGWindowListCopyWindowInfo` (U8). Reads
/// geometry + owner PID + owner name only — never window titles — so no Screen
/// Recording permission is required (KTD6). Coordinates are CoreGraphics global
/// (top-left origin); the capture pipeline maps gaze into the same space.
public enum CGWindowEnumerator {

    /// On-screen, non-desktop windows at layer 0 (normal app windows).
    public static func windows() -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [WindowSnapshot] = []
        for info in raw {
            // Layer 0 = normal application windows (skip menus, shadows, the Dock, etc.).
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard
                let id = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""

            result.append(
                WindowSnapshot(
                    id: id,
                    ownerPID: Int32(pid),
                    ownerName: owner,
                    bounds: Rect(x: bounds.origin.x, y: bounds.origin.y,
                                 width: bounds.size.width, height: bounds.size.height)
                )
            )
        }
        return result
    }
}
