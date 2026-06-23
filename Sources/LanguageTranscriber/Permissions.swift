import Foundation
import AVFoundation
import CoreGraphics

enum PermissionState: Equatable {
    case granted
    case denied
    case undetermined
}

enum Permissions {
    /// Microphone authorization for this process. Queried via AVCaptureDevice.
    static func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:        return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:     return .undetermined
        @unknown default:        return .undetermined
        }
    }

    /// Screen Recording (a.k.a. "Screen & System Audio Recording") authorization.
    /// `CGPreflightScreenCaptureAccess` returns `true` only once TCC has granted us access.
    /// Note: macOS often caches the answer per process — if the user toggles permission
    /// in System Settings, the running app may need to be relaunched for this to flip.
    static func screenRecording() -> PermissionState {
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Prompt for microphone access. Safe to call repeatedly.
    @discardableResult
    static func requestMicrophone() async -> Bool {
        if microphone() == .granted { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Trigger the Screen Recording permission prompt. macOS will show its TCC dialog the first
    /// time; on subsequent runs the user must toggle the switch in System Settings → Privacy &
    /// Security → Screen Recording.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        return CGRequestScreenCaptureAccess()
    }
}
