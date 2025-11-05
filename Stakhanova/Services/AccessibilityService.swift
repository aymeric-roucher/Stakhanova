import Cocoa
import ApplicationServices

class AccessibilityService {
    /// Get information about the UI element at the specified point
    static func getElementAtPoint(_ point: CGPoint) -> AccessibilityElement? {
        // Get the system-wide accessibility element at the mouse position
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()

        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)

        guard result == .success, let element = element else {
            return nil
        }

        return extractElementInfo(from: element)
    }

    /// Get information about the currently focused element
    static func getFocusedElement() -> AccessibilityElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let element = focusedElement else {
            return nil
        }

        return extractElementInfo(from: element as! AXUIElement)
    }

    private static func extractElementInfo(from element: AXUIElement) -> AccessibilityElement {
        let role = getAttributeValue(element, kAXRoleAttribute)
        let title = getAttributeValue(element, kAXTitleAttribute)
        let label = getAttributeValue(element, kAXDescriptionAttribute)
        let description = getAttributeValue(element, kAXHelpAttribute)
        let value = getAttributeValue(element, kAXValueAttribute)
        let roleDescription = getAttributeValue(element, kAXRoleDescriptionAttribute)

        return AccessibilityElement(
            role: role,
            title: title,
            label: label,
            description: description,
            value: value,
            elementType: roleDescription
        )
    }

    private static func getAttributeValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)

        guard result == .success else {
            return nil
        }

        if let stringValue = value as? String {
            return stringValue
        } else if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }

        return nil
    }

    /// Get all open windows across all applications
    static func getAllOpenWindows() -> [WindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { windowDict -> WindowInfo? in
            guard let ownerName = windowDict[kCGWindowOwnerName as String] as? String else {
                return nil
            }

            let title = windowDict[kCGWindowName as String] as? String
            let layer = windowDict[kCGWindowLayer as String] as? Int ?? 0

            // Extract bounds
            var bounds = CGRect.zero
            if let boundsDict = windowDict[kCGWindowBounds as String] as? [String: Any] {
                bounds = CGRect(
                    x: boundsDict["X"] as? CGFloat ?? 0,
                    y: boundsDict["Y"] as? CGFloat ?? 0,
                    width: boundsDict["Width"] as? CGFloat ?? 0,
                    height: boundsDict["Height"] as? CGFloat ?? 0
                )
            }

            return WindowInfo(
                title: title,
                ownerName: ownerName,
                bundleIdentifier: nil, // Not available in window info
                bounds: bounds,
                layer: layer
            )
        }
    }

    /// Get all running applications
    static func getAllRunningApps() -> [AppInfo] {
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular else {
                return nil
            }

            return AppInfo(
                name: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                processID: Int(app.processIdentifier)
            )
        }
    }

    /// Get information about the frontmost (active) application
    static func getActiveApp() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return AppInfo(
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            processID: Int(app.processIdentifier)
        )
    }
}
