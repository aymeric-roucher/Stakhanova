import Foundation
import Combine

/// Single source of truth for app-wide state
class AppState: ObservableObject {
    static let shared = AppState()

    /// Whether monitoring is currently active
    @Published var isMonitoring: Bool = false {
        didSet {
            // Persist to UserDefaults whenever it changes
            UserDefaults.standard.set(isMonitoring, forKey: "isMonitoring")
        }
    }

    /// Whether to add click marker on screenshots
    @Published var addClickMarker: Bool = true {
        didSet {
            // Persist to UserDefaults whenever it changes
            UserDefaults.standard.set(addClickMarker, forKey: "addClickMarker")
        }
    }

    private init() {
        // Restore saved state
        isMonitoring = UserDefaults.standard.bool(forKey: "isMonitoring")

        // Restore click marker setting (default to true if not set)
        if UserDefaults.standard.object(forKey: "addClickMarker") != nil {
            addClickMarker = UserDefaults.standard.bool(forKey: "addClickMarker")
        } else {
            addClickMarker = true
        }
    }
}
