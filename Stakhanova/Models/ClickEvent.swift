import Foundation
import AppKit

/// Captures all context about a click event
struct ClickEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let mousePosition: CGPoint

    // Screenshot data
    let screenshotBeforeClick: Data?
    let screenshotAfterClick: Data?

    // Active application info
    let activeApp: AppInfo

    // Clicked element details (from Accessibility API)
    let clickedElement: AccessibilityElement?

    // All open windows/apps at time of click
    let openWindows: [WindowInfo]
    let runningApps: [AppInfo]

    // Modifier keys pressed during click
    let modifierFlags: [String]

    init(
        timestamp: Date = Date(),
        mousePosition: CGPoint,
        screenshotBeforeClick: Data? = nil,
        screenshotAfterClick: Data? = nil,
        activeApp: AppInfo,
        clickedElement: AccessibilityElement? = nil,
        openWindows: [WindowInfo] = [],
        runningApps: [AppInfo] = [],
        modifierFlags: [String] = []
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.mousePosition = mousePosition
        self.screenshotBeforeClick = screenshotBeforeClick
        self.screenshotAfterClick = screenshotAfterClick
        self.activeApp = activeApp
        self.clickedElement = clickedElement
        self.openWindows = openWindows
        self.runningApps = runningApps
        self.modifierFlags = modifierFlags
    }
}

struct AppInfo: Codable {
    let name: String
    let bundleIdentifier: String?
    let processID: Int
}

struct AccessibilityElement: Codable {
    let role: String?           // button, link, menu item, etc.
    let title: String?          // Button text, link text, etc.
    let label: String?          // Accessibility label
    let description: String?    // Description
    let value: String?          // Current value (for text fields, etc.)
    let elementType: String?    // More specific type info
}

struct WindowInfo: Codable {
    let title: String?
    let ownerName: String?
    let bundleIdentifier: String?
    let bounds: CGRect
    let layer: Int
}
