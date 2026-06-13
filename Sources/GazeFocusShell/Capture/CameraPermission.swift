import AVFoundation

/// Camera (TCC) permission helpers (U7, R27). Requires `NSCameraUsageDescription`
/// in the host's Info.plist (the spike embeds one into its binary).
public enum CameraPermission {
    public static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Requests access if undetermined; returns the resolved grant.
    public static func request() async -> Bool {
        switch status {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
