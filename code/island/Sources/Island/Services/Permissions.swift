import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    /// Never prompts.
    static func current() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString   // == kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openSettings(accessibility: Bool) {
        let tail = accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(tail)") {
            NSWorkspace.shared.open(url)
        }
    }
}
