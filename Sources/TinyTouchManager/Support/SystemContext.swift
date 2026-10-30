import AppKit
import ApplicationServices
import Carbon

/// Reads what the Mac is currently showing, to decide whether typing a password is appropriate.
enum SystemContext {
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm", "dev.zed.Zed",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]
    static let authPromptBundleIDs: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.LocalAuthentication.UIAgent",
        "com.apple.coreautha",
    ]

    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    static var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// True when the focused UI element is a password (secure) text field.
    static var isPasswordFieldFocused: Bool {
        guard isAccessibilityTrusted else { return false }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let axElement = element as! AXUIElement
        for attribute in [kAXSubroleAttribute, kAXRoleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, attribute as CFString, &value) == .success,
               (value as? String) == (kAXSecureTextFieldSubrole as String) {
                return true
            }
        }
        return false
    }

    /// Whether a password prompt appears to be waiting (used for the LED reminder).
    static var passwordPromptVisible: Bool {
        if isScreenLocked { return true }
        if let bundle = frontmostBundleID, authPromptBundleIDs.contains(bundle) { return true }
        return isPasswordFieldFocused || isSecureInputActive
    }
}
