import Foundation
import AppKit

/// Captures all context about a click event (metadata only - screenshots saved separately)
struct ClickEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let mousePosition: CGPoint

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
        activeApp: AppInfo,
        clickedElement: AccessibilityElement? = nil,
        openWindows: [WindowInfo] = [],
        runningApps: [AppInfo] = [],
        modifierFlags: [String] = []
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.mousePosition = mousePosition
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

    enum CodingKeys: String, CodingKey {
        case title, ownerName, bundleIdentifier, bounds, layer
    }

    // Regular initializer
    init(title: String?, ownerName: String?, bundleIdentifier: String?, bounds: CGRect, layer: Int) {
        self.title = title
        self.ownerName = ownerName
        self.bundleIdentifier = bundleIdentifier
        self.bounds = bounds
        self.layer = layer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        ownerName = try container.decodeIfPresent(String.self, forKey: .ownerName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        layer = try container.decode(Int.self, forKey: .layer)

        // Decode bounds from array format [[x, y], [width, height]]
        let boundsArray = try container.decode([[CGFloat]].self, forKey: .bounds)
        if boundsArray.count == 2 && boundsArray[0].count == 2 && boundsArray[1].count == 2 {
            let origin = CGPoint(x: boundsArray[0][0], y: boundsArray[0][1])
            let size = CGSize(width: boundsArray[1][0], height: boundsArray[1][1])
            bounds = CGRect(origin: origin, size: size)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .bounds, in: container, debugDescription: "Bounds array format is invalid")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(ownerName, forKey: .ownerName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(layer, forKey: .layer)

        // Encode bounds as array format [[x, y], [width, height]]
        let boundsArray = [
            [bounds.origin.x, bounds.origin.y],
            [bounds.size.width, bounds.size.height]
        ]
        try container.encode(boundsArray, forKey: .bounds)
    }
}
